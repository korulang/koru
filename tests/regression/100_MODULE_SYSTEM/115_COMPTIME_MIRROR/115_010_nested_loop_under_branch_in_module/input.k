// Nested `for` / `! each` where the INNER loop sits under a branch arm of an
// `if`, inside a module tor. No synthesizing library.
//
// 115_008 pins that a directly-nested loop in a module gets distinct capture
// names; this pins the same question when a branch arm intervenes between the
// two loops, which is the shape every real sieve has.
import app/lib

app/lib:run()
