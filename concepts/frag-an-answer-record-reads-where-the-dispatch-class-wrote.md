---
type: belief
id: frag-an-answer-record-reads-where-the-dispatch-class-wrote
provenance: w1C:p5A respell of the 350_02x router cluster, 2026-11-03 — seven tests red on PARSE006 against the Exchange signature; respelling surfaced that three of them pinned a field the dispatch class never writes
ts: 2026-11-03
tags: [orisha, tests, router, handler-lite, answer]
---

# An `orisha:answer` record reads where the dispatch class wrote — a lite hit is head-carried, and `.body` on it is empty by design, not by omission (belief)

`orisha:answer` takes `x: *orisha/pump:Exchange`. The return record has both a
`head` and a `body`, and which field carries the response is decided by how the
request was dispatched:

- A request-free literal arm (`! [GET /t] -> { ... }`) is collected by the
  router transform into `handler-lite`. A lite hit is a *finished* response —
  pre-rendered head and body together — and ships **head-carried**: `head`
  holds the complete wire bytes, `body` is `""`, `head_static` marks it. There
  is no per-request render, so there is no `Date` in it; the block is
  byte-deterministic across runs.
- A request-consuming arm (any chain, any arm that names `req`) materializes a
  `Request`, rides the full `handler`, and returns `head` + `body` as separate
  fields — and that `head` carries a live `Date`, so it cannot be pinned in
  `expected.txt`.

**Reading `.body` is not a safe generic way to check what an arm produced.**
For a lite hit it reads `""`, and pinning that records a response that was
never sent — the wire bytes were sitting in `.head` the whole time. A test that
wants the arm's output must read the field that arm's dispatch class writes:
`.head` for a lite arm, `.body` for a handler arm.

Outside `! arrived`, an `*Exchange` is fabricated host-side —
`koru_orisha.koru_pump.Exchange{ .fd = 0, .raw = <request bytes> }`, the same
construction orisha's own wasm example uses — and passed `x: &<var>`. `head =
null` is legal: `answer` re-walks the request line when the pump never scanned
it (index.kz:759). One `var` per request under test.

The stale spelling `orisha:answer(raw, fd: 0)` predates the pump seam
(`ec5a186`); handler-lite itself is `dafac77` (2026-10-12). The punning wall
(PARSE006) is what surfaced the drift — the tests were the suite's only
`answer` callers, so the signature move had no other witness.

Pinned: 350_023/024/025/029 (handler-path answers, `x: &exchange`), and
350_027/028/030 whose expected.txt now carries the full static lite head as
the literal response the `[GET /t]` arm produced.

Related: [[frag-bare-host-type-is-module-local-cross-module-is-qualified]] (the
qualified-spelling law that made `*orisha/pump:Exchange` nameable across the
index/pump boundary at all).
