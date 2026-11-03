---
type: belief
id: frag-produced-text-exits-through-fmt-blk-split
provenance: measured during 820_007_base64 (w1C:p5A) — three refused paths probed before the working one, 2026-11-03
ts: 2026-11-03
---

# Produced text exits `*String` through `fmt.blk` + `split("")`; `detach` leaks what it hands out (belief)

Text a program *produces* lives in `*String` buffers — `for` iterates only
unqualified `string` (refuses `*String`, `string<*>`, `string<allocated!>`,
`string<*@scoped>` args, KORU030), so feeding produced text back into a flow
requires crossing `*String → string`. The surface today offers exactly one
round-trip-safe exit:

- `fmt.blk { {{ s:S }} }: dump` renders the buffer into `string<allocated!>`,
  then `std/string:split(s: dump, sep: "")` — the documented whole-slice path —
  binds each `! piece` as an **unqualified** `string` that `for` accepts, and
  the `allocated!` obligation auto-discharges. This is the 690_190 idiom.
- `fmt.ln`'s product is `string<... @scoped>` — frame-confined; it feeds only
  `string<*@scoped>` params, never `for` or `io:free`.
- `std/string:detach` yields a **bare owned `string` nothing can dispose**:
  `std/io:free` consumes only `<allocated!>`-labeled slices, and the runtime
  leak counter still tracks the buffer — a detach in a MUST_RUN binary fails
  the produced-program leak check. `*String` offers no char-level read at all
  (`pop-char` mutates, returns nothing; `contains`/`index-of`/`substring` are
  the only reads).

Why it matters: detach looks like the canonical answer to "how do I get the
text back out" and silently writes a leak. Its doc says "tracked no further"
— true of the obligation checker, false of the allocator counter. Programs
that need produced text back into `for` should reach for the fmt.blk+split
bridge, not detach; a real `*String → string` read-out leaf (or a disposer
for detached slices) would retire the detour and is a named gap.

Open question: whether the leak is detach's intended contract ("the next
holder owns it outright" — but no holder can) or a missing `free` leaf for
unlabeled owned slices.
