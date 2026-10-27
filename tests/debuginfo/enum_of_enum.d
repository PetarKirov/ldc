// An enum based on another enum: its DWARF enumeration gets the underlying
// integer type as its base, not the other enumeration. With an enumeration as
// the base, LLVM asserted (`isUnsignedDIType`) when it emitted a constant of
// the outer type, as druntime's `core.stdc.stdatomic` unittests do at -O -g.

// RUN: %ldc -g -O -output-ll -of=%t.ll %s && FileCheck %s < %t.ll
// RUN: %ldc -g -O -c -of=%t%obj %s

enum Inner : int { a = 1, b = 5 }
enum Outer : Inner { x = Inner.a, y = Inner.b }

__gshared int sink;

pragma(inline, true) void use(Outer o) { sink = o == Outer.y ? 1 : 2; }

// Inlined, `o` becomes a constant debug value of type `Outer`.
void callsWithConstant() { use(Outer.y); }

// CHECK-DAG: !DICompositeType(tag: DW_TAG_enumeration_type, name: "Outer"{{.*}}baseType: ![[INT:[0-9]+]]
// CHECK-DAG: ![[INT]] = !DIBasicType(name: "int"
