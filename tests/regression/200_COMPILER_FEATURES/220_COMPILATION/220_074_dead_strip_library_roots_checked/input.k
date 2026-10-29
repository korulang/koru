// The strip-root law's live coverage — program compiles commit zero
// strip-root lines, so the seedExportedRoots machinery only ever saw
// synthetic corpora before this test. post.sh runs `koruc lib`, whose
// ledger must seed every pub entry-module event as a root and still
// strip the non-pub, never-invoked `internal-only`. The STRIP_AST_CHECK
// marker re-decides the primary (program-mode) ledger against
// program.ast.json; post.sh re-decides the lib ledger under --library,
// where roots == pub decls exactly.
import std/io
import std/witness

std/witness:enforce { }

pub tor exported-a { x: i32 } -> i32
exported-a -> x + 1

pub tor exported-b { y: i32 } -> i32
exported-b -> y * 2

// No impl: nothing invokes it and nothing implements it — in a program
// compile dead-strip removes it; under `koruc lib` the export itself is a
// root, which is the only thing that keeps it. This is the case the
// strip-root law actually decides.
pub tor exported-c { w: i32 } -> i32

tor internal-only { z: i32 } -> i32
internal-only -> z - 1

// Not pub, no impl, never invoked — removed in both modes; keeps the
// lib ledger's removal side non-empty for the oracle.
tor dead-weight { q: i32 } -> i32

exported-a(x: 20): d |> std/io:print.ln("{{ d:d }}")
