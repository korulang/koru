---
name: membrane
description: Tend the membrane memory corpus — an OKF concept store whose fragment evolution lives in the git log as lineage trailers. Fire when creating, evolving, merging, splitting, or CORRECTING durable memory/knowledge that lives as OKF files under git; when recording how a belief changed or was repudiated; or when tracing a concept's history through time. YOU are the evolver — there is no evolution engine and no LLM sidecar. NOT for transient notes, scratch, or code comments.
---

# membrane — memory as a disciplined git log over OKF

The membrane is a memory corpus with one move: **the agent updates the knowledge,
and in the same act records how it evolved — into the git log.** There is no
fragment-evolution engine, no proprietary store, no required embedding model. The
intelligence (which concept is this? evolve or correct? what's the lineage?) is a
**judgment you make as you write**, not a technology. git is the temporal ledger;
OKF is the on-disk shape; you are the evolver.

## The prime directive — prose drifts; running code is the real memory

We **loathe** encoding in prose what could be encoded in running code. Prose drifts
as fast as it possibly can, and even a disciplined evolution process just makes it
**double-bookkeeping** — the same belief maintained in two places, guaranteed to
diverge. So the membrane is never the *home* of a belief that code could hold; at
most it is a **larval** holding-pen on the way to code, or a **pointer** to where
the code already holds it.

This makes gardening **bidirectional**. Gardening doesn't only pour beliefs *in* —
its higher act is **evolving them OUT**: promoting a fragment into running code (a
unit test, a regression test, a compiler wall, an engineered organ) and leaving
behind only a **pointer** to that code as the residue. A fragment that has *not*
yet been evolved into code is a debt, not an asset — prose waiting to drift. The
permanent, honest residents of the corpus are the things code **structurally
cannot hold** (repudiations, irreducible whys, regime changes — see intake below)
plus pointers to the code that holds everything else.

**Caveat we hold honestly:** for a *game* (or any project whose value is felt, not
tested) — feel, juice, whether a fight is *fun* — much cannot be pinned by a running
test today. Those beliefs live longer in prose than an engineering belief would —
not because prose is good, but because the running-code home doesn't exist yet. That
gap is a standing invitation to build the missing instrument, never a licence to let
the prose calcify.

## The ambition — read this first, it decides everything

We are **not encoding truth.** We are encoding an *iteratively improving
approximation* of truth. A wrong belief was a legitimate prior state of the
approximation; the correction is itself fallible. Three consequences, load-bearing:

- **Nothing is deleted.** Ever.
- **History is never rewritten.** No rebase, no force-push, no amend of landed
  commits. (The value-tickets, replay, and content-addressing all depend on
  immutability — and the record of having been wrong is part of the honest
  approximation.)
- **Correction is always a *forward* commit** that *marks* the past, never erases
  it. The corpus improves by accumulating forward corrections.

## What goes in — the intake rule that keeps this from becoming an abstraction over code

The single failure that would make the membrane worthless: **restating what the
code already says.** A fragment that mirrors an API, a value, a data-flow, or a
test's assertion is a second source of truth that drifts — the stale
description-of-a-thing-that-describes-itself. The code IS the spec; a membrane that
duplicates it is exactly the abstraction-over-code we reject. Duplication is not
prevented by tooling — it is prevented *here, at intake*, by deciding what is even
allowed to become a fragment.

**The litmus, one line — apply it before every `create`/`evolve`:**

> *If the code (and its tests) were the only artifact left, would this be LOST?*
> If **no**, it does not belong in the membrane.

Only what the code **structurally cannot hold** earns a fragment:

- **Repudiation — the load-bearing case.** *"We believed X; X was wrong."* Code
  provably cannot record this: when you fix it, the wrong design is simply *gone* —
  the working tree never says it was ever believed. The `correct`/`Severs` verb is
  the membrane's whole reason to exist: the ledger of where our code-as-spec was
  wrong. This is the **anti-abstraction**, not an abstraction over code.
- **Irreducible why.** The rationale, the constraint that forced a tradeoff, the
  alternative rejected *and why* — decision context that lives in no file.
- **Regime change.** A shift in how we work or understand the domain — a stance,
  not a fact.

**Banned at intake (these ARE the duplication):**

- restating code — a signature, a value, "X calls Y", a data flow; anything a
  reader would learn by reading the source;
- restating a test — the pin *is* the record; do not mirror it as a "belief";
- status / progress / counts — that's the world-model signals and the git log, not
  a durable belief.

**The second gate — a fragment must be able to be WRONG (encoded 2026-08-04).**
The bans above catch *duplication*. They do not catch *platitude*, and a belief
hedged until nothing could contradict it clears every one of them. So ask it
directly, right after the litmus:

> *What future observation would `correct` this?*

If there is none, it is not a belief — it is decoration. `correct`/`Severs` is
this corpus's whole reason to exist, so a fragment that can never be corrected is
structurally excluded from the membrane's own purpose while satisfying every
other rule at intake. The temptation runs one way and is worth naming: weakening
a claim makes it likelier to survive, and a claim that survives everything taught
you nothing by surviving. Write the belief sharp enough that being wrong about it
would show.

Because most commits change code without changing a belief, **`Evolution:
acknowledged-none` is the common, correct answer** and the corpus stays small *by
design*. A membrane that is growing fast is a membrane being abused as a code
mirror — treat rapid growth as a smell, not success.

## The store

- One concept = one OKF markdown file, keyed by a **stable opaque id**, not by its
  text: `concepts/frag-<id>.md`. The id never changes as the belief evolves —
  identity is the filename; the belief is the body.
- Frontmatter: `type`, `id`, `provenance`, `ts` (+ optional `tags`, `resource`).
  Body = the current belief, in prose.
- The **working tree** is the live corpus (current beliefs). **git history** is
  everything that's been occluded or repudiated — reachable, never gone.

### Where the store lives — the `<store>` pointer

`<store>` is the path to the store repo. A project declares it in
**`.claude/membrane.json`** at the repo root:

    { "store": "../koru-membrane" }

- Resolved relative to the repo root — siblings under one parent are `../<name>`.
- **No `membrane.json`** → the store is **in-repo**: `concepts/` in the project
  itself, hook in the project's own `.git/hooks`. The simple single-project default.
- **Pointed** → a **shared** store: many repos name the same external store, so one
  corpus serves a whole family. The koru family uses this — koru, koru-libs,
  korulang_org all point at the `koru-membrane` sibling repo.

The `commit-msg` hook lives in the **store** repo's hooks (it enforces *corpus*
commits, which land in the store, not in the consumers). Install it once, there.

