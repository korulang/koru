// PIN (outside-in finding, human-authored): move the 510_115 mistake ONE POSITION
// down the chain and KORU047 does not fire. The event is declared, invoked, and
// has no implementation. The program compiles, links, runs, and exits 0.
//
// Observed 2026-07-30: `✓ Built executable: a.out`, output "From network:
// Hello, World!", exit 0.
//
// KORU047's own sentence is the specification this violates: "event X is invoked
// but has no implementation — WITHOUT ONE THE COMPILER WOULD SILENTLY STUB IT TO
// RETURN ZERO-DEFAULTS." That is precisely what happens here. The diagnostic
// names the exact hazard, and then only guards position one against it.
//
// This is the positional axis of
// [[frag-the-minimal-test-of-a-wall-cannot-test-its-reach]], and the same shape
// as 510_109 (KORU022 branch coverage) and 510_110/111 (KORU100 unused bind).
// The difference in severity: KORU022's escape dies later in Zig, loudly. This
// one does not die at all. See 510_117 for what it produces instead.
//
// Provenance: Lars deleted line 7 of koru-examples/human-doodle/doodle.k — the
// whole `validate-response -> response` implementation — and reported that it
// still compiled and ran. It does.
import std/io

tor get-from-network {} -> string<tainted!>
get-from-network -> "Hello, World!"

tor validate-response { response: string<!tainted> } -> string

get-from-network(): response
|> validate-response(response)
|> std/io:print.ln("From network: {{response:s}}")
