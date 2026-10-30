//===-- ctfloat.cpp -------------------------------------------------------===//
//
//                         LDC – the LLVM D compiler
//
// This file is distributed under the BSD-style LDC license. See the LICENSE
// file for details.
//
//===----------------------------------------------------------------------===//

#include "dmd/root/ctfloat.h"
#include "gen/llvm.h"
#include "llvm/ADT/APSInt.h"
#include "llvm/ADT/SmallString.h"
#include "llvm/Support/Error.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

using llvm::APFloat;

namespace {

const llvm::fltSemantics *apSemantics = nullptr;

#if !defined(LDC_real_apfloat)
constexpr unsigned numUint64Parts = (sizeof(real_t) + 7) / 8;
union CTFloatUnion {
  real_t fp;
  uint64_t bits[numUint64Parts];
};
#endif

APFloat parseLiteral(const llvm::fltSemantics &semantics, const char *literal,
                     bool *isOutOfRange = nullptr) {
  APFloat ap(semantics, APFloat::uninitialized);
  auto r = llvm::cantFail(
      ap.convertFromString(literal, APFloat::rmNearestTiesToEven));
  if (isOutOfRange) {
    *isOutOfRange = (r & (APFloat::opOverflow | APFloat::opUnderflow)) != 0;
  }
  return ap;
}

} // anonymous namespace

////////////////////////////////////////////////////////////////////////////////
// LDC_real_apfloat: real_t is a longdouble_ap (dmd/root/longdouble.h), whose
// arithmetic is done here in apSemantics, the target's `real` format.

#if defined(LDC_real_apfloat)

