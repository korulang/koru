// The implicit expression slot, filled from the ENTRY file. `echo(hello)` has
// no label: the callee declares `expr: Expression`, so the bare argument IS
// that slot and reaches the transform's AST under the name `expr`.
//
// Twin of 110_023, which pins the same rule for an invocation inside an
// imported module. This one holds the entry-file axis.
import app/lib2

app/lib2:echo(hello)
