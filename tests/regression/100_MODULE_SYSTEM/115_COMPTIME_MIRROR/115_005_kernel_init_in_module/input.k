// MIRROR of 390_022_singleline_shape_bug: the `std/kernel:shape` + `kernel:init`
// declarations relocated into an imported module.
//
// This is the DECLARATION-position mirror shape — the transform is a top-level
// item of the module rather than the body of a tor, the same position
// `std/store:new` holds in 690_079's lib.k. kernel synthesizes an init tor and
// then calls it by a name minted from the declaring file, which is a different
// name from the one an importer resolves against.
import app/lib

app/lib:run()
