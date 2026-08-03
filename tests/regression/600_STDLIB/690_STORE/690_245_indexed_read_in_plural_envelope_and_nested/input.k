// PINS: a handle-addressed READ survives both places it used to be dropped —
// inside a MULTI-FIELD envelope, and inside another indexed read's INDEX.
//
// Two defects, one shape, found together by trying to walk an intrusive chain.
//
//   (1) `stored` has TWO lowerings. A row-addressed envelope and the
//       single-write path both ran the full expression lowering; the
//       non-row-addressed plural envelope ran only its OWN store's rewrite, so
//       a value reading any other store — or reading one through a handle at
//       all — reached the host verbatim as `cells[...]`. One field worked and
//       two did not, which is the tell for a second lowering rather than a
//       missing feature.
//
//   (2) `indexedFieldRefs` consumed the whole matched span, so an indexed read
//       sitting INSIDE another one's index was never visited. That is exactly
//       one hop along a chain — `cells[cells[h].next].v` — and it is the shape
//       any linked structure is walked with.
//
// The consumer's spelling, not the minimal one: three rows chained at insert
// (`| row` is the only place a handle is minted), then walked THREE hops deep
// through a plural envelope. Handles are opaque and branded, so the oracle is
// the values they reach, never the handle numbers.
//
// Found writing the ECS benchmark's spatial grid: an intrusive bucket chain
// needs no nested collections, no positional addressing and no new verb — only
// these two reads. What it still lacks is a way to name the handle of the row a
// SWEEP is visiting; `[id]` is refused-and-named by the request block today.
import std/io
import std/store

std/store:new(cells, capacity: 8) { v: i64, next: -1[i64] }
std/store:new(head) { h: -1[i64] }
std/store:new(probe) { v1: 0[i64], v2: 0[i64], v3: 0[i64] }

std/store:insert(cells) { v: 10, next: -1 }
| row a |> std/store:stored { head.h: a }
| full |> _

std/store:insert(cells) { v: 20, next: head.h }
| row b |> std/store:stored { head.h: b }
| full |> _

std/store:insert(cells) { v: 30, next: head.h }
| row c |> std/store:stored { head.h: c }
| full |> _

// Multi-field envelope, and the second field is a NESTED indexed read.
std/store:stored { probe.v1: cells[head.h].v, probe.v2: cells[cells[head.h].next].v }

// Three hops — the nesting recurses, it does not merely survive one level.
std/store:stored { probe.v3: cells[cells[cells[head.h].next].next].v }

std/io:print.ln("hop1 {{ probe.v1:d }} hop2 {{ probe.v2:d }} hop3 {{ probe.v3:d }}")
