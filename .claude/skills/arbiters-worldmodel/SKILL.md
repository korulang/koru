---
name: arbiters-worldmodel
description: The world-modeling practice of Arbiter-Driven Development — instrumenting anything (a repo, a product, an idea, a dataset) with executable world models that fire signals. Fire whenever world-modeling comes up in ANY form — "should this be instrumented?", starting a project under the world-model regime, floating an ontology from data or a codebase, building or judging a signal instrument, the tending loop, probes vs instruments, faucets. NOT the wm tool's manual (that lives in `wm help` and is never duplicated here). This is the method-side guide and the honed-prose home for the practice.
---

# World-modeling — the practice, method-side

This skill guides the *practice* of world-modeling inside ADD sessions. It
deliberately does not document the `wm` tool — run `wm help`; the tool's
conventions live there, enforced by being executable, and copying them here
would only create drift. The relationship is one-way: this method relies on
the tool; the tool has never heard of the method.

This file is also the practice's **prose home** — the larval layer. Lines
here graduate into challenge briefs, pass contracts, and tool help as they
earn encoding, and the prose dies. Hone it between experiments (a Gardener
act); expect it to shrink as the practice hardens.

## When world-modeling is the move — substrate by fit

Two substrates encode an invariant; pick by the gap's shape, not by habit:

- **Test / xfail** — the gap is binary, code-checkable, settled by one run.
  "This input must be rejected" is a test, not a model.
- **World-model instrument** — the gap is continuous, temporal, or needs
  *watching*: rhythms, droughts, drifts, regime breaks, leading signals,
  anything where the question is "should a watcher be surprised right now?"

A repo enters the regime by getting a governed shape (`wm help` —
governance section). An idea enters the regime by stage 1 of the chain:
there is no requirement that anything be built yet, only that real data
exists somewhere.

## Two ways a signal fires — an instrument, or declared at the change

A faucet signal is this skill's own question — *should a watcher be surprised
right now?* — made concrete. It reaches the faucet by one of two paths, split by
the same razor as any other gap:

- **Mechanical** — an instrument/producer computes it from data (cadence, churn,
  regime break). Deterministic and reconstructable, so it belongs in the tool, not
  in anyone's head. The chain's stage-3 instruments are this path.
- **Discipline-declared** — the signal *is a judgment* (this contradicts a prior
  belief — a *surprise*; this is a *smear*; this entity's story just *shifted* — a
  *regime-change*) that no mechanical extractor reliably catches, because catching
  it *is* the judgment. The agent declares it at the moment it makes the change —
  e.g. as a `Signal:` trailer on a memory commit, where the commit SHA is already
  the claim ticket. The carrier and its enforcement live with that substrate (for
  the git-memory corpus, the `membrane` skill); the *meaning and the bar* live
  here.

The bar is the same on both paths: emit only when a watcher should *wake* — a real
surprise, a contradiction, a detected contamination, a regime shift. Routine change
carries none — declared explicitly, so the silence is a choice, not an oversight.
The mistake to avoid is pushing a *judgment* signal onto the mechanical path and
then fighting to extract it; if catching it needs taste, it is declared, not
computed.

## Ground in what already exists — run `wm` first

Before a contestant floats a concept or proposes an instrument, it runs the
`wm` readers to see the landscape it is adding to — the same move a synth
contestant makes by listing prior submissions before building. `wm tree <path>`
shows every instrument that exists and whether it is green, red, or **dark**
(authored but never run); `wm top` (or `wm top ~/src`) rolls each repo to one
ranked line. The point is aim, not inventory: a concept already shipped is not
the target — the **residue**, the dark instruments, and the gaps are. Both are
pure readers (no run, no lock); `wm help` is the manual, never copied here.

## The chain — three replayable stages, catalogs feeding forward cold

The generic pipeline (worked example: `6digit-world/challenges/vocabulary/`,
first full revolution 2026-06-11, two domains, blind at every link):

1. **Hunt** — find a domain with real, downloadable historical data; fetch
   it; ship rows-on-disk with provenance. Cited-but-not-fetched data
   disqualifies — LLMs fabricate plausible dataset URLs at a terrifying
   rate, and vapor sources poison every stage downstream silently.
2. **Float** — a sealed contestant stares at the data and names the
   concepts, free-form. Two gates only: evidence per concept (computed from
   the shipped rows — number, n, command) and an expression attempt against
   the engine (encodes-with-sketch / resists-with-reason; any shipped
   fragment must survive the FULL toolchain, compile included). The
   **residue is a first-class deliverable** — what the engine couldn't say
   is the engine's roadmap, discovered from outside.
3. **Rules** — a cold contestant composes the floated vocabulary into a
   catalog instrument with a frozen pass contract: oracle verified
   bit-for-bit, honest in-sample/out-of-sample bands, and at least one
   **flinch gate** — a historical event the model is never told about and
   must visibly react to, plus quiet gates proving it absorbs the world's
   ordinary rhythm. Board-visible or not done.

Stages replay independently and at different rates; the link between them
is the judged catalog, never a conversation. The walk arbitrates between
every stage.

