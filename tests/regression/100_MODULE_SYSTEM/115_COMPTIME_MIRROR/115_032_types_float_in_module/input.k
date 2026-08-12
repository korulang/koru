// MIRROR of 030_102_float_type: `float` declaring a nominal floating-point
// type inside an imported .kz module.
//
// Sibling of 115_031 on the other primitive. Kept separate because the types
// library mints one transform per primitive and a shared fault would show on
// both while a per-primitive one would not. Asserts output rather than a clean
// run, for the reason 115_036 demonstrates.
import app/lib

app/lib:run()
