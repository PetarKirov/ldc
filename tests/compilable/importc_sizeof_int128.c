// ImportC has no 128-bit integer type, so importc.h hides clang's
// `__SIZEOF_INT128__`, which headers test before using `__int128` (Linux's
// linux/types.h, macOS's SDK).

// RUN: %ldc -c %s -of=%t%obj

#ifdef __SIZEOF_INT128__
typedef signed __int128 s128;
#endif

int answer(void) { return 42; }
