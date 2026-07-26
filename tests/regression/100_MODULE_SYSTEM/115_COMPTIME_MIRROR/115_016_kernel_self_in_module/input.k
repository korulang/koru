// MIRROR of 390_040_self_basic: `std/kernel:shape` as a module declaration with
// `kernel:init` feeding `kernel:self` through continuations.
//
// 115_005 pins kernel's init on the boundary in isolation; this pins the shape
// the library is actually written for, so a fix that only satisfies the bare
// init does not read as complete. The init opens a source block on the
// subflow-definition line — legal since 210_168, and this mirror could not be
// written at all before that.
import app/lib

app/lib:run()
