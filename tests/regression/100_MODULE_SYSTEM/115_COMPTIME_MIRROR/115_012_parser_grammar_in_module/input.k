// MIRROR of 641_005_ordered_choice_same_head: a `[with]std/parser:grammar`
// declaration and its `std/parser:parse` use, both relocated into an imported
// module.
//
// parser is a SYNTHESIZING library — the grammar declaration appends the
// compiled rule machinery and `parse` refers to it by name. Both halves move
// together, so this pins the declaration-position and flow-position shapes at
// once for the library where the grammar's home decides what `parse` resolves.
import app/lib

app/lib:run()
