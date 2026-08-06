---
type: belief
id: frag-a-reproducible-failure-localises-the-symptom-not-the-defect
provenance: eight wrong attributions in one session, the last of which was one step from patching a healthy annotation parser to fix invalid syntax in koru_std
ts: 2026-08-05
---

# A reproducible failure localises the symptom; the component it surfaces in is not evidence about the component at fault (belief)

A defect that reproduces feels *located*. It isn't. Reproduction proves the
failure is real and repeatable — it says nothing about which layer owns it, and
the layer where the error text appears is the least reliable witness available,
because an error surfaces wherever the invariant is *checked*, not wherever it
was *broken*.

The reflex this belief exists to interrupt: a stable repro plus a plausible
mechanism reads as a diagnosis, and the next move is a fix. It is not a
diagnosis. It is a symptom with an address.

## The eight, in one session (2026-08-05)

Every one reproduced. Every one had a mechanism I could state. Every one was
wrong about *where*:

1. **"Cross-compilation is broken."** Recorded as a toolchain gap in two
   artifacts, reproduced in nine lines. It was `std.build:config` — the dot
   namespace retired by `5f41236f`. The compiler was fine.
2. **"`OPTIMIZE_DEADELIM` drops the interrupt-vector handlers."** Reproduced. It
   was `OPTIMIZE_LTO`; dead-elim is fine and saves 24,832 bytes.
3. **"`ukpod/anon.c` is missing its `UK_ASSERT` include."** The include is at
   line 10, and `assert.h:73` no-ops the macro when asserts are off. Does not
   reproduce at all; cause still unknown.
4. **"`invalid!` is new to the whole corpus."** Grepped three files in
   `koru-libs`; `yaml/index.kz` had been doing it for months.
5. **"`app{}` + `config{}` together is a compiler defect."** Two *existing*
   Source tors in one program compile fine. It was name collision in my own
   module — `app` is a reserved import alias, `config` collides with
   `std/build:config`.
6. **"The LIFT brief is malformed."** It already contained the rule under
   discussion, with `gzip`'s `fed` gate as a worked exemplar.
7. **"Prose must be preserved for the record."** The preserved passages were
   false statements about the present.
8. **"Combined annotations drop `depends_on` — the bug is in
   `annotation_parser.getCall`."** The parser is correct. `koru_std/build.kz`
   was writing `~[default, depends_on(x)]` with a comma where annotations
   separate on `|`. I was one step from patching a healthy component.

Eight is past coincidence. It is the default behaviour of confident reading.

## Why the symptom's address is actively misleading

Each of these had a *coherent story* attaching the failure to the place it
appeared. That is the trap: the story is generated from the same reading that
produced the misattribution, so it corroborates itself. Number 8 is the sharp
case — "the parser drops the second annotation" explains the observation
perfectly, predicts the right behaviour under a single annotation, and is false.
A theory that fits every observation you have is not evidence when all your
observations come from one reading.

## What follows

- **The cheapest instrument is a control run, and it is the one consistently
  skipped.** Run the *same shape* through a path known to work. Two existing
  Source tors in one program: nine seconds, killed #5. A pipe instead of a comma:
  one minute, killed #8. In every one of the eight, a control was available and
  cost under a minute.
- **Before naming a component, state what would have to be true of it, and check
  that.** #8's claim required `getCall` to mishandle a multi-entry array. Reading
  it would have shown it iterates and matches by name — fine. The claim was never
  checked against the code it accused.
- **A failure that moves when you fix it has not necessarily been fixed.**
  Correcting `main` → `backend` moved the error to `backend: No such file`. The
  first defect was real *and* was hiding a second one. Treat a *changed* error as
  a new observation, never as confirmation.
- **A silent failure earns extra suspicion about location.** `~[a, b]` produced
  no diagnostic — it silently became not-two-annotations. When a system swallows
  malformed input, the surfacing point is arbitrarily far from the cause, and the
  ordinary "it broke here" heuristic is worth nothing.
- **Say "I have not bisected this" out loud.** All eight were stated flatly.
  Cheap hedging at the moment of claiming would have cost nothing and prevented
  a wrong fix in a healthy file.

## Open

- Nothing enforces the control run. It is a habit, and habits are what this
  belief documents failing eight times in a row. Whether it can be made
  mechanical — a checklist item on any commit whose message names a component as
  at fault — is unexplored.
- Seven of the eight were caught by Lars asking a plain question or supplying one
  fact. That ratio is the actual finding about where a second pair of eyes pays,
  and it argues against running long unattended stretches on diagnosis-shaped
  work specifically.
