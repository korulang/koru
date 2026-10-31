---
type: belief
id: frag-a-returned-managed-wants-errdefer-never-defer
provenance: the transcendental rung printed garbage digits then double-freed; the math was right, the return contract was not
ts: 2026-10-31
---

# A returned Managed wants errdefer, never defer (belief)

`fxSinSmall` ended `var sum = try u.clone(); defer sum.deinit(); ... return
sum;`. `std.math.big.int.Managed` is a struct whose limbs live behind a
pointer: returning `sum` copies the struct, the `defer` frees the limb buffer,
and the caller receives a dangling `Managed`. The first symptom was not the
crash — `decToString` read the freed limbs back as plausible-looking digits
(`sin(pi/2)` printed `4.18e7`), and only `decDeinit` turned it into a detected
double-free. A memory bug masqueraded as a math bug; the correct-looking wrong
answer is the dangerous part, not the segfault.

The ruling: **a local that is returned by value takes `errdefer`, never
`defer`.** `defer` means "I still own this at scope exit"; `return x` means
"the caller owns it now." They cannot both be true. The correct pattern in the
same file already existed — `fxExpSmall`, `fxAtanInv`, `fxLnF` all hold the
result under `errdefer` or no defer at all and move it out; the two broken
functions had been written by copying the *consumed-value* idiom onto the
*returned-value* position.

The subtler neighbour: `var u = try r.clone(); defer u.deinit();` followed by
conditional `u.deinit(); u = try other.clone();` is lawful — `defer` evaluates
the variable at scope exit and frees whatever it currently holds, the manual
deinit settles the old value. Reassignment-then-defer is fine; return-then-defer
is not. The difference is one line and the failure mode is silent until the
second free.

Related: [[frag-a-refusal-arm-payload-is-an-ownership-question]] — same axiom
one layer up: ownership follows the declared crossing, and a crossing that is
never declared (a value returned past its own `defer`) is invisible to every
check until the heap notices.
