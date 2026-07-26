// MIRROR of 390_021_multiline_source: `std/kernel:pairwise` over a module's own
// shape and init.
//
// Third kernel arm after 115_005 (bare init) and 115_016 (self). pairwise
// carries its body as a source block and expands to an O(n^2) form, so it
// exercises a different expansion than self does off the same init.
import app/lib

app/lib:run()