**The validity signal is blind convergence.** Run floats as sealed pairs.
When two agents who cannot see each other name the same concept — same
flappiest test, same lead-time structure, same missing faucet at the top of
both residues — the vocabulary is real. When they diverge, the judges
arbitrate, and the divergence itself is information. Never let a contestant
read a sibling's float "for inspiration"; convergence manufactured is
convergence destroyed.

## The tending loop — live is replay arriving slowly

An instrument is never finished; it is tended:

1. Replay ≡ live for model semantics; live adds only *operational*
   surprises (faucets dying, revisions), which route to channel-watchers,
   not the world model.
2. The live failure that matters most is the **missing surprise** — the
   world flinched and the model didn't.
3. Go back to replay and tune until the right surprises fire — legal under
   the **consumption ratchet**: tuning on a missed event moves it into
   in-sample forever (logged in the provenance ledger); the next flinch
   gate must come from data the model has never seen. The calendar mints
   fresh holdout every day a faucet stays live.
4. Redeploy, keep watching. Each turn moves one judged surprise out of the
   human's head into the instrument.

## Where surprise enters — three doors, one ratchet

Surprise is not only *computed ahead* of the world; it is also a **historical
fact** — "we were surprised by this" — and an honest regime catches it from
every direction it arrives, not just the one a watcher predicted. There are
three doors, and they feed one ratchet.

1. **Preemptive — the watcher fires.** The instrument predicts, the world
   deviates past epsilon, the alarm rings. This is the door the rest of this
   skill documents: probes, instruments, flinch gates. Its reach is bounded by
   imagination — you can only pre-encode a surprise you already had words for.
2. **Ambient — a human is surprised, with nothing watching.** In the course of
   normal work you (or the Arbiter) stumble on something real and think *"huh,
   that's surprising"* — no instrument pointed at it, no commission in flight.
   This is the door the methodology long left undocumented, and the other two
   both quietly **presume an instrument already exists**: the tending loop tunes
   a watcher that *missed*; the chain floats a *commissioned* dataset. Neither
   catches the surprise that ambushes you off the walk. The danger is
   **evaporation** — an uncaptured "huh" is gone by the next turn, and it is the
   highest-value input the system has, precisely because no watcher anticipated
   it.
3. **Commissioned — a scout goes looking.** The Hunt → Float → Rules chain, and
   the Gardener's re-drink of standing instruments on fresh data. Scheduled, not
   reactive: it scours for surprise on a gardening cadence, and its residue is
   the roadmap.

**The ratchet: discover → capture → watch.** A surprise that earns its keep
*graduates* — door 2 or 3 nominates a probe, a probe that starts wanting an
alarm becomes an instrument (the existing promotion path), and from then on that
exact surprise arrives through door 1. The lived surprise of today is the
threshold of tomorrow; you can never be naively surprised by it again. The loop
also closes **backward**: door 1's *misses* are door 2's richest feed — *"the
world flinched and the model didn't"* is the watcher confessing a blind spot,
and that confession is the most valuable "huh" there is. The consumption ratchet
already names this move; tending-loop step 4 (one judged surprise moved out of
the human's head into the instrument) is this same ratchet seen from *inside* an
existing instrument.

**Capture is a standing act; ratification is the Gardener's.** Because door 2
fires at any phase — or none — the *catching* cannot be pinned to a phase; it is
a standing quick-capture any moment feeds. The *deciding* — does this surprise
earn a permanent watcher? — is Gardening's, and it is the same refusal that keeps
every signal honest: surprise **nominates**, the judge **ratifies**, and most
nominations must die. Encode every "huh" as a watcher and you get a garden of
dead rules and alarm-fatigue — and you will encode gauge-seams (the instrument
changing under the world) as if they were world-events. *Refuse the ceremony for
surprises nobody would act on.* Door 2 is **never Muse**: Muse dreams what the
garden *wants to become*; a captured surprise is an observation of what *is*.

**What the encoded rule actually is.** When a lived surprise becomes a watcher,
the rule you write is the *explanation* of the surprise — the smallest change to
the world model that would have made the observation unremarkable. So the size of
that change gauges the surprise's depth: a one-line threshold tweak was a shallow
surprise; a relationship the model had **no way to express** was a deep one — and
a deep one is usually a *residue* entry (the engine's own roadmap), not a
tunable.

**Prose now, tool by recurrence.** Honest state today: the *encoding substrate*
exists (a probe is one computed number to a tile; an instrument carries the full
discipline) but the *capture on-ramp* — an inbox that catches the ambient "huh"
before it evaporates — does not. **Do not build the inbox on this prophecy.**
Promotion is triggered by recurrence, not forecast (Gardener doctrine); building
a capture organ before the pain of losing surprises has actually recurred is the
front-loaded hunter the Gardener forbids. Name the act here, in the larval prose,
so it is *recognized* when it recurs; let the recurrence earn the tool. Until
then the on-ramp is manual, and that is correct: when surprised, drop a probe —
or, if there are no words for it yet, log it as residue.

## Probes vs instruments — two weights, one promotion path

- A **probe** is the lightest governed unit: one computed number from
  existing artifacts, straight to a tile. No model, no oracle. Most of a
  repo's dev-signal vocabulary starts as probes (heartbeat, debt age,
  flap count).
- An **instrument** carries the full discipline: model, oracle, bands,
  flinch gates, pass contract.
- Promotion is earned, not planned: a probe becomes an instrument when its
  number starts wanting an *alarm* — a threshold someone would act on.
  Building the full ceremony for a number nobody alarms on is inhale waste.

## The honesty kit — what keeps signals meaningful

- **Meaningfulness is bought by refusing observations, not adding them.**
  Every signal that works, works because of an exclusion rule: snapshot
  only full runs, post only on change, compute rates only over in-scope
  units, keep intent markers adjacent to the thing measured. Every
  unmeasurable thing is an observation whose *frame* (intent, duration,
  cleanliness, channel) wasn't captured beside it. (Floated blind from the
  koru substrate, 2026-06-11.)
