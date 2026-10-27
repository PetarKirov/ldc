// On Darwin, a link with debug info gathers it into a .dSYM, as clang does:
// the binary only maps to the object files' DWARF.

// REQUIRES: Darwin

// RUN: rm -rf %t.dSYM %t-nodebug.dSYM
// RUN: %ldc -g %s -of=%t
// RUN: test -d %t.dSYM/Contents/Resources/DWARF
// RUN: %ldc %s -of=%t-nodebug
// RUN: not test -e %t-nodebug.dSYM

void main() {}
