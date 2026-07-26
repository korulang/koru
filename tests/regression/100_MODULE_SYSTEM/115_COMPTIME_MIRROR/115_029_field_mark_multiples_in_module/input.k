// MIRROR of 2109_prime_sieve_generated: `std/field:mark-multiples`, which emits
// a fully-unrolled per-stride marker at compile time, relocated into an
// imported module.
//
// 115_004 pins field:new on the boundary; this pins the library's generating
// transform, the one that bakes masks as immediate literals. Whether the two
// share a fault or fail separately is what the pair is for.
import app/lib

app/lib:run()
