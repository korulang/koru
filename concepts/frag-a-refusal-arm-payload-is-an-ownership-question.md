---
type: belief
id: frag-a-refusal-arm-payload-is-an-ownership-question
provenance: qcalc exercised `num:parse`'s |bad for the first time and the leak checker named a buffer nobody owned
ts: 2026-10-31
---

# A refusal arm's payload is an ownership question, not a diagnostic decoration (belief)

`num:parse`'s `|bad` arm returned the offending input as unmarked `string`. It
read like a courtesy — the caller sees what failed. It was actually an owned
buffer crossing a boundary with no owner: the `catch` returned `s` before the
free line could ever run, so every malformed parse leaked, and no test had ever
fired that arm. qcalc fired it within an hour of existing.

The ruling: **when a refusal arm carries owned bytes, the bytes ride an
obligation or they don't ride at all.** Two lawful shapes:

- **Transfer** — `| bad string<std/io:allocated!>`: the obligation moves to the
  receiver, who disposes via `io:free`. Right when the receiver genuinely needs
  the offending bytes — `num:parse` on external text, where the bad input is
  evidence the caller may want.
- **Settle inside** — the callee frees the buffer and produces an unmarked
  message: `=> bad "malformed quantity"`. Right when the caller already holds
  the evidence — `quantity:lit`, whose input was the caller's own literal.

The unlawful shape is the one that shipped: owned bytes returned as plain
`string`. That is not a laxer contract, it is no contract — a leak the type
cannot see and the leak checker can only catch when someone finally walks the
arm.

Second mechanic in the same fix: `=> bad e` does not move `e`'s obligation into
an arm whose payload is declared unmarked. Produce transfers a marked payload
only into a marked arm — `=> exact q` works because `exact` is declared
`string<exact!>`; `=> bad e` into `bad string` silently leaves `e` live and the
checker names it. The arm's declared payload type is what discharges, not the
produce spelling.

Related: [[frag-crossing-a-boundary-splits-into-representation-and-ownership]] —
the same split, one boundary down: here it is a union arm instead of a C ABI,
and the ownership half is again the one that bites.
