/**
 * This module extracts debug info from the currently running Mach-O executable.
 *
 * The static linker leaves the DWARF in the object files; `dsymutil` gathers
 * it into a `.dSYM` bundle beside the executable, which is where this module
 * reads it from.
 *
 * Copyright: Copyright Jacob Carlborg 2018.
 * License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Authors:   Jacob Carlborg
 * Source:    $(DRUNTIMESRC core/internal/backtrace/macho.d)
 */
module core.internal.backtrace.macho;

version (OSX)
    version = Darwin;
else version (iOS)
    version = Darwin;
else version (TVOS)
    version = Darwin;
else version (WatchOS)
    version = Darwin;

version (Darwin):

import core.stdc.string : memcmp, memcpy, strlen, strrchr;
import core.sys.darwin.crt_externs : _NSGetMachExecuteHeader;
import core.sys.darwin.mach.dyld : _dyld_get_image_header, _dyld_get_image_name,
    _dyld_get_image_vmaddr_slide, _dyld_image_count;
import core.sys.darwin.mach.loader : load_command, mach_header, mach_header_64,
    section_64, segment_command_64, uuid_command, LC_SEGMENT_64, LC_UUID, MH_MAGIC_64;

/**
 * The running executable and the line table of its `.dSYM` bundle,
 * `<exe>.dSYM/Contents/Resources/DWARF/<exe name>`.
 *
 * The `.dSYM` holds link-time addresses, so a runtime address is a DWARF
 * address plus the executable's ASLR slide (`baseAddress`). A `.dSYM` counts
 * only when its CPU type and `LC_UUID` match the executable's: a stale one
 * would name wrong lines. Without one, the line table is empty and the caller
 * falls back to `atos`.
 */
struct Image
{
    private const(mach_header_64)* self;
    private size_t slide;
    private const(ubyte)[] dsymFile; // the mapped DWARF file of the .dSYM
    private const(ubyte)[] debugLine;

    @disable this(this);

    ~this() @nogc nothrow
    {
        if (dsymFile.length)
            unmapFile(dsymFile);
    }

    static Image openSelf() @nogc nothrow
    {
        Image image;
        image.self = _NSGetMachExecuteHeader();
        if (image.self is null)
            return image;

        foreach (i; 0 .. _dyld_image_count())
        {
            if (_dyld_get_image_header(i) !is cast(const(mach_header)*) image.self)
                continue;
            image.slide = cast(size_t) _dyld_get_image_vmaddr_slide(i);
            image.openDsym(_dyld_get_image_name(i));
            break;
        }
        return image;
    }

    @property bool isValid() @nogc nothrow
    {
        return self !is null;
    }

    T processDebugLineSectionData(T)(scope T delegate(const(ubyte)[]) processor)
    {
        return processor(debugLine);
    }

    @property size_t baseAddress() @nogc nothrow
    {
        return slide;
    }

private:

    /// Maps the `.dSYM` of the executable at `path`, trying the path with
    /// symbolic links resolved first, and keeps its `__debug_line`.
    void openDsym(const(char)* path) @nogc nothrow
    {
        import core.stdc.limits : PATH_MAX;
        import core.sys.posix.stdlib : realpath;

        if (path is null)
            return;
        char[PATH_MAX] resolved = void;
        if (realpath(path, resolved.ptr) !is null && tryDsymOf(resolved.ptr))
            return;
        tryDsymOf(path);
    }

    bool tryDsymOf(const(char)* exePath) @nogc nothrow
    {
        import core.stdc.limits : PATH_MAX;

        enum dsymDir = ".dSYM/Contents/Resources/DWARF/";
        const exeLength = strlen(exePath);
        const slash = strrchr(exePath, '/');
        const name = slash ? slash + 1 : exePath;
        const nameLength = exeLength - (name - exePath);

        char[PATH_MAX] dsymPath = void;
        if (exeLength + dsymDir.length + nameLength + 1 > dsymPath.length)
            return false;
        auto p = dsymPath.ptr;
        memcpy(p, exePath, exeLength);
        p += exeLength;
        memcpy(p, dsymDir.ptr, dsymDir.length);
        p += dsymDir.length;
        memcpy(p, name, nameLength);
        p[nameLength] = '\0';

        auto file = mapFile(dsymPath.ptr);
        if (!file.length)
            return false;
        auto line = dwarfSection(file, self, "__debug_line");
        if (!line.length)
        {
            unmapFile(file);
            return false;
        }
        dsymFile = file;
        debugLine = line;
        return true;
    }
}

private:

