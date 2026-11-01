/**
 * Read a file from disk and store it in memory.
 *
 * Copyright: Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:    $(LINK2 https://github.com/dlang/dmd/blob/master/compiler/src/dmd/file_manager.d, _file_manager.d)
 * Documentation:  https://dlang.org/phobos/dmd_file_manager.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/compiler/src/dmd/file_manager.d
 */

module dmd.file_manager;

import core.stdc.stdio;
import dmd.common.outbuffer;
import dmd.root.stringtable : StringTable;
import dmd.root.file : File;
import dmd.root.filename : FileName, isDirSeparator;
import dmd.root.string : toDString;
import dmd.globals;
import dmd.identifier;
import dmd.location;

enum package_d  = "package." ~ mars_ext;
enum package_di = "package." ~ hdr_ext;

/// Returns: whether a file with `name` is a special "package.d" module
bool isPackageFileName(scope FileName fileName) nothrow
{
    return FileName.equals(fileName.name, package_d) || FileName.equals(fileName.name, package_di);
}

// A path stack that allows one to go up and down the path using directory
// separators. `cur` is the current path, `up` goes up one path, `down` goes
// down one path. if `up` or `down` return false, there are no further paths.
private struct PathStack
{
    private const(char)[] path;
    private size_t pos;

    @safe @nogc nothrow pure:

    this(const(char)[] p)
    {
        path = p;
        pos = p.length;
    }

    const(char)[] cur()
    {
        return path[0 .. pos];
    }

    bool up()
    {
        if (pos == 0)
            return false;
        while (--pos != 0)
            if (isDirSeparator(path[pos]))
                return true;
        return false;
    }

    bool down()
    {
        if (pos == path.length)
            return false;
        while (++pos != path.length)
            if (isDirSeparator(path[pos]))
                return true;
        return false;
    }
}

/***************************
 * Cache path lookups so the operating system
 * is only consulted once for each path.
 */
private struct PathCache
{
    /* for filespec "a/b/c/d.ext"
     * a b and c are directories, a, a/b, a/b/c are paths.
     */

    StringTable!(bool) pathStatus;      // cached value of does a path exist or not

  nothrow:

    /**
     * Determine if the path part of path/filename exists.
     * Cache the results for the path and each left-justified subpath of the path.
     * Params:
     *  filespec = path/filename
     * Returns:
     *  true if path exists, false if it does not
     */
    bool pathExists(const(char)[] filespec) nothrow
    {
        /* look for the longest leftmost parent path that is cached
         * by starting at the right and working to the left
         */
        bool exists = true;
        auto st = PathStack(filespec);
        while (st.up)
        {
            if (auto cached = pathStatus.lookup(st.cur))
            {
                exists = cached.value;
                break;
            }
        }
        /* found a parent path that is cached (or reached the left end of the path).
         * Now move right caching the results of those directories.
         * Once a directory is found to not exist, all the directories
         * to the right of it do not exist
         */
        while (st.down)
        {
            if (!exists)
                pathStatus.insert(st.cur, false);
            else
                exists = pathStatus.insert(st.cur, FileName.exists(st.cur) == 2).value;
        }

        return exists;
    }

    /**
     * Ask if path ends in a directory.
     * Cache result for speed.
     * Params:
     *  path = a path
     * Returns:
     *  true if it's a path, false if not
     */
    bool isExistingPath(const char[] path)
    {
        auto cached = pathStatus.lookup(path);
        if (!cached)
            cached = pathStatus.insert(path, FileName.exists(path) == 2);
        return cached.value;
    }
}

final class FileManager
{
    private StringTable!(const(ubyte)[]) files;  // contents of files indexed by file name

    private PathCache pathCache;

