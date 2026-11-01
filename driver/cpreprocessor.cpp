#include "driver/cpreprocessor.h"

#include "dmd/errors.h"
#include "dmd/root/rmem.h"
#include "dmd/timetrace.h"
#include "driver/cl_options.h"
#include "driver/tool.h"
#include "gen/irstate.h"
#include "llvm/ADT/StringSet.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/Program.h"
#include "llvm/MC/MCSubtargetInfo.h"
#include "llvm/Target/TargetMachine.h"

// In dmd/deps.d
void addAbsentDep(const char *path);

namespace {
const char *getPathToImportc_h(Loc loc) {
  // importc.h should be next to object.d
  static const char *cached = nullptr;
  if (!cached) {
    cached = FileName::searchPath(global.importPaths, "importc.h", false);

    // for -makedeps-absent, the import paths searched before the one with it
    for (const char *path : global.importPaths) {
      const char *candidate = FileName::combine(path, "importc.h");
      if (cached && strcmp(candidate, cached) == 0)
        break;
      addAbsentDep(candidate);
    }
    if (!cached) {
      error(loc, "cannot find \"importc.h\" along import path");
      fatal();
    }

#ifdef _WIN32
    // if the path to importc.h is relative, cl.exe (but not clang-cl) treats it as relative to the .c file!
    cached = FileName::toAbsolute(cached);
#endif
  }
  return cached;
}

FileName getOutputPath(Loc loc, const char *csrcfile) {
  llvm::SmallString<64> buffer;

  // 1) create a new temporary directory (e.g., `/tmp/itmp-ldc-10ecec`)
  auto ec = llvm::sys::fs::createUniqueDirectory("itmp-ldc", buffer);
  if (ec) {
    error(loc,
          "failed to create temporary directory for preprocessed .i file: %s\n%s",
          buffer.c_str(), ec.message().c_str());
    fatal();
  }

  // 2) append the .c file name, replacing the extension with .i
  llvm::sys::path::append(buffer, FileName::name(csrcfile));
  llvm::sys::path::replace_extension(buffer, i_ext.ptr);

  // the directory is removed (after the file) in Module.read()

  return FileName::create(buffer.c_str()); // allocates a copy
}

// Returns the prerequisites of the single make rule in `rule`, as gcc's and
// clang's `-MD` write it: separated by whitespace and escaped line breaks,
// with spaces and '#' escaped by a backslash and '$' doubled.
std::vector<std::string> parseMakeRulePrerequisites(llvm::StringRef rule) {
  std::vector<std::string> prerequisites;
  std::string current;
  const auto flush = [&] {
    if (!current.empty())
      prerequisites.push_back(std::move(current));
    current.clear();
  };

  // skip the target (set to a plain name with -MT)
  size_t i = rule.find(':');
  if (i == llvm::StringRef::npos)
    return prerequisites;

  for (++i; i < rule.size(); ++i) {
    const char c = rule[i];
    const char next = i + 1 < rule.size() ? rule[i + 1] : '\0';
    if (c == '\\' && (next == ' ' || next == '\t' || next == '#')) {
      current += next;
      ++i;
    } else if (c == '\\' && (next == '\n' || next == '\r')) {
      flush();
    } else if (c == '$' && next == '$') {
      current += '$';
      ++i;
    } else if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      flush();
    } else {
      current += c;
    }
  }
  flush();
  return prerequisites;
}

// Adds the headers in the dependency file `depFile` the preprocessor wrote
// for `csrcfile` to the -makedeps files, each once per compilation.
void addHeadersToMakeDeps(Loc loc, const char *depFile, const char *csrcfile) {
  static llvm::StringSet<> listed;

  auto buffer = llvm::MemoryBuffer::getFile(depFile);
  if (!buffer) {
    error(loc, "cannot read the C preprocessor's dependency file `%s`: %s",
          depFile, buffer.getError().message().c_str());
    fatal();
  }

  for (const auto &path : parseMakeRulePrerequisites((*buffer)->getBuffer())) {
    if (path == csrcfile || !listed.insert(path).second)
      continue;
    global.params.makeDeps.files.push(mem.xstrdup(path.c_str()));
  }
}
} // anonymous namespace