/// Maps the whole file at `path` read-only, or returns `null`.
const(ubyte)[] mapFile(const(char)* path) @nogc nothrow
{
    import core.sys.posix.fcntl : open, O_RDONLY;
    import core.sys.posix.sys.mman : mmap, MAP_FAILED, MAP_PRIVATE, PROT_READ;
    import core.sys.posix.sys.stat : fstat, stat_t;
    import core.sys.posix.unistd : close;

    const fd = open(path, O_RDONLY);
    if (fd < 0)
        return null;
    scope (exit) close(fd);

    stat_t st;
    if (fstat(fd, &st) != 0 || st.st_size < mach_header_64.sizeof)
        return null;
    const size = cast(size_t) st.st_size;
    auto data = mmap(null, size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (data is MAP_FAILED)
        return null;
    return (cast(const(ubyte)*) data)[0 .. size];
}

void unmapFile(const(ubyte)[] file) @nogc nothrow
{
    import core.sys.posix.sys.mman : munmap;

    munmap(cast(void*) file.ptr, file.length);
}

/**
 * The `__DWARF` section `name` of the Mach-O `file`, or `null` unless `file`
 * is a 64-bit Mach-O for the executable `exe`: the same CPU type and, when
 * the executable has one, the same `LC_UUID`.
 *
 * Every offset is checked against the bounds of `file`.
 */
const(ubyte)[] dwarfSection(const(ubyte)[] file, const(mach_header_64)* exe,
                            const(char)[] name) @nogc nothrow
{
    auto header = cast(const(mach_header_64)*) file.ptr;
    if (header.magic != MH_MAGIC_64 || header.cputype != exe.cputype)
        return null;
    if (mach_header_64.sizeof + header.sizeofcmds > file.length)
        return null;
    const commands = file[mach_header_64.sizeof .. mach_header_64.sizeof + header.sizeofcmds];

    const exeCommands = (cast(const(ubyte)*) (exe + 1))[0 .. exe.sizeofcmds];
    if (const exeUuid = findUuid(exeCommands, exe.ncmds))
    {
        const dsymUuid = findUuid(commands, header.ncmds);
        if (dsymUuid is null || memcmp(exeUuid, dsymUuid, 16) != 0)
            return null;
    }

    const(ubyte)[] result;
    forEachCommand(commands, header.ncmds, (const(load_command)* lc, const(ubyte)[] cmd) {
        if (lc.cmd != LC_SEGMENT_64 || cmd.length < segment_command_64.sizeof)
            return false;
        auto segment = cast(const(segment_command_64)*) lc;
        if (!fixedNameIs(segment.segname, "__DWARF"))
            return false;
        if (segment_command_64.sizeof + segment.nsects * section_64.sizeof > cmd.length)
            return true;
        foreach (ref section; (cast(const(section_64)*) (segment + 1))[0 .. segment.nsects])
        {
            if (!fixedNameIs(section.sectname, name))
                continue;
            if (section.offset + section.size <= file.length)
                result = file[section.offset .. cast(size_t) (section.offset + section.size)];
            break;
        }
        return true;
    });
    return result;
}

/// The 16 bytes of the `LC_UUID` among `commands`, or `null`.
const(ubyte)* findUuid(const(ubyte)[] commands, uint ncmds) @nogc nothrow
{
    const(ubyte)* uuid;
    forEachCommand(commands, ncmds, (const(load_command)* lc, const(ubyte)[] cmd) {
        if (lc.cmd != LC_UUID || cmd.length < uuid_command.sizeof)
            return false;
        uuid = (cast(const(uuid_command)*) lc).uuid.ptr;
        return true;
    });
    return uuid;
}

/// Calls `visit` on each well-formed load command until it returns `true`.
void forEachCommand(const(ubyte)[] commands, uint ncmds,
                    scope bool delegate(const(load_command)*, const(ubyte)[]) @nogc nothrow visit)
    @nogc nothrow
{
    foreach (_; 0 .. ncmds)
    {
        if (commands.length < load_command.sizeof)
            return;
        auto lc = cast(const(load_command)*) commands.ptr;
        if (lc.cmdsize < load_command.sizeof || lc.cmdsize > commands.length)
            return;
        if (visit(lc, commands[0 .. lc.cmdsize]))
            return;
        commands = commands[lc.cmdsize .. $];
    }
}

/// Whether the NUL-padded, fixed-width Mach-O name `field` is `name`.
bool fixedNameIs(ref const(char)[16] field, const(char)[] name) @nogc nothrow
{
    if (name.length > field.length || field[0 .. name.length] != name)
        return false;
    return name.length == field.length || field[name.length] == '\0';
}
