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
ranked line; **`wm faucets <path>`** joins the signal registry against the firing
ledger and names every **dark signal** — declared but never emitted (a missing or
broken faucet). The point is aim, not inventory: a concept already shipped is not
the target — the **residue**, the dark instruments, the **dark signals**, and the
gaps are. All are pure readers (no run, no lock); `wm help` is the manual, never
copied here.

## Dark signals — the registry is a spec of the world, not an inventory of it (encoded 2026-07-07)

A `signals/*.signal` you declared but nothing emits is a **dark signal**: an
aspiration with no faucet. Treat the registry as a **spec of the world you want to
see** — you may declare `human-frustration` or `trust` before any faucet produces
them, and the *gap between the catalog and reality is the work list*, not an error
in the catalog. The failure this ends is the silent one: an un-fauceted signal used
to look identical to one nobody needs — both simply never fired — so the hole hid in
plain sight (the regime's own collaboration signals sat dark for weeks, invisible,
until someone dug the bus by hand). Make unbuilt **loud**: `wm faucets` joins the
registry against the firing ledger and names every dark signal, exit 1 — the
aspirational catalog that *screams until it is true*.

One razor, so it never cries wolf: **absence of firing is not, by itself, absence of
faucet.** Some signals are honestly quiet — an empty surface is a correct resting
state. Rank by evidence, never assert from silence: **dark** (never fired — the
strong candidate, and it catches a *broken* faucet as readily as a missing one) →
**stale** (fired, then silent past the staleness window — a watch, not a gap) →
**live**. And the directionality is why this is a *runtime* read, not a static one:
faucets name their signal; signals do not name their faucet — so you cannot ask the
signal, you ask the **bus** (the firing ledger is the join that needs neither side to
know the other).

The dark set is a commission input, exactly like stage-1's residue feeds stage-3: a
**faucet run** consumes `wm faucets --json` and builds emitters for the dark signals;
a later run points world models at the newly-live ones. Declare the world
aspirationally → let the gap scream → commission it closed → watch it go live. That
loop is the transparency ADD promises, finally turned on *itself*.

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
   is the engine's roadmap, discovered from outside. And a float names
   **ports and rules, never pre-chewed features**: the ontology says what
   the model *perceives raw* and what DSP shapes it into belief. Extraction
   with an opinion — rates, bins, holds, smoothing — belongs INSIDE the
   engine; a float that assigns it to the producer/sensor is floating a
   power leak (see "Dumb signals, smart engine", 2026-07-02).
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

## Dumb signals, smart engine — and the live tick (encoded 2026-07-02)

Earned in 6digit-world over weeks of frustration, named the night the first
live tick ran (commit_shape). Two laws, and the mechanism that kept erasing
them:

- **Dumb signals, smart engine.** Producers mint provenance and forward raw
  events; every transformation with an opinion — rates, holds, decay,
  binning, reference-divergence — is the model's job, expressed in the
  engine. A "smart signal" (a feature pre-computed in host code) dumbs down
  the whole system: it leaves the model.wmfx one EWMA line and moves the
  actual world-modeling where the engine can't see it. These leaks arrive
  dressed as reasonable design decisions (a harness-side sample-and-hold, a
  producer that bins hours); each is a route-around of a missing engine
  capability, and gets named as such.
- **The cassette is the test rig; the live tick is the instrument's LIFE.**
  Replay ≡ live holds for model semantics, but an instrument that has only
  ever replayed a tape is a regression test wearing an instrument's costume:
  its green says "the engine works," never "the world is watched." An
  instrument is not done until it has ticked live — event in, ONE engine
  tick, state carried forward across invocations, signal out at that moment.
- **Why this kept regressing — the mechanism, so the fix sticks.** The
  verified-means-run discipline demands proof inside one turn, and tape
  replay is the only shape that can prove itself inside one turn — so the
  honesty machinery itself selects the dead shape unless the live tick is
  explicitly named the deliverable. The counter-move: **pin the aspiration.**
  When a walk lands an insight of this class, the closing act is a pinned
  aspiration instrument (an `ASPIRATION` marker in the instrument dir; `wm`
  renders `asp`, distinct from `red`) — *red is the honest state at commit
  time*, which frees intent from the prove-it-green pressure and lets it
  survive session death. An aspiration is an oracle for a world that doesn't
  exist yet; going green is the event.

