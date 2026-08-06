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

## The variant that survives having controls: they can all vary ONE axis

Everything above is about claims made with NO control run. 2026-08-06 produced
the harder case — a diagnosis with **four labelled controls**, each real, each
correctly observed, and the conclusion still wrong.

The claim was that Koru's phantom-obligation discharge wall "guards only a tor's
FIRST declared branch", so a handle handed back on a later failure arm could be
bound and dropped unreported. The observation behind it was genuine: in one
compile of the shipped `unikraft/blk` lift, `KORU030` fired for a handle on arm 1
and stayed silent for a handle on arm 2. Controls R1, R4 and R5 then ruled out
struct-vs-bare payloads, mid-chain position, and the state wall — leaving "arm
position" as the survivor.

It was not arm position. Obligations are keyed by BINDING NAME, never by node
identity, so arm position cannot matter at all. The discriminator was the
**disposer set**: with exactly one unattended disposer for a state, auto-discharge
silently inserts the disposal; with zero or several it reports. Arm 2's state had
one candidate and was handled; arm 1's could not be elected and was reported. Two
arms, two disposer shapes, one correct compiler and no defect.

**Why the controls did not save it: all four varied the same axis.** R1, R4, R5
moved payload shape, chain position and which wall was probed — and every one of
them held the disposer set fixed, because the disposer set was not yet a
candidate. Controls confirm or eliminate hypotheses you already have; they cannot
nominate the variable you have not thought of. So a set of controls that all vary
one dimension produces the *feeling* of triangulation while measuring a single
line through the space.

What follows, and it is sharper than "run a control":

- **Count the AXES your controls span, not the controls.** Four probes along one
  axis is one experiment repeated. The question to ask before concluding is
  "which dimension have I held fixed in every single run?" — that is where the
  discriminator hides, by construction.
- **An asymmetry is not a mechanism.** "A fires and B does not" invites you to
  name the most visible difference between A and B. Position is the most visible
  difference between two branch arms, and it was the wrong one. Enumerate what
  else differs *before* believing the salient answer.
- **Read the OUTPUT, not the absence of a diagnostic.** The disproof cost one
  command: compile the program that "leaks" and grep the emitted Zig for the
  disposal. It was there, auto-inserted, in the exact arm the note said leaked. A
  silent compiler was read as an absent check when it was a completed one, and
  nobody looked at what it had produced.
- **A confident diagnosis with controls attached propagates further than one
  without.** This claim reached a module README, a second module's README, two
  status reports to Lars, a test file titled `frontier_*`, and a commissioned
  bugfix session — *because* it came with evidence. The rigour bought it
  distribution, and the error rode along.

Residue: `koru-libs/unikraft/alloc/tests/autodischarge_covers_later_arms.kz` is
the former "frontier", kept and renamed — it now passes as a regression on the
auto-discharge path and carries the correction, so the file that made the claim is
the file that refutes it.
