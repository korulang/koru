---
type: belief
id: frag-pointfree-threads-the-branch-left
provenance: introduced on branch pointfree-choke-chain — feat(parser+desugar): point-free |> pipelines with the choke
ts: 2026-07-19
---

# A bare `|>` threads the one branch LEFT — name a continuation only when it is ambiguous (belief)

The threading pyramid — a flow that binds one state through N stages, re-raising
the same failure branch at every level (`koru_std/compiler.kz`'s `analysis` was
six deep) — is `>>=` hand-unrolled. A point-free chain writes it as a line:
`~head |> stage |> stage` with ONE dedented choke handler. The surface is new;
the semantics were always there.

**What a bare `|>` means.** A continuation whose branch is unnamed threads the
**one branch LEFT** at that stage — the single declared branch not claimed by an
enclosing handler. This is decided by **arity, not polarity**: Koru has no
success path and no failure path (it never has), so the thread cannot be "take
the good branch." It is "take the sole survivor." The choke is not an
error-handler; it is a *claimer* that removes branches from the count, and a
stage threads exactly where the claims leave one survivor.

**The rule this refines.** Previously every flow continuation had to name its
branch, and `|>` could not begin a line (KORU010) — a `bare `|>` picks nothing"
doctrine (220_016: "no implicit positive case, no default"). That refines, it is
not discarded: **name a branch only when more than one is left; the sole survivor
names itself.** The danger 220_016 guarded — an *ambiguous* unnamed continuation
— is still a hard error (>1 left → forced to handle). Only the unambiguous case,
which the old rule also forbade, is now allowed. KORU010's line-start prohibition
was deliberate corpus-shaping scaffolding; it retired once the corpus had settled
into the shape it was training.

**Why it stays safe.** Because no branch is privileged, the compiler can never
silently pick a winner among several. Claiming is total (every produced branch is
claimed or is the survivor — no silent swallow) and exact (a claim that matches no
produced branch is a dead claim, rejected). This is bind generalized over polarity:
`Result`'s `>>=` freezes which branch threads into the type; here the caller's
claims decide, so the thread can carry what another language would call the error.

**A choke claims over the CHAIN, and lands per STAGE.** These are two different
scopes, and collapsing them into one was a real defect — worth stating as a
belief because the wrong answer is the intuitive one. A ladder does not have to
re-raise the same branch at every rung: the honest shape of a result API is
heterogeneous (`| not-found` from an object lookup, `| out-of-range` from an
index, `| wrong-type` from a cast), and a chain over such stages threads
perfectly well, because "sole survivor" is computed *per stage* against whatever
claims that stage happens to declare. So a choke must **replicate onto the
stages that declare it**, not onto all of them — an arm cloned onto a stage that
never produces that branch is a dead arm the coverage wall rightly refuses.

Exactness then has to move up, or it disappears: with per-stage filtering a
mistyped claim would be filtered out everywhere and silently dropped. So the
dead-claim wall lives at the **chain** — a claim must land on at least one
stage, refused at the choke, naming the word that was got wrong. Chain for
exactness, stage for replication; neither scope substitutes for the other.

Corollary worth keeping: **uniform-branch ladders are the degenerate case, not
the representative one.** `analysis` in `compiler.kz` is `| failed` six times,
so the ladder that proved the feature was the one shape that could not expose
the limit. A feature validated against its most favourable case reads as
universal until something outside asks it a different question — here, an app in
koru-examples with three duplicate `close(doc)` arms a reader noticed by eye.

**How it is realized (see, do not restate — code moves):** the parser accepts the
surface (leading-`|>`, bare-identifier stages, multi-line stitch) and a desugar
pass rewrites the point-free AST into the canonical continuation pyramid before any
checker runs — thread the survivor, replicate the choke across stages, close the
terminus — so downstream stays frozen. Pins: 210_151 (threads), 210_152 (choke
catches at runtime).

**Open questions.** (1) The forced-handle diagnostic (two branches left → reject
*at the claim site* naming what to disambiguate) is not built; today the generic
KORU022 coverage wall fires. (2) Value threading is strictly ONE step back;
reaching further is explicit — the ambiguity of multiple in-scope same-name
bindings is why. (3) Obligation discharge on an implicitly-threaded binding needs
a unique discharge pattern; ambiguous discharge must force an explicit bind. (4)
Effect (`!`) branches share the walls and the choke but do NOT thread — they emit
and resume; forward-threading is continuation-only.
