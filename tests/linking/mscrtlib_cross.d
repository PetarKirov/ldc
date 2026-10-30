// Cross-linking for MSVC from another host with an explicit MS C runtime
// (the Windows SDK's libraries supplied by the user) links that runtime's
// vcruntime too, as with Visual C++; it used to fail an assertion.

// REQUIRES: target_X86, internal_lld
// UNSUPPORTED: Windows

// The link itself fails (no Windows libraries here); -vv logs its arguments.
// RUN: not %ldc -mtriple=x86_64-pc-windows-msvc -link-internally -mscrtlib=msvcrt -vv %s -of=%t.exe 2>&1 | FileCheck %s
// CHECK: '/DEFAULTLIB:msvcrt'
// CHECK-SAME: '/DEFAULTLIB:vcruntime'

void main() {}
