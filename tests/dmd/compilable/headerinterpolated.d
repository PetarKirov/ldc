/*
REQUIRED_ARGS: -c -o- -Hf${RESULTS_DIR}/compilable/headerinterpolated.di
PERMUTE_ARGS:
OUTPUT_FILES: ${RESULTS_DIR}/compilable/headerinterpolated.di

TEST_OUTPUT:
---
=== ${RESULTS_DIR}/compilable/headerinterpolated.di
// D import file generated from 'compilable/headerinterpolated.d'
void f(Args...)(Args)
{
}
void g()(int n)
{
	f(i"a $(n) b");
}
---
*/

// An interpolated string is a primary expression: printing one as an
// argument must neither assert nor parenthesize it.
void f(Args...)(Args) {}
void g()(int n) { f(i"a $(n) b"); }