- **Exit codes speak for instruments, not the world.** A healthy instrument
  loudly reporting an unhealthy world is a green run. Conflating the two
  makes every doctrinal red wall page someone.
- **The watcher is the surprise-encoding.** Observation epistemics (channel
  dead? data censored? source revising itself?) mostly need no new wire
  semantics — point a second model at the channel itself and read the bit
  off its surprise. Worked proof: `6digit-world/models/019_watcher_season`
  recovered a park closure from observation-cadence texture alone.
- **Disclose every out-of-sample look** in the provenance ledger, even the
  innocent ones. The ledger is what lets a judge distinguish a frozen
  contract that passed first try from a tuned fake.
- **Every rendering is an artifact, and committed artifacts earn drift
  gates — turtles all the way down, by design.** A diagram, a README
  number, a face, a board tile: each is a rendering of some source, each
  can silently drift from it, and each gets a regenerate-and-diff or
  replay-and-compare gate on the wall the moment it's committed
  (worked instances: graph-sync for diagrams, readme-numbers for prose,
  face_drift for faces, 018 for visible surfaces shipping engine shadows).
  This is cheap precisely because the honesty rules force renderings to be
  computations — wallpaper can't be drift-checked, which is the test for
  whether something IS wallpaper. No regress: each turtle is diffed
  against the one below, and the tower grounds in the oracle (bit-for-bit)
  and the commit (content-addressed). The chain of custody from source to
  eye is gated at every hop, and belief is only ever as fresh as its
  oldest green gate.

## Installing the regime in a product — the install recipe

The path from "we floated this product's ontology" to "a flywheel runs
inside it." Four steps, in order; steps 2–4 are proven on existing repos,
step 1→2 is the product-install move (first subject: 6digit-trust,
2026-06-12):

1. **Faucets** — product-side migrations/event-logs, specified by the
   floats' residues (the converged "what's unwatchable and what table fixes
   it" list IS the spec). Correctness fixes that create history (e.g.
   revoke-plus-insert instead of update-in-place) are faucet work — often
   faucet #1.
2. **A governed shape** — give the product a `wm/` adapter corner (ten-line
   `wm/run.sh`, target-owned layout knowledge; see `wm help` governance).
   The product is now operable from outside, occupancy-guarded.
3. **Probes before instruments** — the floats' derivable-today concepts as
   one-number computations over the new faucets, straight to tiles.
   Promote to full instruments only when a number wants an alarm. Domain
   instruments built earlier against historical/ancestral data re-point at
   the product's live faucets when the shapes match.
4. **The spin** — schedule `wm run <product>` (cron, post-event hook, CI);
   surprises surface to the board; the tending loop and the Gardener's
   instrument verbs keep it honest. The walk is only called when something
   flinches.

**Where wm sits in a CI/dev pipeline:** as a sibling of the test suite,
consuming the same contract shape — exit code + report. The cut that keeps
it sane: wm's exit code gates on **instrument health only** (oracle drift,
broken harness, dead faucet = red build); **world-state is a report
artifact, never a default gate** — a healthy instrument loudly reporting an
unhealthy world is a green run. A specific alarm graduates into a blocking
CI gate only by explicit walk decision, and that graduation ratchets like
everything else (tighten deliberately, never loosen silently).

Orthogonality is enforced at install time too: everything installed —
adapter, probes, schedules — must be expressible in the tool's own
vocabulary (`wm help`), with no method-words in it. ADD depends on wm; wm
cannot pick the method out of a lineup.

## Day-type routing

**World-model is a door on the walk's menu** — one of the basin tracks named
when the day is named (walk.md), pickable on session startup like Generative.
Not every session is one; it recurs, and like Challenge it re-grounds itself:
the catalogs and the calendar decide what's due, so a session is productive
in one move. A World-model day is one of: replay a chain stage (the
arbiters-challenge skill governs replay mechanics), build one named
instrument, or run the tending loop on newly-arrived data. The Gardener owns
the regime's exhale (gardener.md "Tend the instruments"): re-drink, promote
probes, prune dead faucets, hone this very file. The walk happens first,
every time, as always.
