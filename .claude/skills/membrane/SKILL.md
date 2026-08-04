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

    { "store": "../koru" }

- Resolved relative to the repo root — siblings under one parent are `../<name>`.
- **No `membrane.json`** → the store is **in-repo**: `concepts/` in the project
  itself, hook in the project's own `.git/hooks`. The simple single-project default.
- **Pointed** → a **shared** store: many repos name the same external store, so one
  corpus serves a whole family. The koru family uses this — `koru-libs` and
  `korulang_org` name `../koru`, and `koru` itself declares nothing because
  in-repo is the default. (Until 2026-08-04 they all named a `koru-membrane`
  sibling that had stopped moving nine days earlier; the corpus was split in half
  and every pointer named the dead half. One store, one pointer mechanism.)

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
2. **Decide the verb** — create / evolve / merge / split / correct / move.
3. **Edit** the file(s) — opaque-id filename, belief in the body.
4. **Commit** with the trailer. The hook rejects a malformed one.

Spend the time this needs. You are the intelligence; there is nothing behind you.

### A concept is a BELIEF — never a prose copy of runnable code

**Never duplicate in prose what exists as runnable code.** (Lars-ruled
2026-07-10, after a concept file restated probe findings, file:line
citations, and implementation inventories that the code, tests, and commit
message already held.) This is the membrane instance of the no-state-prose
ruling for tests: prose that duplicates code-derivable state is context
poison — stale the moment the code moves, and nothing in the workflow moves
the prose with it.

- A concept body carries what NO tool can derive: the ruling, the why, the
  direction, the open questions, the judgment. That is belief.
- What code/tests/pins/commits already encode — current behavior, line
  numbers, which tests are red, what a probe showed — is **referenced by
  name** (`the 310_104 pin`, `the import gate`), never restated. The
  reference stays true when the state flips; the restatement lies.
- Detector at write time: if a sentence would need editing when the code
  changes *without the belief changing*, it is state, not belief — cut it.
- Second detector, a different class: **could this belief ever be WRONG?** The
  rule above catches *duplication*; it does not catch *platitude*, and a belief
  hedged until nothing could contradict it clears it untouched. So ask outright —
  *what future observation would `correct` this?* No answer means it is not a
  belief, it is decoration. `correct`/`Severs` is this corpus's whole reason to
  exist, so a fragment that can never be corrected is structurally excluded from
  the membrane's own purpose while satisfying every other rule at intake. The
  temptation runs one way and is worth naming: weakening a claim makes it likelier
  to survive, and a claim that survives everything taught you nothing by
  surviving. Write it sharp enough that being wrong about it would show.
  (Encoded 2026-08-04.)

## Reading the corpus — `snap`, never the whole thing

The corpus never deletes, so "read the membrane before you start" is an
instruction whose cost grows without bound. **`snap` is the bounded read**, and
it is the default way to arrive at the corpus:

```sh
node <store>/snap.mjs                      # bounded snapshot, ~6 KB
node <store>/snap.mjs --bytes 16000        # wider — covers every concept
node <store>/snap.mjs --concept frag-<id>  # drill: full belief + its lineage
node <store>/snap.mjs --json               # structured, for a renderer
```

Detail decays with **heat** (git recency, then how often a concept has been
revised). Hot beliefs arrive whole; below that a concept is its title plus its
last change; below that the one-line commit subject alone; and the tail is named
but not described. Every concept lands in exactly one tier, so the corpus's true
width is always visible even when its contents aren't.

`snap` is **pure-read and fully derived** — git plus the working tree, no index,
no cache, no state. It never writes and never demands work in return, so call it
as freely as you like. Run it from a repo whose `.claude/membrane.json` names a
store and it finds it on its own; with no pointer it reads the cwd, which is the
in-repo case. Otherwise pass `--store`.

Read the whole corpus only when you have a reason that names it. Reach past
`snap` with the queries below.

## Querying through time

