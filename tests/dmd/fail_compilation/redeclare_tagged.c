/* TEST_OUTPUT:
---
fail_compilation/redeclare_tagged.c(13): Error: redefinition of `x` with different type: `struct S` vs `const struct S`
fail_compilation/redeclare_tagged.c(14): Error: redefinition of `y` with different type: `struct S` vs `union S`
---
*/

/* The tag's kind and its qualifiers still distinguish types. */

struct S { int a; };
extern struct S x;
extern struct S y;
extern const struct S x;
extern union S y;
