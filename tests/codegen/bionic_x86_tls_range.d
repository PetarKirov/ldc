// On x86 Linux, a static druntime computes its TLS range as a static offset
// below the TCB, so as not to depend on __tls_get_addr. Bionic is excluded:
// its static druntime is routinely linked into a dlopen'd shared library,
// whose TLS block is dynamic, so the range comes from __tls_get_addr there,
// as it does on every other Bionic target.

// REQUIRES: target_X86

// RUN: %ldc -mtriple=x86_64-unknown-linux-android29 -output-ll -of=%t-android.ll %runtimedir/src/rt/sections_elf_shared.d
// RUN: FileCheck %s < %t-android.ll
// RUN: %ldc -mtriple=i686-unknown-linux-android29 -output-ll -of=%t-android32.ll %runtimedir/src/rt/sections_elf_shared.d
// RUN: FileCheck %s < %t-android32.ll
// RUN: %ldc -mtriple=x86_64-unknown-linux-gnu -output-ll -of=%t-glibc.ll %runtimedir/src/rt/sections_elf_shared.d
// RUN: FileCheck --check-prefix=GLIBC %s < %t-glibc.ll

// CHECK-LABEL: define {{.*}}@_D2rt19sections_elf_shared11getTLSRangeF
// CHECK-NOT: {{^}}}
// CHECK: call {{.*}}@{{_+}}tls_get_addr(

// GLIBC-LABEL: define {{.*}}@_D2rt19sections_elf_shared11getTLSRangeF
// GLIBC-NOT: tls_get_addr
// GLIBC: {{^}}}