- **Current belief** — read the working-tree file.
- **A concept's whole trajectory** — `git log -E --grep="Concept:[[:space:]]+frag-<id>"
  --format="%h %ad %s%n%b" --date=short`. The whitespace class is not
  decoration: commits written before 2026-08-04 aligned their trailers into a
  column, and a literal `"Concept: frag-<id>"` matches none of those and reports
  the miss as *no trajectory* rather than as a bad query. The `commit-msg` hook
  now normalises trailer spacing, so new commits match either form — the
  tolerant spelling is what also reaches the history behind it.
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

## The enforcement hook (the one piece of required tech)

A `commit-msg` hook validates the trailer so the discipline can't silently drift —
encode the discipline into something that fires on its own. It must:

- require an `Action:` from the six verbs and a `Concept:`;
- require `Occludes:` on evolve; `Parents:` on merge/split; **`Severs:` AND
  `Reason:` on correct**; `Custody:` on move;
- **require the declaration to COVER the commit** — every staged
  `concepts/frag-*.md` must be named in `Concept:`, `Parents:` or `Severs:`.
  Without this the gate checks a declaration's shape and never its reach, so a
  commit can stage twenty-five concepts, declare one, and the rest ride along
  undeclared. That is not hypothetical: it passed here on 2026-08-04, and it is
  the same defect shape as a correction applied to one term of a multi-term
  aggregate. A gate you can fill in the form of and walk around is worse than no
  gate, because it certifies.
- **refuse a `move` that edits** — if a staged concept exists in both `HEAD` and
  the index under `Action: move`, its blob must be unchanged. Custody and content
  are separate claims and must stay separately answerable;
- require a faucet-signal declaration on every membrane commit — a `Signal:` line
  **or** an explicit `Signals: none`; and **forbid `Signals: none` on a `correct`**;
- reject the commit (non-zero exit) on any violation, printing what's missing.

Reference logic (Node; install at `<store>/.git/hooks/commit-msg`):

```js
const msg = require("fs").readFileSync(process.argv[2], "utf8");
const f = (k) => (msg.match(new RegExp("^" + k + ":\\s*(.+)$", "m")) || [])[1];
const action = f("Action");
const need = { create:[], evolve:["Occludes"], merge:["Parents"], split:["Parents"], correct:["Severs","Reason"], move:["Custody"] };
const fail = (m) => { console.error("membrane: rejected — " + m); process.exit(1); };
if (!action) process.exit(0);                       // non-membrane commits pass
if (!need[action]) fail(`unknown Action '${action}'`);
if (!f("Concept")) fail("missing Concept:");
for (const k of need[action]) if (!f(k)) fail(`Action ${action} requires ${k}:`);
const none = /^Signals:\s*none\b/im.test(msg), nSig = (msg.match(/^Signal:\s*\S+/gim) || []).length;
if (!none && !nSig) fail("declare a 'Signal:' line or 'Signals: none'");
if (action === "correct" && !nSig) fail("correct is intrinsically a signal — not 'none'");
```

## Embeddings — deferred, back-fillable (do NOT build until needed)

git + OKF is the **complete source of truth.** A JINA index over `(concept, commit)`
is a *derived cache* you can rebuild from history in one pass at any time — so
nothing is lost by shipping without it. It buys exactly one thing: **cold semantic
retrieval** (a query whose words don't match the stored text). Measured on
LongMemEval s-10q, plain keyword search already hits ~90% recall, so embeddings are
a ~10% tail optimization, not a load-bearing part. Reach for them only when that
tail becomes the bottleneck — and back-fill the whole index then.

## Optional tooling (benefits split by who it serves)

- **Traversal helper** (`membrane trace/at/suspect`) — encodes the `Parents:` /
  `Severs:` walks above once. `snap --concept` already covers a single concept's
  trajectory; what's left is forward smear-tracing. Not required.
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
- Duplicate in prose what exists as runnable code — beliefs reference code and
  tests by name; they never restate their contents (see the write-time loop).