## The extended nervous system — attention, not truth (Lars, 2026-07-02)

The stance that governs how much to trust all of this, in Lars's words: the
system is an **extended nervous system** that *informs a decision by guiding
attention* — never something relied on for base truth. A signal tells you
**where to look**; the ticket and the source tell you **what is true**. No
card, however fresh, settles a fact — factual reasoning walks the provenance
home. This is not a perfect simulation and is never supposed to become one;
it is a **constantly aligning machinery with practical value**.

The operational consequences:

- **Two tiers, split on mutability.** Provenance (the resource bridge) is
  append-only and untouchable — editable history is not a trace. Everything
  derived from it — cassettes, series, feature rows — is *mutable working
  material*: historical data is never disposable and never truth. Hand-fix a
  bad row, reprocess a tape with a better extractor, re-run last month for
  forensics — all first-class acts of the discipline, and all safe *because*
  every row's ticket points at the immutable tier. Mutable interpretation
  over immutable evidence.
- **Don't build (or demand) clockwork.** A contestant inheriting this stance
  should not armor derived data against edits, refuse manual corrections, or
  treat a reprocessed series as corruption. The machinery aligns by being
  touched.

## The routed bus — signals find their models by declaration (encoded 2026-07-05)

The night the first signal→model vertical closed (6digit-world `wmtick`,
commits 058fc3f..4e48969), after a grill that began from "the world model has
completely failed." It hadn't: engine, authoring, bus, and routing vocabulary
all worked — **nothing ran instruments and nothing consumed the spool.** The
failure was cadence and consumption, never inference. Doctrine, so the shape
is never lost on re-instantiation:

- **The producer states; the registry routes.** A producer's whole job ends at
  posting its raw measurement with provenance. Where it goes is decided by one
  committed, inspectable declaration (`signals/<family>.signal`, `route:` line)
  — never by the producer, never by host code. Sinks today: `surface` (the
  Cordial board), `wake` (Victoria's ears — flinch class only), `wmfx=<model>`
  (durable per-model spool, drained by a clocked driver into ONE real engine
  tick per card, state carried forward). Planned by the same grammar: `agent`
  (a spool the walk consumes at Phase 0 — signals addressed to the arbiters
  are standing state, not evaporating asks) and `gate` (a blocking class:
  commits/merges refuse while one stands unacknowledged).
- **Worked instance — koru's regression suite → the bus (the whole routing grammar
  on one run lifecycle).** The suite is PURE EXHAUST: `koru/wm/producer/cordial.ts`
  reads `test-results/latest.json`, diffs it against the last run's per-test state,
  and posts a START → FLIPS → VERDICT lifecycle across three families, each a
  different `route:` — the same dumb producer, the declarations doing all the
  deciding:
  - `koru.regression.run` — a PURELY VISUAL trace beat (`route: surface` only, no
    wake, no model): fired at suite start so an empty board reads as *idle*, not
    *mid-run*, and as the `--trace "<msg>"` breadcrumb channel. This is the
    canonical shape of a surface-only signal — a trace log to the board, nothing
    more.
  - `koru.regression.test` — RAW per-test telemetry, one card per green↔red FLIP,
    `route: surface, wmfx=regression_shape` — feeds the shape engine, never `wake`
    (a per-test flood must render and feed a model, never page).
  - `test-health` — the whole-run VERDICT `green|red|regression`, one card,
    `route: surface, wake` (flinch class).
  The runner stays dumb — the adapter (`wm/run.sh`) brackets the run (`--start`
  before, flips + verdict after); `run_regression.sh` never learns. `test-health`
  had been declared and DARK for weeks; lighting it was the whole move
  (declare-first, then close the faucet). One producer, three sinks, chosen by
  committed declarations: the purely-visual heartbeat, the raw stream to the
  engine, and the one card allowed to wake a human.