namespace {

const llvm::fltSemantics &quad() { return APFloat::IEEEquad(); }

// The host's `long double`, for conversions and the functions computed with
// the host's math library.
const llvm::fltSemantics &hostSemantics() {
  constexpr int digits = std::numeric_limits<long double>::digits;
  if (digits == 53)
    return APFloat::IEEEdouble();
  if (digits == 64)
    return APFloat::x87DoubleExtended();
  if (digits == 113)
    return APFloat::IEEEquad();
  llvm_unreachable("Unknown host long double type");
}

APFloat convert(APFloat v, const llvm::fltSemantics &semantics,
                APFloat::roundingMode rm = APFloat::rmNearestTiesToEven) {
  bool losesInfo;
  v.convert(semantics, rm, &losesInfo);
  return v;
}

// The value in apSemantics. Every value of it is exact in a quadruple.
APFloat unpack(longdouble_ap x) {
  return convert(APFloat(quad(), llvm::APInt(128, llvm::ArrayRef<uint64_t>(x.bits, 2))), *apSemantics);
}

// Rounds to apSemantics, then stores the (exact) quadruple bits.
longdouble_ap pack(const APFloat &v) {
  const llvm::APInt bits =
      convert(convert(v, *apSemantics), quad()).bitcastToAPInt();
  longdouble_ap r;
  r.bits[0] = bits.getRawData()[0];
  r.bits[1] = bits.getRawData()[1];
  return r;
}

APFloat fromHost(long double v) {
  const llvm::fltSemantics &semantics = hostSemantics();
  uint64_t words[2] = {0, 0};
  memcpy(words, &v, std::min(sizeof(v), sizeof(words)));
  return APFloat(semantics,
                 llvm::APInt(APFloat::getSizeInBits(semantics), words));
}

long double toHost(const APFloat &v) {
  const llvm::APInt bits = convert(v, hostSemantics()).bitcastToAPInt();
  long double r = 0;
  memcpy(&r, bits.getRawData(),
         std::min(sizeof(r), size_t(bits.getNumWords() * 8)));
  return r;
}

APFloat fromInteger(uint64_t v, bool isSigned) {
  APFloat r(*apSemantics);
  r.convertFromAPInt(llvm::APInt(64, v, isSigned), isSigned,
                     APFloat::rmNearestTiesToEven);
  return r;
}

// x86's "integer indefinite", for NaNs and values out of range.
constexpr uint64_t integerIndefinite = 0x8000000000000000ULL;

uint64_t toInteger(const APFloat &v, bool isSigned) {
  if (v.isNaN())
    return integerIndefinite;
  llvm::APSInt result(64, /*isUnsigned=*/!isSigned);
  bool isExact;
  if (v.convertToInteger(result, APFloat::rmTowardZero, &isExact) &
      APFloat::opInvalidOp)
    return integerIndefinite;
  return result.getZExtValue();
}

longdouble_ap roundToIntegral(longdouble_ap x, APFloat::roundingMode rm) {
  APFloat v = unpack(x);
  v.roundToIntegral(rm);
  return pack(v);
}

// floor(sqrt(n)) and whether it is inexact
llvm::APInt isqrt(const llvm::APInt &n, bool &inexact) {
  const unsigned width = n.getBitWidth();
  llvm::APInt rem = n, res(width, 0), bit(width, 0);
  if (n.isZero()) {
    inexact = false;
    return res;
  }
  bit.setBit((n.getActiveBits() - 1) & ~1u); // highest power of 4 <= n
  while (!bit.isZero()) {
    const llvm::APInt trial = res + bit;
    res.lshrInPlace(1);
    if (rem.uge(trial)) {
      rem -= trial;
      res += bit;
    }
    bit.lshrInPlace(2);
  }
  inexact = !rem.isZero();
  return res;
}

// The correctly rounded square root in apSemantics.
APFloat sqrtAP(const APFloat &x) {
  if (x.isNaN() || x.isZero() || (x.isInfinity() && !x.isNegative()))
    return x;
  if (x.isNegative())
    return APFloat::getQNaN(x.getSemantics());

  // x = m * 2^e with m an integer of p bits
  const unsigned p = APFloat::semanticsPrecision(x.getSemantics());
  int exp;
  const APFloat fraction = llvm::frexp(x, exp, APFloat::rmNearestTiesToEven);
  llvm::APSInt m(p + 1, /*isUnsigned=*/true);
  bool isExact;
  llvm::scalbn(fraction, p, APFloat::rmNearestTiesToEven)
      .convertToInteger(m, APFloat::rmTowardZero, &isExact);
  int e = exp - static_cast<int>(p);

  // n = m * 2^s, with s making e - s even and n wide enough that its root
  // has two bits below the result's precision: the rounding and sticky bits.
  int s = static_cast<int>(p) + 4;
  if ((e - s) & 1)
    ++s;
  const unsigned width = 2 * p + 16;
  const llvm::APInt n = m.zext(width).shl(s);

  bool inexact;
  llvm::APInt root = isqrt(n, inexact).shl(1);
  if (inexact)
    root.setBit(0);

  APFloat r(x.getSemantics());
  r.convertFromAPInt(root, false, APFloat::rmNearestTiesToEven);
  return llvm::scalbn(r, (e - s) / 2 - 1, APFloat::rmNearestTiesToEven);
}

template <typename F> longdouble_ap viaHost(longdouble_ap x, F f) {
  return pack(fromHost(f(toHost(unpack(x)))));
}

} // anonymous namespace

void CTFloat::setTargetSemantics(const llvm::fltSemantics &semantics) {
  // A double-double's values are not all exact in a quadruple; fold its
  // `real` as a quadruple, and round when emitting it.
  apSemantics = &semantics == &APFloat::PPCDoubleDouble() ? &quad() : &semantics;

  zero = 0;
  one = 1;
  minusone = -1;
  half = 0.5;
  nan = pack(APFloat::getQNaN(*apSemantics));
  infinity = pack(APFloat::getInf(*apSemantics));
}

bool CTFloat::hostMathHasRealPrecision() {
  return APFloat::semanticsPrecision(hostSemantics()) >=
         APFloat::semanticsPrecision(*apSemantics);
}

