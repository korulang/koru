// MIRROR of 340_001_struct_basic: `std/types:struct` declaring a nominal struct
// inside an imported .kz module.
//
// First .kz mirror on the wall — the module is host-embedded, so the transform
// declares a type that host code in the SAME module then constructs. The
// declaration and its use stay together because the emitted type lives in that
// module's scope; what moves is which scope that is.
import app/lib

app/lib:run()