FileName runCPreprocessor(FileName csrcfile, Loc loc, OutBuffer &defines) {
  dmd::TimeTraceScope timeScope("Preprocess C file", csrcfile.toChars(), loc);

  const char *importc_h = getPathToImportc_h(loc);

  const auto &triple = *global.params.targetTriple;
  const bool isMSVC = triple.isWindowsMSVCEnvironment();

#ifdef _WIN32
  windows::MsvcEnvironmentScope msvcEnv;
  if (isMSVC)
    msvcEnv.setup(/*forPreprocessingOnly=*/true);
#endif

  FileName ipath = getOutputPath(loc, csrcfile.toChars());

  // With -makedeps, the preprocessor lists the headers it read in a make rule
  // next to the .i file. Not done for MSVC, whose /showIncludes goes to the
  // console.
  //
  // It lists no absent headers: a header created in an include directory
  // searched ahead of the one a header was found in is missed, as is one
  // that makes a failing `__has_include` succeed, which names no file the
  // rule could list. Deriving them from the search order would miss the
  // latter, the includer's directory of a quoted include, and
  // `#include_next`, so -makedeps-absent does not claim them; a build that
  // keys on its output must treat the C include directories as unlisted.
  std::string depFile;
  if (global.params.makeDeps.doOutput && !isMSVC) {
    llvm::SmallString<64> buffer(ipath.toChars());
    llvm::sys::path::replace_extension(buffer, "dep");
    depFile = buffer.str().str();
  }

  std::vector<std::string> args;
  const std::string &cc = getCC(args);

  args.push_back(isMSVC ? "/std:c11" : "-std=c11");

  if (!isMSVC)
    appendTargetArgsForGcc(args);

  if (triple.isOSDarwin())
    args.push_back("-fno-blocks"); // disable blocks extension

  for (const auto &ccSwitch : opts::ccSwitches) {
    args.push_back(ccSwitch);
  }
  for (const auto &cppSwitch : opts::cppSwitches) {
    args.push_back(cppSwitch);
  }

  if (isMSVC) {
    args.push_back("/nologo");
    args.push_back("/P"); // preprocess only

    const bool isClangCl = llvm::StringRef(cc).contains_insensitive("clang-cl");

    if (!isClangCl) {
      args.push_back("/PD");              // print all macro definitions
      args.push_back("/Zc:preprocessor"); // use the new conforming preprocessor
    } else {
      // propagate the target to the preprocessor
      args.push_back("--target=" + triple.getTriple());

      // propagate all enabled/disabled features to the preprocessor
      const auto &subTarget = gTargetMachine->getMCSubtargetInfo();
#if LLVM_VERSION_MAJOR >= 23
      const auto &featureBits = subTarget.getFeatureBits();
#else
      const auto &featureBits = subTarget->getFeatureBits();
#endif

      llvm::SmallString<64> featureString;
      for (const auto &feature :
#if LLVM_VERSION_MAJOR >= 23
           subTarget.getAllProcessorFeatures()
#else
           subTarget->getAllProcessorFeatures()
#endif
           ) {
        args.push_back("-Xclang");
        args.push_back("-target-feature");
        args.push_back("-Xclang");

        featureString += featureBits.test(feature.Value) ? '+' : '-';
#if LLVM_VERSION_MAJOR >= 23
        featureString += feature.key();
#else
        featureString += feature.Key;
#endif
        args.push_back(featureString.str().str());
        featureString.clear();
      }

      // print macro definitions (clang-cl doesn't support /PD - use clang's
      // -dD)
      args.push_back("/clang:-dD");

      // need to redefine some macros in importc.h
      args.push_back("-Wno-builtin-macro-redefined");

      // disable the clang resource headers (immintrin.h etc.), using
      // unsupported types like __int128, __bf16 etc. - stick to the MS headers
      args.push_back("-nobuiltininc");
    }

    args.push_back(csrcfile.toChars());
    args.push_back((llvm::Twine("/FI") + importc_h).str());
    // preprocessed output file
    args.push_back((llvm::Twine("/Fi") + ipath.toChars()).str());
  } else { // Posix
    // merge #define's with output:
    // https://gcc.gnu.org/onlinedocs/cpp/Invocation.html#index-dD
    args.push_back("-dD");

    // need to redefine some macros in importc.h
    args.push_back("-Wno-builtin-macro-redefined");

    args.push_back("-E"); // run preprocessor only
    if (!depFile.empty()) {
      args.push_back("-MD");
      args.push_back("-MF");
      args.push_back(depFile);
      args.push_back("-MT");
      args.push_back("ldc-cpp");
    }
    args.push_back("-include");
    args.push_back(importc_h);
    args.push_back(csrcfile.toChars());
    args.push_back("-o");
    args.push_back(ipath.toChars());
  }

  const int status = executeToolAndWait(loc, cc, args, global.params.v.verbose);
  if (status) {
    errorSupplemental(loc, "C preprocessor failed for file '%s'", csrcfile.toChars());
    fatal();
  }

  if (!depFile.empty()) {
    addHeadersToMakeDeps(loc, depFile.c_str(), csrcfile.toChars());
    // Module.read() removes the directory, which must be empty by then
    llvm::sys::fs::remove(depFile);
  }

  return ipath;
}
