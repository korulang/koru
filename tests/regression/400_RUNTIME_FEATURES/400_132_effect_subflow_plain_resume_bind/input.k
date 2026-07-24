// SUBFLOW-IMPLEMENTED EFFECTS, plain return (pure .k, no proc) — the subflow
// sibling of 400_116. `! ask i64 -> i64` is the single-payload resume; the
// proc side binds it with `const a = ask(q)`. The subflow side binds it with
// the established call-site `:` bind and continues with the established
// bind-then-construct form — `query = ask(q): a => done a` is byte-for-byte
// the 100_053 shape (`~process = compute(x: input): v => result v`), with the
// callee being the event's own arm instead of a declared event.
//
// Consumer side is already-landed grammar: `->` produces the resume value
// (400_116), so this test's red is entirely the impl side.
import std/io

pub tor query { q: i64 }
! ask i64 -> i64
| done i64

query = ask(q): a => done a

query(q: 41)
! ask v -> v + 1
| done r |> std/io:print.ln("{{ r:d }}")
