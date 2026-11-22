---
type: belief
id: frag-a-deficit-attributed-to-the-kernel-can-live-in-the-input-path
provenance: Goose-race json, 2026-10-22 — the suite read "parser 1.23x
  behind Goose, 3.4x the RSS" and the investigation opened on the emitted
  recursive-descent scanner. The whole deficit was io.kz's read-file:
  readToEndAlloc's chunked growth copied a 115MB file ~3x, inflating peak
  RSS to 443MB and the row to 1.23x. stat+alloc+readAll: 0.97x, RSS parity.
ts: 2026-10-22
---

# A deficit attributed to the kernel can live in the input path (belief)

The json row read as a parser loss: 1.23x behind Goose's hand-tuned reader
(DIGIT_PAIRS, POW10_128 tables) with 3.4x its RSS, and the obvious fix was
scanner plumbing — fused token loops, cheaper skip, one-pass numbers. The
measured decomposition said otherwise: stubbing parseFloat moved nothing
(~15ms), and the remaining scanner profile was inside noise of Goose's
instruction count. The actual deficit was upstream of the benchmarked code:
**`io:read-file` used `readToEndAlloc`, whose chunked growth copied the
115MB input ~3x** — 443MB peak RSS for a 115MB file, page-fault and memcpy
traffic timed inside the row. A stat-sized single `readAll` reads the same
file at 116MB and closed the row to 0.97x with no parser change at all.

The working hypothesis had a silent scope: "the benchmark measures the
parse." It measures the process — input acquisition is inside the clock.
The cheapest wrong story here would have been a week of scanner work
buying the ~10ms that remained. This is
[[frag-the-vectorizer-checks-the-emitted-shape-not-the-structure]]'s
discipline applied one level up: the emitted shape held the answer, but
the right emitted *function* was `read_file`, not `__jobj`. A deficit
decomposes before it yields — measure the whole path, in pieces small
enough to falsify (stub the candidate, watch the clock), before touching
the code the story blames.

The same defect lived twice: `fs:read-lines` slurped through the same
`readToEndAlloc` growth under an `aspirational` note that correctly
described the streaming gap while leaving the cheaper defect unmeasured.
An honest annotation about the big gap is not evidence the small one is
closed.

The 016 bigint row was the same story one level deeper (A2.4): the w2
gap read as "constant-factor limb tuning" — py int 1.02ms vs koru
25.85ms on 3^100000 — and the instrumentation plan was mul-level. The
measured split: `biPowFast` was 2.79ms of the 26ms; the rest was one
`Managed.toString` — Zig's quadratic decimal render of 47713 digits —
plus a per-op radix round-trip (`biToDigits`+`decFromDigits`) in
`decMul`/`decAdd`/`decMod` paid only to canonicalize (strip trailing
zeros, count digits). Both have limb-level answers that were already in
the file (`div1L`, `pow10L`); the canonicalize path just never used
them. Even the remaining post-fix w2 is ~75% render — and py's 1.02ms
never paid for `str()` at all, so the flattering part of the old gap was
a comparison that wasn't measuring the same work.

## Open questions

- `io:read-stdin` keeps chunked growth (correct — no stat on a stream) but
  could still over-copy on known-size redirects; unmeasured.
- The arena parser still materializes the `coordinates` array where Goose
  streams; on larger docs that shape may become the real deficit.