longdouble_ap ld_ap_from_int64(ld_ap_int64 v) { return pack(fromInteger(v, true)); }
longdouble_ap ld_ap_from_uint64(ld_ap_uint64 v) { return pack(fromInteger(v, false)); }
longdouble_ap ld_ap_from_float(float v) { return pack(APFloat(v)); }
longdouble_ap ld_ap_from_double(double v) { return pack(APFloat(v)); }
longdouble_ap ld_ap_from_host(long double v) { return pack(fromHost(v)); }

float ld_ap_to_float(longdouble_ap x) {
  return convert(unpack(x), APFloat::IEEEsingle()).convertToFloat();
}
double ld_ap_to_double(longdouble_ap x) {
  return convert(unpack(x), APFloat::IEEEdouble()).convertToDouble();
}
long double ld_ap_to_host(longdouble_ap x) { return toHost(unpack(x)); }

ld_ap_int64 ld_ap_to_int64(longdouble_ap x) {
  return static_cast<ld_ap_int64>(toInteger(unpack(x), true));
}
ld_ap_uint64 ld_ap_to_uint64(longdouble_ap x) {
  const APFloat v = unpack(x);
  // a negative value wraps around, as it converts through a signed integer
  return v.isNegative() && !v.isNaN() ? toInteger(v, true)
                                      : toInteger(v, false);
}

#define LD_AP_BINARY(name, op)                                                 \
  longdouble_ap ld_ap_##name(longdouble_ap x, longdouble_ap y) {               \
    APFloat v = unpack(x);                                                     \
    v.op(unpack(y), APFloat::rmNearestTiesToEven);                             \
    return pack(v);                                                            \
  }
LD_AP_BINARY(add, add)
LD_AP_BINARY(sub, subtract)
LD_AP_BINARY(mul, multiply)
LD_AP_BINARY(div, divide)
#undef LD_AP_BINARY

longdouble_ap ld_ap_mod(longdouble_ap x, longdouble_ap y) {
  APFloat v = unpack(x);
  v.mod(unpack(y)); // fmod: exact
  return pack(v);
}

int ld_ap_cmp(longdouble_ap x, longdouble_ap y) {
  switch (unpack(x).compare(unpack(y))) {
  case APFloat::cmpLessThan:
    return -1;
  case APFloat::cmpEqual:
    return 0;
  case APFloat::cmpGreaterThan:
    return 1;
  case APFloat::cmpUnordered:
    return 2;
  }
  llvm_unreachable("Unknown APFloat comparison result");
}

// Exact in apSemantics:
real_t CTFloat::sqrt(real_t x) { return pack(sqrtAP(unpack(x))); }
real_t CTFloat::fabs(real_t x) { return pack(llvm::abs(unpack(x))); }
real_t CTFloat::ldexp(real_t n, int exp) {
  return pack(llvm::scalbn(unpack(n), exp, APFloat::rmNearestTiesToEven));
}
real_t CTFloat::copysign(real_t x, real_t s) {
  APFloat v = unpack(x);
  v.copySign(unpack(s));
  return pack(v);
}
real_t CTFloat::round(real_t x) {
  return roundToIntegral(x, APFloat::rmNearestTiesToAway);
}
real_t CTFloat::floor(real_t x) {
  return roundToIntegral(x, APFloat::rmTowardNegative);
}
real_t CTFloat::ceil(real_t x) {
  return roundToIntegral(x, APFloat::rmTowardPositive);
}
real_t CTFloat::trunc(real_t x) {
  return roundToIntegral(x, APFloat::rmTowardZero);
}
real_t CTFloat::rint(real_t x) {
  return roundToIntegral(x, APFloat::rmNearestTiesToEven);
}
real_t CTFloat::nearbyint(real_t x) {
  return roundToIntegral(x, APFloat::rmNearestTiesToEven);
}

