// MIRROR of 2106_prime_sieve_bitfield: the `std/field:new` sieve relocated into
// an imported module.
//
// `field` appends one declaration, which put it in the synthesizing class
// alongside store, regex, kernel and parser — but unlike those four it was never
// probed across a boundary, so which side of the line it falls on is what this
// pins. A capture-shadowing symptom seen elsewhere in field was never tied to
// module placement either way.
import app/lib

app/lib:run()
