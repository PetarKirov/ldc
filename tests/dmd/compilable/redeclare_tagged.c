/* A variable of struct, union or enum type may be declared again: before
 * semantic, each mention of the tag is a type of its own.
 */

struct S;
extern const struct S x;    // the tag is incomplete
struct S { int a; };
extern const struct S x;
extern const struct S x;

union U { int i; float f; };
extern union U u;
extern union U u;

enum E { e0, e1 };
extern enum E e;
extern enum E e;