## The six-verb lineage discipline

Every commit to the corpus carries a trailer block. The verb is the judgment.

```
<verb>(<id>): <one-line summary>

Action:     create | evolve | merge | split | correct | move
Concept:    frag-<id>[, frag-<id>...] # the resulting/affected concept(s)
Occludes:   <blob-sha>                # evolve ONLY — the prior belief's blob (reachable)
Parents:    frag-<id>[, frag-<id>...] # merge/split ONLY — the lineage DAG edge
Severs:     frag-<id>@<blob-sha>      # correct ONLY — the repudiated lineage point
Reason:     <why the prior line was wrong>   # correct ONLY
Custody:    <from> -> <to>            # move ONLY — where the belief is now kept
Provenance: <session / conversation / source of this update>
Signal:     <type> [value=<n>] [<note>]     # zero or more — the WMFX faucet (see below)
Signals:    none                            # REQUIRED if there are no Signal: lines
```

Choosing the verb:

- **create** — a new belief that doesn't belong to any existing concept.
- **evolve** — an existing concept, *superseded but was-valid*: the world moved,
  the belief refined. `Occludes:` the prior blob. *("Walls were sage; I repainted
  them white.")*
- **merge** — two concepts are actually one. One commit deletes both source files,
  writes the unified one; `Parents:` lists both (both occluded by this commit).
- **split** — one concept is actually two distinct beliefs. `Parents:` the original.
- **correct** — an existing concept was *wrong* — a smear, a mis-extraction, a bad
  merge. Not superseded — **repudiated.** `Severs:` the bad lineage point +
  `Reason:`. Stays on the *same* file/id: a discontinuity *within* an identity,
  not a new identity.
- **move** — **custody, not content.** Where a belief is KEPT changes; what is
  believed does not. A corpus absorbing another store's concepts, or a repo that
  stops being a store handing its concepts to the one that is. `Custody:` names
  from and to. This is the ONLY legal way a concept file may leave a tree, and it
  is legal precisely because it is not a deletion: the content stays reachable in
  history, and the gate refuses a `move` whose blob changed — a move that also
  edits is two acts, moved then evolved. Keeping them separate is what leaves
  "custody changed" and "the belief changed" separately answerable later.

  The limit is stated rather than hidden: a hook cannot read the destination
  repo, so custody-IN cannot be verified mechanically. `Custody:` is a claim a
  reader checks. What IS verified is that nothing is lost on the way out.

**The one hard discernment is evolve vs. correct.** Evolve = "this *was* true, now
it's different." Correct = "this was *never* right." Mislabel a correction as an
evolve and you bury an error as honest history; mislabel an evolve as a correction
and you slander a valid past. **When genuinely unsure, it's evolve** — reserve
`correct` for real defects.

Occlusion and severance are the **two ways the past stops being current**, and the
trailer is the only thing that distinguishes them. Both are forward; both keep the
full history.

## Faucet signals — the carrier; the meaning lives in world-modeling

The membrane commit is also WMFX's **universal envelope**: `source` (= membrane),
`ts` (= commit time), and `claim_id` (= the commit SHA — the content-addressed
value ticket) all come from the commit, so a `Signal:` trailer **derefs back to the
exact memory change that triggered it, for free.** This skill owns the **carrier
and its enforcement** only.

**What counts as a signal, and the bar, are NOT defined here** — they are
world-modeling doctrine, in the `arbiters-worldmodel` skill (the
"discipline-declared signal" path). Read it for the *meaning*; what follows is
just how membrane carries and enforces it:

- Format: `Signal: <type> [value=<n>] [<note>]` — one per attention-worthy signal;
  `source`/`ts`/`claim_id` come from the commit.
- **Every commit must declare**: a `Signal:` line, or an explicit `Signals: none`
  (a conscious "I considered it; nothing here"). The hook rejects silence.
- **Interlock**: a `correct` is intrinsically attention-worthy, so it may **not**
  declare `Signals: none` — it must carry at least one `Signal:`. The hook enforces it.

## Write-time loop (this replaces the evolution engine)

1. **Survey** — what concept(s) does this update touch? Read/grep the store. (Later,
   optionally, embedding-match to find candidates.)
2. **Decide the verb** — create / evolve / merge / split / correct.
3. **Edit** the file(s) — opaque-id filename, belief in the body.
4. **Commit** with the trailer. The hook rejects a malformed one.

Spend the time this needs. You are the intelligence; there is nothing behind you.

## Querying through time

- **Current belief** — read the working-tree file.
- **A concept's whole trajectory** — `git log -E --grep="Concept:[[:space:]]+frag-<id>"
  --format="%h %ad %s%n%b" --date=short`.
- **Belief at time T** — `git show <commit>:concepts/frag-<id>.md` (read-only;
  **never `checkout`** — it mutates the tree and can clobber untracked sidecar state).
- **Lineage / parents / occlusions** — parse the `Parents:` / `Occludes:` / `Severs:`
  trailers from the log.
- **Suspect descendants of a defect** — from a `Severs:`, trace `Parents:` edges
  *forward* to find every concept that merged from the repudiated point. They are
  not auto-corrected (that's a later judgment) — but they are now *visible* as
  suspect. This is the discipline-side answer to smear.

## The typed log is the visualization bridge

The commit log is not just storage — it is a **strictly-typed IR**, and the
visualization surface is a *pluggable renderer* over it (WMFX's "emit, not render"
doctrine: a first-class graph IR with pluggable emitters). The bridge contract is
the trailer grammar; the surface consumes it, never the reverse.

**The principle: strict typing in the log funds visual richness.** Every typed
field is an affordance the renderer can spend. Loose prose renders as a flat list;
a tight schema renders as a living graph. So tightening the trailers is not
bureaucracy — it is *buying* visual expressiveness, and that is the forward
flywheel: each new typed field unlocks a new visual dimension, which is the reason
to keep the discipline sharp. The walk feeds it for free — every membrane commit a
`/arbiters` session makes is one more typed event the surface renders, live.

Starter field → affordance map (the renderer's vocabulary):

| Trailer field | Visual affordance |
|---|---|
| `Action: create` | a new node appears |
| `Action: evolve` + `Occludes:` | node updates; prior state a faded ghost behind it |
| `Action: merge` + `Parents:` | two nodes converge into one |
| `Action: split` + `Parents:` | one node forks into two |
| `Action: correct` + `Severs:` | a **visible cut** in the lineage — a scar, not a smooth step |
| `Action: move` + `Custody:` | the node migrates between corpora — a translation, not a state change |
| `Signal: <type>` | colour / glyph by type (surprise, smear, regime-change, correction) |
| `Signal: … value=<n>` | intensity / size / glow by strength |
| `claim_id` (commit SHA) | the node's stable handle; click-through to the exact change |
| `ts` (commit time) | position on the time axis |

The surface can be as **flamboyant** as the schema is strict. Surface binding: the
renderer is **6digit-cordial** — the Hollywood-OS development HUD (the Iron Man
transparency plane, literalized). Cordial renders two feeds from the same substrate:
membrane lineage/signal walks (this log) **and** WMFX world-model state (the `wm`
tool, which stores state). Everything above is surface-agnostic and holds for any
renderer; Cordial is the target.

## The enforcement hook — the UNIVERSAL gate (the definition of a well-formed repo)

The gate is not optional tech; it is what makes a repo **well-formed for ADD**. A
repo without it can *hold* a corpus but cannot *keep* one — gardening that isn't
forced by the commit is gardening that never happens (the failure this whole
discipline exists to kill: 90% of the machinery present, sitting outside the
commit loop). So the well-formedness bar is exact and simple:

> **A well-formed repo has the membrane gate installed and firing.** Measured by
> the *presence of the enforced question*, NEVER by corpus size — a brand-new repo
> with an empty `concepts/` is fully well-formed; it just hasn't learned anything
> durable yet. Measure the wall, not the harvest.

The canonical, **tested** hook ships in this skill — do not re-derive it:

- `hooks/commit-msg` + `hooks/commit-msg.cjs` — the gate (below)
- `hooks/post-commit` + `hooks/post-commit.cjs` — the faucet (routes belief-class
  signals; surfaces every sealed signal to the Cordial plane)
- `hooks/install.sh` — drops the set into any repo (`hooks/install.sh <repo>`)
- `hooks/test/hook-test.mjs` — drives the real hook in a throwaway git repo and
  asserts accept/reject per case. Run it after any change to the gate.

One `commit-msg` hook enforces two disciplines from two markdown sections; each
tool parses only its own section, so they never collide:

**`## World Model` — universal.** Every authored commit declares a `Signal:` line
or a conscious `Signals: acknowledged-none`. Silence is rejected.

**`## Membrane` — universal too (this is the change that closes the loop).** Every
authored commit answers "did a durable belief change here?" with exactly one of:

- a lineage `Action:` (create/evolve/merge/split/correct/**move**) **with every
  staged concept file named in the declaration** — the belief and the code that changed it land as
  one atomic commit, so `git log` itself holds the fragment evolution; or
- a conscious `Evolution: acknowledged-none` — "I considered it; nothing here
  changed a durable belief." The forced *pause* is the point: typing it is the
  moment you might catch that something *did* change.

**The interlock (the leak-closer).** A `Signal:` whose interface is `membrane:
true` (contradiction / correction / regime-change) is a declaration that a belief
changed — so `Evolution: acknowledged-none` becomes a lie and the gate rejects it.
You said a belief changed; you must garden it *in this commit*, never queue it to
an inbox that no one drains.

**The coverage wall (added 2026-08-04).** The gate used to validate a
declaration's SHAPE — legal verb, required fields present, referenced blobs
resolve — and never ask whether it COVERED the commit. So a commit could stage
twenty-five concept files, declare one `Concept:`, and the other twenty-four rode
through undeclared and unexamined; a real commit did exactly that and passed. Every
staged `concepts/frag-*.md` must now appear in `Concept:`, `Parents:` or `Severs:`,
and `Concept:` takes a comma-separated list. **A gate you can satisfy without doing
the work is worse than no gate, because it certifies.**

**`move` — custody, not content.** The other five verbs all answer *what changed
about what is believed*; nothing answered *where it is kept*. A corpus absorbing
another store, or a repo that stops being a store, could not be committed honestly
at all — the gate rightly refuses to let concept files vanish without a verb, and
rightly had no verb for that. `move` is legal precisely because it is not a
deletion: the content stays reachable in history, and the gate **refuses a `move`
whose blob changed**, so a move that also edits is two acts. The destination lives
in another repo the hook cannot read, so `Custody:` is a claim a reader checks —
that limit is stated rather than implied away.

**Trailer whitespace is part of the grammar.** Authors align these fields into a
column, which produces two spellings of one field and silently breaks the
trajectory query above — `git log --grep="Concept: frag-<id>"` matches no aligned
commit and reports the miss as *no history*. The hook normalises trailer spacing
before anything parses it, so the log stores one spelling while the author keeps
the habit.

**Mechanical scaffolding (the ever-improving cheap step).** When the commit stages
exactly one concept file, the hook derives the deterministic trailer fields from
the staged diff — `Concept:` from the filename, `Occludes:` from the file's prior
blob on an `evolve` — and writes them back into the message. The agent supplies
only *judgment* (the verb and the belief); the hook supplies the bookkeeping. This
is doctrine-safe: it scaffolds lineage, it never *decides* a belief. Reading the
*code* diff to auto-write a *belief* is the forbidden LLM-evolver — the gate never
does that.

All the original lineage validation still holds (Occludes must be a reachable
blob, merge/split Parents must resolve, correct needs `Severs:` + `Reason:` and may
not be `acknowledged-none`). See `hooks/commit-msg.cjs` for the authoritative
logic and `hooks/test/hook-test.mjs` for the behavior it guarantees.

## Embeddings — deferred, back-fillable (do NOT build until needed)

git + OKF is the **complete source of truth.** A JINA index over `(concept, commit)`
is a *derived cache* you can rebuild from history in one pass at any time — so
nothing is lost by shipping without it. It buys exactly one thing: **cold semantic
retrieval** (a query whose words don't match the stored text). Measured on
LongMemEval s-10q, plain keyword search already hits ~90% recall, so embeddings are
a ~10% tail optimization, not a load-bearing part. Reach for them only when that
tail becomes the bottleneck — and back-fill the whole index then.

## Optional tooling (benefits split by who it serves)

- **Traversal helper** (`membrane trace/at/suspect`) — encodes the query commands
  above once. A convenience *for the agent* (consistency, fewer tokens). Not required.
- **Lineage visualizer** — reads `git log`, renders evolutions as continuous lines
  and `correct`/`Severs` as explicit cuts. This is the *human's* transparency plane:
  how the corpus's history and health are seen **without poking**. High value for the
  human, marginal for the agent — build it for that purpose.

## Never

- Rewrite history (rebase/amend/force) — corrections are forward commits.
- Delete a concept to "remove" a wrong belief — `correct` + `Severs` it forward.
  A concept file may only leave a tree under `move`, which is not a deletion: the
  content stays reachable in history and provably continues elsewhere.
- Skip the trailer, or hand-wave the verb — the hook will reject it, and a silent
  evolve-vs-correct mislabel corrupts the time-travel.
- Reach for an LLM or embedding "evolver" — you are the evolver; that's the point.
