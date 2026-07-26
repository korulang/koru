// MIRROR of 340_011_constructor_generates_struct: `std/constructor:struct`
// building a type from a LINQ range of field specs, inside an imported .kz
// module.
//
// The constructor mints a type whose FIELD NAMES are computed at comptime
// (`v{i}`), then host code in the same module constructs it. A transform that
// generates names rather than copying them is the case where a wrong namespace
// would be hardest to see by reading.
import app/lib

app/lib:run()
