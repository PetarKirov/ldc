/**
 * D header file for WASI (WebAssembly System Interface).
 *
 * Copyright: Copyright (c) 2024 D Language Foundation
 * License: Distributed under the
 *      $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0).
 *    (See accompanying file LICENSE)
 */

module core.sys.wasi.core;

version (WASI):
extern (C):
@nogc:
nothrow:

alias __wasi_errno_t = ushort;

/// Fills a buffer with high-quality random data.
__wasi_errno_t __wasi_random_get(void* buf, size_t buf_len);

/// Returns the resolution of a clock.
__wasi_errno_t __wasi_clock_res_get(uint id, ulong* resolution);

/// Returns the time value of a clock.
__wasi_errno_t __wasi_clock_time_get(uint id, ulong precision, ulong* time);

enum __WASI_CLOCKID_REALTIME = 0;
enum __WASI_CLOCKID_MONOTONIC = 1;
enum __WASI_CLOCKID_PROCESS_CPUTIME_ID = 2;
enum __WASI_CLOCKID_THREAD_CPUTIME_ID = 3;