// With the host's math library, so as precise as its `long double`:
real_t CTFloat::sin(real_t x) { return viaHost(x, [](long double v) { return sinl(v); }); }
real_t CTFloat::cos(real_t x) { return viaHost(x, [](long double v) { return cosl(v); }); }
real_t CTFloat::tan(real_t x) { return viaHost(x, [](long double v) { return tanl(v); }); }
real_t CTFloat::log(real_t x) { return viaHost(x, [](long double v) { return logl(v); }); }
real_t CTFloat::log2(real_t x) { return viaHost(x, [](long double v) { return log2l(v); }); }
real_t CTFloat::log10(real_t x) { return viaHost(x, [](long double v) { return log10l(v); }); }
real_t CTFloat::exp(real_t x) { return viaHost(x, [](long double v) { return expl(v); }); }
real_t CTFloat::expm1(real_t x) { return viaHost(x, [](long double v) { return expm1l(v); }); }
real_t CTFloat::exp2(real_t x) { return viaHost(x, [](long double v) { return exp2l(v); }); }
real_t CTFloat::pow(real_t x, real_t y) {
  return pack(fromHost(powl(toHost(unpack(x)), toHost(unpack(y)))));
}

#endif // LDC_real_apfloat

////////////////////////////////////////////////////////////////////////////////

void CTFloat::initialize() {
  if (apSemantics)
    return;

#if defined(LDC_real_apfloat)
  // The host's format until Target::_init sets the target's.
  setTargetSemantics(hostSemantics());
  return;
#elif defined(_MSC_VER)
  // MSVC hosts use dmd.root.longdouble (80-bit x87)
  apSemantics = &APFloat::x87DoubleExtended();
#else
  static_assert(std::numeric_limits<real_t>::is_specialized,
                "real_t is not an arithmetic type");
  constexpr int digits = std::numeric_limits<real_t>::digits;
  if (digits == 53) {
    apSemantics = &APFloat::IEEEdouble();
  } else if (digits == 64) {
    apSemantics = &APFloat::x87DoubleExtended();
  } else if (digits == 113) {
    apSemantics = &APFloat::IEEEquad();
  } else if (digits == 106) {
    apSemantics = &APFloat::PPCDoubleDouble();
  } else {
    llvm_unreachable("Unknown host real_t type for compile-time reals");
  }
#endif

  zero = 0;
  one = 1;
  minusone = -1;
  half = 0.5;

  nan = fromAPFloat(APFloat::getQNaN(*apSemantics));
  infinity = fromAPFloat(APFloat::getInf(*apSemantics));
}

////////////////////////////////////////////////////////////////////////////////

void CTFloat::toAPFloat(const real_t src, APFloat &dst) {
#if defined(LDC_real_apfloat)
  dst = unpack(src);
#else
  if (sizeof(real_t) == 8) {
    dst = APFloat(static_cast<double>(src));
    return;
  }

  CTFloatUnion u;
  u.fp = src;

  const unsigned sizeInBits = APFloat::getSizeInBits(*apSemantics);
#if LLVM_VERSION_MAJOR >= 22
  const APInt bits = APInt(sizeInBits, u.bits);
#else
  const APInt bits = APInt(sizeInBits, numUint64Parts, u.bits);
#endif

  dst = APFloat(*apSemantics, bits);
#endif
}

////////////////////////////////////////////////////////////////////////////////

real_t CTFloat::fromAPFloat(const APFloat &src_) {
#if defined(LDC_real_apfloat)
  return pack(src_);
#else
  APFloat src = src_;
  if (&src.getSemantics() != apSemantics) {
    bool ignored;
    src.convert(*apSemantics, APFloat::rmNearestTiesToEven, &ignored);
  }

  const APInt bits = src.bitcastToAPInt();

  CTFloatUnion u;
  memcpy(u.bits, bits.getRawData(), bits.getBitWidth() / 8);
  return u.fp;
#endif
}

////////////////////////////////////////////////////////////////////////////////

real_t CTFloat::parse(const char *literal, bool &isOutOfRange) {
  const APFloat ap = parseLiteral(*apSemantics, literal, &isOutOfRange);
  return fromAPFloat(ap);
}

bool CTFloat::isFloat32LiteralOutOfRange(const char *literal) {
  bool isOutOfRange;
  parseLiteral(APFloat::IEEEsingle(), literal, &isOutOfRange);
  return isOutOfRange;
}

