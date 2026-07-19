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
