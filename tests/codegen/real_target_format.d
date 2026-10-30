// The front-end folds `real` in the target's format, whichever the host's
// is: a quadruple-precision target's constants are exact on an x87 or macOS
// host too (LDC_REAL_APFLOAT, dmd/root/longdouble.h).

// REQUIRES: real_apfloat, target_X86, target_AArch64, target_WebAssembly

// RUN: %ldc -mtriple=wasm32-unknown-wasip1 -output-ll -of=%t.wasm.ll %s
// RUN: FileCheck %s --check-prefix=QUAD < %t.wasm.ll
// RUN: %ldc -mtriple=aarch64-linux-gnu -output-ll -of=%t.aarch64.ll %s
// RUN: FileCheck %s --check-prefix=QUAD < %t.aarch64.ll
// RUN: %ldc -mtriple=x86_64-linux-gnu -output-ll -of=%t.x86_64.ll %s
// RUN: FileCheck %s --check-prefix=X87 < %t.x86_64.ll

import core.math : sqrt;

// One ulp above one is representable, half an ulp rounds away.
static assert(1.0L + real.epsilon != 1.0L);
static assert(1.0L + real.epsilon / 2 == 1.0L);
static assert(real.max * 2 == real.infinity);

// QUAD-LABEL: define {{.*}}third
// QUAD: ret fp128 f0x3FFD5555555555555555555555555555
// X87-LABEL: define {{.*}}third
// X87: ret x86_fp80 f0x3FFDAAAAAAAAAAAAAAAB
real third() { return 1.0L / 3; }

// The correctly rounded square root, in CTFE.
enum root2 = sqrt(2.0L);
// QUAD-LABEL: define {{.*}}squareRootOfTwo
// QUAD: ret fp128 f0x3FFF6A09E667F3BCC908B2FB1366EA95
// X87-LABEL: define {{.*}}squareRootOfTwo
// X87: ret x86_fp80 f0x3FFFB504F333F9DE6484
real squareRootOfTwo() { return root2; }

// QUAD-LABEL: define {{.*}}largest
// QUAD: ret fp128 f0x7FFEFFFFFFFFFFFFFFFFFFFFFFFFFFFF
// X87-LABEL: define {{.*}}largest
// X87: ret x86_fp80 f0x7FFEFFFFFFFFFFFFFFFF
real largest() { return real.max; }

// Where the host's `long double` is narrower than the target's `real`, CTFE
// runs Phobos' own implementation of `exp` (and `log`, `pow`), in the target's
// format, rather than the host's math library.
import std.math.exponential : exp;
enum euler = exp(1.0L);
// QUAD-LABEL: define {{.*}}eulersNumber
// QUAD: ret fp128 f0x40005BF0A8B1457695355FB8AC404E7A
real eulersNumber() { return euler; }