    ///
    public this () nothrow
    {
        this.files._init();
        this.pathCache.pathStatus._init();
    }

nothrow:
    /********************************************
    * Look for the source file if it's different from filename.
    * Look for .di, .d, directory, and along global.path.
    * Does not open the file.
    * Params:
    *      filename = as supplied by the user
    *      pathsInfo = pathsInfo to look for filename with metadata
    *      whichPathFoundThis = Which path from `path` was used in determining the output path, or -1 if unknown.
    * Returns:
    *      the found file name or
    *      `null` if it is not different from filename.
    */
    const(char)[] lookForSourceFile(const char[] filename, const ImportPathInfo[] pathsInfo, out ptrdiff_t whichPathFoundThis)
    {
        //printf("lookForSourceFile(`%.*s`)\n", cast(int)filename.length, filename.ptr);
        /* Search along pathsInfo[] for .di file, then .d file.
        */

        whichPathFoundThis = -1;

        // List of extensions to match, in order of precedence.
        const(char)[][2] extensions = [
            FileName.forceExt(filename, hdr_ext),
            FileName.forceExt(filename, mars_ext),
        ];
        const(char)[][3] importCextensions = [
            FileName.forceExt(filename, i_ext),
            FileName.forceExt(filename, h_ext),
            FileName.forceExt(filename, c_ext),
        ];
        scope(exit)
        {
            foreach (ext; extensions)
                FileName.free(ext.ptr);
            foreach (ext; importCextensions)
                FileName.free(ext.ptr);
        }

        /* For `-makedeps-absent`, record the candidates within directory
         * `path` that precede candidate number `found`, in the order
         * lookForSourceFileInPath() probes them: mod.di, mod.d,
         * mod/package.di, mod/package.d, then the ImportC extensions.
         * Only files are recorded, never directories: a candidate whose
         * parent directory is missing (which pathExists() finds without
         * probing the file) stands for that directory too, as creating
         * the file creates it. So the package files count even when
         * mod/ is not a directory. `size_t.max` records every candidate.
         * A null `path` (the working directory) records the relative
         * candidates.
         */
        void recordAbsentCandidates(const char[] path, size_t found)
        {
            import dmd.deps : addAbsentDep;

            if (!global.params.makeDepsAbsent.doOutput)
                return;

            size_t index;
            void record(const char[] dir, const char[] name)
            {
                if (index++ >= found)
                    return;
                const candidate = FileName.combine(dir, name);
                addAbsentDep(candidate);
                if (candidate.ptr != name.ptr)
                    FileName.free(candidate.ptr);
            }

            foreach (ext; extensions)
                record(path, ext);
            const n = FileName.combine(path, FileName.sansExt(filename));
            record(n, package_di);
            record(n, package_d);
            if (n.ptr != filename.ptr)
                FileName.free(n.ptr);
            foreach (ext; importCextensions)
                record(path, ext);
        }

        /* Search for all combinations of files (mod.di, mod.d, mod/package.d, ...)
         * within in directory `path`.
         */
        const(char)[] lookForSourceFileInPath(const char[] path)
        {
            // When checking for modules locally, combine won't allocate a new string.
            bool checkLocal = path is null;
            void freePath(const(char)[] p)
            {
                if (checkLocal)
                    return;
                FileName.free(p.ptr);
            }

            const p = FileName.combine(path, filename);
            scope(exit) freePath(p);
            if (!pathCache.pathExists(p))
            {
                recordAbsentCandidates(path, size_t.max);
                return null; // no need to check for anything else.
            }

            // Search for any file matching {path}/{file}.{ext}
            foreach (i, ext; extensions)
            {
                const file = FileName.combine(path, ext);
                if (FileName.exists(file) == 1)
                {
                    import dmd.root.rmem : xarraydup;
                    recordAbsentCandidates(path, i);
                    return checkLocal ? file.xarraydup : file;
                }
                freePath(file);
            }

            const n = FileName.combine(path, FileName.sansExt(filename));
            scope(exit) freePath(n);
            if (pathCache.isExistingPath(n))
            {
                /* The filename exists but it's a directory.
                 * Therefore, the result should be: filename/package.d
                 * iff filename/package.d is a file
                 */
                const ni = FileName.combine(n, package_di);
                if (FileName.exists(ni) == 1)
                {
                    recordAbsentCandidates(path, extensions.length);
                    return ni;
                }
                FileName.free(ni.ptr);

                const nd = FileName.combine(n, package_d);
                if (FileName.exists(nd) == 1)
                {
                    recordAbsentCandidates(path, extensions.length + 1);
                    return nd;
                }
                FileName.free(nd.ptr);
            }

            /* Search for any file with importC extensions after all attempts
               to find a D module/package in the path are exhausted.  */
            foreach (i, ext; importCextensions)
            {
                const file = FileName.combine(path, ext);
                if (FileName.exists(file) == 1)
                {
                    import dmd.root.rmem : xarraydup;
                    recordAbsentCandidates(path, extensions.length + 2 + i);
                    return checkLocal ? file.xarraydup : file;
                }
                freePath(file);
            }
            recordAbsentCandidates(path, size_t.max);
            return null;
        }

        // First see if module is found in any search paths.
        if (!FileName.absolute(filename))
        {
            foreach (pathIndex, entry; pathsInfo)
            {
                if (auto s = lookForSourceFileInPath(entry.path.toDString()))
                {
                    whichPathFoundThis = pathIndex;
                    return s;
                }
            }
        }
        // No modules found, check for the module locally.
        if (auto s = lookForSourceFileInPath(null))
            return s;

        return null;
    }

    /**
     * Retrieve the cached contents of the file given by `filename`.
     * If the file has not been read before, read it and add the contents
     * to the file cache.
     * Params:
     *  filename = the name of the file
     * Returns:
     *  the contents of the file, or `null` if it could not be read or was empty
     */
    const(ubyte)[] getFileContents(FileName filename)
    {
        const name = filename.toString;
        if (auto val = files.lookup(name))      // if `name` is cached
            return val.value;                   // return its contents

        if (FileName.exists(name) != 1) // if not an ordinary file
            return null;

        OutBuffer buf;
        if (File.read(name, buf))
            return null;        // failed

        buf.write32(0);         // terminating dchar 0

        const length = buf.length;
        const ubyte[] fb = cast(ubyte[])(buf.extractSlice()[0 .. length - 4]);
        if (files.insert(name, fb) is null)
            assert(0, "Insert after lookup failure should never return `null`");

        return fb;
    }

    /**
     * Adds the contents of a file to the table.
     * Params:
     *  filename = name of the file
     *  buffer = contents of the file
     * Returns:
     *  the buffer added, or null
     */
    const(ubyte)[] add(FileName filename, const(ubyte)[] buffer)
    {
        auto val = files.insert(filename.toString, buffer);
        return val == null ? null : val.value;
    }
}
