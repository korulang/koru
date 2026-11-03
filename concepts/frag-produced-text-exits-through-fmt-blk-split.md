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

Evolved 2026-11-03 (gap-detach, same day): the named gap is filled —
`std/string:read { s: *String<view|instance> } ! text string | done usize`
lends `s.data` to the arm as an unqualified `string` for the call's duration;
`for`, `split`, `parse-int` take it directly, one hop, no copy, no ownership
move (`610_025`). `read` retired as `-> s.data` because up-borrows are
unpoliceable (KORU095); the `! text` arm is the policeable direction — same
shape `split` uses for its `! piece` views. The fmt.blk + `split("")` bridge
still works (820_008 stays green) but is no longer the only exit.

The open question resolves toward "detach's contract is real but host-only":
its next holder is host machinery (`body_allocated`'s post-send free in
orisha's `respond-plain`, whose `body: string` param is unqualified — the
`allocated!` label cannot ride that surface), not a Koru leaf. The leak fires
when detach is used as a *read-out* — the motive `read` now removes. A
Koru-level disposer for unlabeled owned slices remains unspellable: `free`
cannot distinguish an owned slice from a literal, which is what the
`allocated!` label exists to say.

Measured extras: `s.data` projection on `*String` already reached `for` and
`split` mechanically (borrow-down) — the gap was first-class surface, not
capability. `split(s: *String)` still escapes as a raw Zig type error
(`[]const u8` vs `*String`) rather than a Koru diagnostic — a separate
checker hole (`string<*>` wildcard admits non-slice base types), unclosed.