bool CTFloat::isFloat64LiteralOutOfRange(const char *literal) {
  bool isOutOfRange;
  parseLiteral(APFloat::IEEEdouble(), literal, &isOutOfRange);
  return isOutOfRange;
}

////////////////////////////////////////////////////////////////////////////////

int CTFloat::sprint(char *str, size_t str_buf_length, char fmt, real_t x) {
  assert(fmt == 'g' || fmt == 'a' || fmt == 'A');
  const bool uppercase = fmt == 'A';

  // We try to keep close to C printf and handle a few divergences of the LLVM
  // to-string utility functions.

  // For simplicity later on, do not accept values of str_buf_length below 5.
  if (str_buf_length < 5)
    return 0;

  if (isNaN(x)) {
    size_t length = 0;
    if (copysign(one, x) != one) {
      str[0] = '-';
      ++length;
    }
    if (length > str_buf_length-4)
      length = str_buf_length-4;
    memcpy(str + length, uppercase ? "NAN" : "nan", 3);
    length += 3;
    str[length] = 0;
    return length;
  }

  if (isInfinity(x)) { // incl. -inf
    size_t length = 0;
    if (x < 0) {
      str[0] = '-';
      ++length;
    }
    if (length > str_buf_length-4)
      length = str_buf_length-4;
    memcpy(str + length, uppercase ? "INF" : "inf", 3);
    length += 3;
    str[length] = 0;
    return length;
  }

  // Use LLVM for printing hex strings.
  if (fmt == 'a' || fmt == 'A') {
    APFloat ap(0.0);
    toAPFloat(x, ap);

    size_t length =
        ap.convertToHexString(str, 0, uppercase, APFloat::rmNearestTiesToEven);

    if (length > str_buf_length-1)
      length = str_buf_length-1;

    // insert a '+' prefix for non-negative exponents (incl. 0) as visual aid
    const char p = uppercase ? 'P' : 'p';
    for (int i = length - 2; i >= 0; --i) {
      if (str[i] == p) {
        if (str[i + 1] != '-' && str[i + 1] != '+') {
          for (int j = length - 1; j > i; --j)
            str[j + 1] = str[j];
          str[i + 1] = '+';
          ++length;
        }

        break;
      }
    }

    str[length] = 0;
    return length;
  }

  assert(fmt == 'g');

  // Use the host C runtime for printing decimal strings;
  // llvm::APFloat::toString() seems not to round correctly, e.g., with LLVM 10:
  // * powl(2.5L, 2.5L) = 9.882117688... => `9.88211` (not 9.88212)
  // * 1e-300L => `9.99999e-301`
#if defined(LDC_real_apfloat)
  // The host's `long double` prints 6 digits of any value in its range; LLVM
  // prints those outside it, like a quadruple's on an x87 or macOS host.
  size_t length;
  const APFloat ap = unpack(x);
  const long double host = toHost(ap);
  if (std::isfinite(host) && (host != 0 || ap.isZero())) {
    length = snprintf(str, str_buf_length - 1, "%Lg", host);
  } else {
    llvm::SmallString<32> s;
    ap.toString(s, /*FormatPrecision=*/6, /*FormatMaxPadding=*/0);
    length = std::min(s.size(), str_buf_length - 1);
    for (size_t i = 0; i < length; ++i)
      str[i] = s[i] == 'E' ? 'e' : s[i];
  }
#elif defined(_MSC_VER)
  size_t length = snprintf(str, str_buf_length-1, "%g", static_cast<double>(x));
#else
  size_t length = snprintf(str, str_buf_length-1, "%Lg", x);
#endif

  // 1 => 1.0 to distinguish from integers
  bool needsFPSuffix = true;
  for (size_t i = 0; i < length; ++i) {
    if (str[i] != '-' && !isdigit(str[i])) {
      needsFPSuffix = false;
      break;
    }
  }
  if (needsFPSuffix && (length < str_buf_length-3)) {
    memcpy(str + length, ".0", 2);
    length += 2;
  }

  str[length] = 0;
  return length;
}
