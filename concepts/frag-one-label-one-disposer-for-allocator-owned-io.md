---
type: belief
id: frag-one-label-one-disposer-for-allocator-owned-io
provenance: introduced with the 335_042/043 ruling — Lars unblocked the spelling 2026-07-31 ("we are free to just fix std/io"), the label/disposer choice made at the keyboard
ts: 2026-07-31
---

# Allocator-owned io buffers carry one label, discharged by one disposer (belief)

Every allocator-owned buffer a `std/io` tor hands back carries the same
phantom obligation — `allocated!` — and is discharged by the same tor —
`std/io:free`. Not per-tor labels, not a `*String` re-wrap: one label, one
disposer, on the primitive `string` surface the tors already speak.

Why this shape won:
- The **machinery predated the ruling** — 335_047 tracked an arbitrary
  phantom label on a bare `string` through discharge and stale-read long
  before io used it. 335_042 said so explicitly: what was missing was the
  spelling on the IO surface, never the checker.
- **Auto-discharge makes the obligation invisible to most callers**: the
  existing corpus compiled unchanged (the inserter traces the buffer to its
  single legal disposer), while `--auto-discharge=disable` lays the leak
  bare as a loud KORU030 naming `std.io:free`. The day it landed,
  kopium's leak check went green with zero consumer edits.
- A `*String<view!>` return was the rejected alternative (335_042's
  question 2): it would force every read-path caller through take/read
  ceremony for what is semantically a one-shot buffer.

Reach: `read-file` and `read-stdin` today. The rule extends to every
`readToEndAlloc`-shaped path io grows (335_042's question 3 answered as
"one label for all of them"), and gzip's `no_obligation_pin` names the
same shape waiting in koru-libs.