- **Cascades are declarations, not machinery.** A model's outputs return to
  the bus as ordinary measured cards; any output family declaring
  `wmfx=<downstream>` is a cascade edge. The registry IS the graph — one hop
  per declaration, each hop durable through a spool. Watch for declared
  cycles (self-echo is guarded by the driver's output allowlist; A→B→A is
  not, yet), and know each hop costs one clock period.
- **The watcher law: a new organ is not done until its watcher exists.** Any
  sink, driver, route, or faucet added to the machinery ships with the
  instrument that watches its flow — the machinery is itself a domain under
  the regime. Circuit breakers split by the standing razor: the hard backstop
  is mechanical and lives in the tool (a max-rate clamp at the wake sink);
  the breaker proper is a *judgment* — a model watching flow-to-sink (wake
  volume, inference spend) that fires when a watcher should be surprised —
  so the threshold lives in a declared, tunable model, never in someone's
  head. This is the transparency layer: it is what lets the Gardener stop
  guessing where to tend.
- **Naming across repo boundaries — two tiers live in the wild; declare which
  one you mean.** Judgment/collaboration families (`correction`,
  `regime-change`, ...) are bare-named and system-global by design — declared
  identically in several repos, first-registry-wins. Measured telemetry is
  repo-scoped and carries its scope in the name (`<repo>.<metric>`, the
  readme_drift pattern) — UNLESS the model deliberately watches the human or
  the whole system rather than one repo, in which case bare is a decision,
  not an accident. (Ruled on the walk, 2026-07-05: `commit_churn` stays bare
  — commit_shape models the DEV, one stream across all hooked repos; the
  blending is the feature, per-repo texture rides each card's `source` and
  ticket. A per-repo churn norm would be a different instrument with a
  dotted name, floated on its own merits.)
- **Membrane coupling goes through the agent, never around it.** The
  `membrane: true` declaration field is already consumed on the commit-side
  hop (a belief signal in a commit trailer routes into the `.membrane` store).
  The reverse direction — bus/world signals updating beliefs — is walk work:
  model-fired flinches route to the `agent` sink, and converting a standing
  flinch into an `evolve`/`correct` on the corpus (with its `Signal:` trailer)
  is a judgment the agent makes on the walk. Mechanical writes to the belief
  corpus are banned by the same razor that splits declared from computed
  signals: if catching it needs taste, it is declared, not computed.
- **The quick runnable pin — the grill's exit condition.** When a vision
  resists capture, grill until it reduces to something a script can measure,
  then give it a body: `models/<slug>/run.sh` + `ASPIRATION` marker in any
  governed dir. Minutes, no suite, no framework — wm discovers by convention.
  Red is its honest resting state; the board carries the gap forward so the
  ask never has to be repeated. (This is the anti-evaporation move: the
  five-times-asked vision was the disease; the pin is the cure.)

## The Declare-First Signal Catalog — three bindings, one namespace, tiers inferred (walk, 2026-07-08)

The catalog is not a flat pile of `signals/*.signal`; it is a namespaced corpus
with three **bindings**, and — the load-bearing move — the binding is *inferred*,
never stored as a field. This is the structural companion to declare-first above:
declare-first says *build the catalog forward*; this says *what shape the forward
corpus takes*.

**The cut is what the artifact is bound to, not what it watches.** Domain (what a
signal watches — commit churn, mood, regression time) is the *second* token; the
*first* token carries binding, because binding decides where the declaration lives
and what it travels with. Three bindings, each with a home that already exists:

- **repo-bound** — lives in `<repo>/signals/`, committed, travels with the repo
  through clones and worktrees. Watches that repo's own artifacts
  (`commit.churn`, `regression.wall-seconds`, `test-health`). The canonical set
  is the one listed in the bus home's `registries` file; **worktree clones are
  deliberately excluded there** ("a stale clone registry must never shadow the
  canonical one"), so the on-disk duplication across worktrees is cosmetic, not a
  routing hazard — the router reads canonical-only.
- **project-bound** — **no artifact and no home.** A project seldom fits one repo,
  so "project" is an *inferred lens* computed at read time, never a materialized
  directory. It reuses prose's `neighborhood.ts` verbatim: tokenize a repo
  basename on `-_.`, IDF-weight the tokens across sibling dirs (rare tokens like
  `koru`/`6digit` score strong, common ones approach zero), recency-gate on git
  activity (14d) so stale name-collisions drop out. A project-scoped read resolves
  the neighborhood and unions the signals across it. `prose link` is the explicit
  override for the rare case name+recency misses — inherited, so even the override
  needs no new artifact.
- **system-bound** — lives at the bus home (`~/.6digit-cordial/signals.d/` +
  `registries` + `signals.json`), outside every repo. Holds the **rootless**
  signals: routing tables and sink defs, the machinery-watching-itself probes
  (`heartbeat-probe`, `narrator-deaf`), and the dev/collaboration signals that
  watch *the human and the work*, not any repo (`human-frustration`, `lars-mood`,
  `trust`, `correction`).

**The namespace is `<lead>.<domain>.<leaf>`, and the lead token both names the
family and *decides the tier* — no tier field is maintained.** The lead is one of
two things:

- a **family token** (`koru.regression.wall-seconds`, `6digit-world.commit.churn`)
  — repo/project-bound. It self-declares belonging because it is the literal input
  to prose's tokenizer; a signal quoted out of context still names its family.
- a **reserved system word** (`dev.mood.frustration`, `meta.faucet.dark-count`) —
  system-bound, because these signals are *rootless*: they have no repo to lead
  with.

**The tier discriminator is free: feed the lead token to prose's neighborhood
resolver.** If it matches real sibling repos, the signal is family-bound; if it
scores zero against every repo, it is a reserved system word and the signal is
system-bound. *Whether the lead resolves to a neighborhood IS the tier* — the same
mechanism that groups repos sorts the tiers, with no manifest and nothing to keep
in sync.

**The rootless class is a discovery, not just a bucket.** Naming it as its own
class is what made the whole model fall out: the dev/collaboration signals had been
copy-pasted into every repo, which *disguised them as repo-bound* when they never
were — they watch the human and the collaboration. The reserved lead vocabulary
starts minimal and **open**: `dev` (the human & the collaboration), `session`
(agent/arbiter runtime), `meta` (the regime watching itself). It is a starting
vocabulary, not a fence — a signal earns a new reserved lead only when something
real fits none of the three. Everything that is *not* a reserved word must resolve
to a real repo family or it is rejected: that rejection is the pit-of-success wall.

## The tending loop — live is replay arriving slowly

An instrument is never finished; it is tended:

1. Replay ≡ live for model semantics; live adds only *operational*
   surprises (faucets dying, revisions), which route to channel-watchers,
   not the world model. (Semantics-equal never makes the live tick
   optional — see "Dumb signals, smart engine" above.)
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

**Declare first — the catalog is built FORWARD, never backfilled from recurrence
(Lars, 2026-07-07, overriding and deleting the prior "tool by recurrence"
caution, which had been re-encoded several times and was wrong every time).** The
deleted doctrine said: don't build a capture organ before the pain of losing
surprises has recurred; wait, let recurrence earn the tool. It is wrong for one
decisive reason — **you cannot feel the pain of a missing instrument, because
nothing is watching the place it would watch.** A signal never declared is
indistinguishable from a world with nothing to say there; the absence is silent
*by construction*, so "wait for the pain to recur" is a gate that can never
physically open. Backtracking from a spark of inspiration into the signals a
model implies does not work and never did.

So the discipline **starts** with declaration. Sit down and brainstorm, float,
and define as many signals as possible — hundreds, a thousand — each landing
DARK, RED, or inactive, most with no faucet yet and no obvious place one would
go. That standing corpus of un-fauceted declarations is not debt; it is **the
single highest-value asset the regime holds**, because it is exactly the surface
you gap-close against: `wm faucets` turns it into a screaming work-list, and
every dark signal is a commission waiting. Declaring is cheap, forward, and the
whole point — declare aggressively, up front, *before* the faucet is known or
even locatable. (The ratchet below still governs **promotion** — a dark
declaration graduating into a fully tended, flinch-gated instrument with a wake
route still earns its keep, and most never will. What is deleted is any gate on
*declaring* in the first place.)

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
