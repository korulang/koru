# Koru Verification Path — C Emit, IR Congruence, Proof-Carrying Obligations, Attested CI

Target branch: `Cypoe/koru:ccomp` (cut from updated upstream `korulang/koru`)
Status: design note for co-review with Lars. Non-negotiables are marked **N**; shape questions are marked **S**.
Working constraints honored: bring questions, never invent spellings; regression tests first; no builds while `run_regression` is live.

---

## 0. The trust pyramid

Four layers, each certifying a different thing. No layer substitutes for another:

1. **CompCert** — the *reference compiler* is correct (their theorem, their Coq proof).
2. **Alive2** — each optimization *instance* on our code shapes was checked (bounded, SMT-backed witness — not a theorem).
3. **Verified checker** — koru's obligation *verdicts* are correct (our theorem, in Lean, small).
4. **zkVM receipt** — the battery *actually ran*, on pinned artifacts (attestation of process, not of semantics).

A proof about semantics does not attest execution. An attestation of execution does not prove semantics. Every layer below is only as strong as the layer above it that it leans on — so each layer is pinned to the
one thing it can actually certify.

---

## 1. K1 — C emit + ccomp oracle

**Scope:** tier-1 runtime Koru, sequential, deterministic. This is a second independent realization of the
semantic space, not a replacement backend. The Zig emission stays the product path.

**Refusal table** (every entry refuses by name — silent acceptance is a red battery):

| Construct | Reason out of scope |
|---|---|
| host lines (raw Zig) | cannot lower to C |
| `!`-effect arms | resume semantics out of oracle scope |
| `pump` / `rings` / `worker.spawn` | CompCert is a sequential C subset; no verified concurrency |
| comptime/transform tors leaking runtime effects | tors vanish at compile time by definition |

**Dialect:** CompCert C subset — ISO C99 minus VLA, minus `setjmp/longjmp`, minus `long double`,
fixed-width integer types, CompCert C's defined evaluation order (use it — determinism of the reference
is part of the oracle contract).

**Lowering table:**

| Koru | CompCert C |
|---|---|
| tor | dispatch function; branches = tagged result |
| continuation arm | caller-side switch |
| binding | single-assignment local (const-initialized) |
| cell | module-scope array/struct (closed accessor set → static) |
| transform/comptime tors | nothing emitted; refuse if effects leak |

**Gates (canonical cells; missing oracle = FAIL, never SKIP):**

- **G-CC-1** equivalence: both backends, stdout bytes + rc. First program class: a finite byte transducer
  over `std/io`. Then prime-sieve parity.
- **G-CC-2** missing `ccomp` = FAIL naming the oracle path.
- **G-CC-3** refusal tests: every out-of-scope construct refuses with a named reason.
- **G-CC-4** determinism pin: pinned ccomp version + flags; same input → byte-identical binary.

**Acceptance**: G-CC-1 green on transducer fragment and sieve; refusal table complete; no upstream syntax
invented (emitter mode + transform tor; placement questions go to Lars).

---

## 2. K2 — LLVM IR congruence (Alive2-style)

**Mechanics:** `-fllvm` build leg; `getEmittedLlvmIr()`; Alive2 translation validation (requires an
RTTI-enabled LLVM build).

**Use A — instance checking:** validate LLVM's own optimization passes on koru-emitted IR.

**Use B — transform congruence:** emit IR before and after a koru-level optimization transform; Alive2 as
the per-instance equivalence witness.

**Honesty clause:** Alive2 is sound up to its bounds. The `-fllvm` leg is not the product binary when the
self-hosted x86_64 backend is the default — the ccomp oracle speaks for shipped artifacts. Document the
coverage map per target, per backend, per layer.

**Gates:** 
- **G-LL-1** opt-TV clean over the corpus arm
- **G-LL-2** negative control (two genuinely differing
IRs → Alive2 must flag).

**Landed (2026-10-13, 6aff63be6) — different shape than the sketch.** No
`-fllvm` leg exists; what shipped verifies *emitted-C optimization
congruence* instead: `scripts/alive2_gate.sh` clang -O0's a test's
`output_emitted.c` to reference IR and `alive-tv --passes=` proves each
intra-procedural optimization instance is a refinement of it. That is a
related but distinct claim from Use A — it establishes that the emitted
C holds no UB a mainstream optimizer can diverge on, which is exactly
the K1-complementary property: ccomp validates its own pipeline, alive2
validates arbitrary-pipeline safety of the artifact itself.
An `ALIVE2_CHECK` marker puts a regression test under the leg (needs
clang + alive-tv on PATH); 12 tests marked. The marker is the contract:
a marked test on a host without the oracles fails `alive2-oracle` naming
the resolved path — the G-CC-2 doctrine applied to K2, never a skip. Verdict discipline is strict
— incorrect/timeout/undecided fail — with named, counted scope
exclusions for alive2's structural limits (unmodeled libcalls,
sret/untranslatable signatures, unroll-bound loops); the parser's counts
are cross-checked against alive-tv's own summary. G-LL-2 measured live:
a same-signature `mul`→`add` IR forge reports `incorrect input_wmul`.
Use B (koru-transform congruence) stays unlanded — it needs the emitter
to expose pre/post IR, not a `.ll` from clang.

**Use B instrument landed (2026-10-14) — accounting level, not congruence
yet.** The exposure Use B was blocked on now exists: under
`std/witness:enforce`, every `whole_program` transform write-back commits a
`[witness] site transform-app` line — the site's canonical-AST digest plus
the multiset diff of top-level item digests (`rm=`/`add=`), and a
`transform-app-census` line per run. `whole_program` is the ONE splice
where a handler can rewrite items outside its site (`koru_std/taps.kz` is
the only producer); site-local results are confined by construction and
emit nothing. The comptime-only-site removal emits verdict `gc` — a
singleton site removal. The Lean oracle rules on accounting honesty: a
`wp` line must carry its site digest in `rm`; a `gc` line must be exactly
the singleton `{site}`; the census count must equal the application lines
(APP-DRIFT on mismatch).

**Blast-radius bound landed (2026-10-14) — the pass-graph `contract:preserves`
surface.** `[transform|contract:preserves(...)]` declares which top-level item
kinds a transform's write-backs hold invariant — the *allowed* set the
accounting was missing. Positive atoms list the preserved kinds;
negated atoms (`contract:preserves("!flow","!module_decl")`) mean "preserve every
kind except these" — closed under future `ast.Item` growth, which is why
`tap` declares the negated form (its measured write-back touches only
`flow` and `module_decl` items). At each `whole_program` application the
runner diffs touched kinds against the declaration: a removed or added
collateral item of a preserved kind refuses with KORU181 (transform name,
offending kind, site location, declared bound — the site item is always
licensed; `appended`-path results stay site-local and carry no bound
question). The committed line carries the bound and per-item kind tags
(`preserves=`,`rmk=`,`addk=`), and the Lean oracle independently
re-decides compliance from the kind vocabulary alone — a forged line
that claims a bound while touching a held kind rejects (`forged.txt:45`).
This is K2-Use-B congruence at the declared-surface level: the multiset
the accounting commits is now bounded by contract, not merely observed.
Digests include source locations — the accounting is path-sensitive by
construction; `310_140` and `220_062`/`220_063` pin the shape.

**Graph-arcs landed (2026-10-14) — the observed order is now itself a
corpus.** `pass_graph.validate` still decides the declared-vs-observed
check at frontend time (and still refuses on violation — the hand-written
order remains authoritative); what changed is that under
`std/witness:enforce` the backend commits what it checked:
`pass-graph-edge` lines for every declared pipeline requirement,
`pass-graph-order` lines for every root chain's flattened run order,
`pass-graph-tedge`/`pass-graph-tstage` rows for the transform surface,
and a `pass-graph-census` counting all four. The Lean oracle re-decides
the rules on the committed corpus alone — wherever a consumer runs in a
root order, every requirement must run strictly earlier; a transform
edge's producer must sit in a strictly earlier stage (`pre < main <
post`); the census must count the emitted lines honestly. A backend
that printed a graph it did not check gets caught at the gate, not
trusted at emission. `220_066` pins the live arcs with a `WITNESS_CHECK`
leg; `220_067` pins the gate itself — no enforce, no arcs; forged and
drift corpora carry malformed shapes, a reversed order, a same-stage
transform edge, and count drift.

**Obligations landed (2026-10-15) — a bound is not an obligation.**
`contract:preserves` says which item kinds a write-back may touch; it never
obligated the transform to justify a touch it was permitted. The
`[transform|contract:obliges(...)]` surface closes that: a closed vocabulary of
re-decidable claims about the write-back itself. `kind-stable` — the
collateral rm/add kind multisets must agree (the site item stays
licensed, as with `contract:preserves`). `matched-only` — every removed non-site
item must contain an invocation the transform fires on: no silent
consumption of unrelated items. `consume-only` — every invocation path
the write-back removed is the transform's own consumed call. The
vocabulary is closed at declaration
time (KORU185 refuses unknown predicates and `contract:obliges` on non-transform
decls); enforcement is unconditional — a violated obligation refuses
with KORU187 whether or not witnesses are emitted. Under enforce each
declared obligation commits one `transform-oblige` line per application
— the claim plus verdict; `kind-stable` carries no fields because its
whole evidence is already on the paired app line (`site`, `rmk`,
`addk`), while `matched-only` commits `justified=`, the matched
collateral digest set the app line does not carry. The app line gains
`;obliges=` and the census commits both counts. The Lean oracle
re-decides the predicates from the app's committed evidence alone — it
does not trust the `ok` verdict — and the corpus check requires every
declared obligation to pair with exactly one oblige line, so a dropped
or extra line is a refusal. One honest
consequence: obligations are enforced at canonical-digest granularity,
so a transform that *clones* items it does not change registers them as
touched — clone drift reads as a touch. The satisfied pin (`220_072`)
therefore passes untouched items through by value, which is the pattern
the obligation exists to force: clone only what you change.
Pins: `220_068`/`220_069` declaration refusals, `220_070`/`220_071`
enforcement refusals, `220_072` the satisfied shape; `koru_std/taps.kz`
declares `contract:obliges("kind-stable","consume-only")`.

**Runner-measured invocation delta landed (2026-10-29) — the third
obligation is decided over a delta the transform never sees.** Every
`wp` transform-app line now commits `sitepath=` (the consumed call's
canonical path) plus `inv+=`/`inv-=` — the `path*count` multiset delta of
invocation spellings below top level, collected by the runner over the
pre and post trees at the write-back boundary. The delta is measured,
not reported: the handler cannot under-declare what its splice did.
`consume-only` bounds it: `inv- ⊆ {sitepath}` — the transform may add
calls freely (that is its job) but may not silently delete or rename
away a call it was not fired on. `kind-stable` bounds item *kinds*;
`matched-only` bounds *which items* moved; `consume-only` bounds *which
call paths* vanished — the invocation-level analog of matched-only.
Measured first on the only live application before declaring it:
tap's actual delta is exactly `inv- = {std.taps:tap*1}`, `inv+ = ∅` —
the rewrite consumes only its own call. The granularity limit is named:
the law bounds the *path*, not the position — k removals of the consumed
path spell the same as one; positions are not in the multiset.
`220_075` pins the refusal (a write-back dropping a `victim` call
refuses KORU187); `310_140` pins the committed line; golden carries the
consume-only pair and drift.txt a forged `ok` whose `inv-` names a
non-site path.

**Dead-strip justification landed (2026-10-15) — the first Use-B transform
whose semantic claim is re-decided, not accounted.** `pass-dead-strip`
(src/dead_strip.zig) is the live pipeline pass whose correctness claim
reduces to a decidable set law: every removed `event_decl`/`proc_decl` must
spell a path the program never invokes and no library root seeds —
`removed ∩ (uses ∪ roots) = ∅`. Under `std/witness:enforce` the pass
commits the pre-image: `strip-use` lines for every key in its `used` set
(all spellings the membership test consults — canonical paths, inline-body
text scrapes, hyphenated emitted-name variants), `strip-root` for seeded
exports, `strip-rm` carrying BOTH keys `isPathUsed` probed (canonical and
the enclosing-module fallback), `strip-cargo` digests for comment-only
host-line removals, and a `strip-census`. WitnessCheck re-decides the law
on the committed sets alone — a `strip-rm` naming a still-spelled path is a
semantic forgery (`drift_strip.txt` gates it expecting rejection), roots
must appear among uses, and the census must count honestly. Cargo digests
ride packed lines — up to 64 comma-joined digests per `strip-cargo`
payload — so `675_036`'s 2345 comment-cargo removals cost ~37 lines
rather than ~2400; the multiset is the identity and order is preserved,
so both oracles re-decide exactly what the per-line spelling carried. Evidence lines buffer and print
only on a fully successful run: the caller swallows a failed pass, and a
half-ledger in an otherwise-clean corpus would read as drift rather than
failure. Every other koru transform remains at
accounting level — `strip-*` is the template for the class: commit the
decidable pre-image of the transform's own justification, let the oracle
re-run the membership law, never serialize a verdict.

**Artifact channel landed (2026-10-27) — evidence-follows-AST is now
re-derived, not trusted, for the dead-strip leg.** The 2026-10-15 leg
re-decided verdicts on the pass's *committed* sets; a pass that
under-commits `used` to license a removal still passed. The shared fix
both K2 and K3 named: `program.ast.json` is the serialized
frontend→backend channel — the artifact the backend deserializes as
`original_ast` — so an oracle can re-derive the reachability pre-image
independently instead of trusting the ledger. `verify/strip_ast/
strip_ast_check.py` (a from-scratch Python walk over the raw JSON, not the
Zig decoder) mirrors `collectUsedPaths` and `filterItems` and re-decides:
every artifact-spelled key must be committed (`UNSPELLED` — the
under-commitment class the old leg was blind to), no `strip-rm` key may be
artifact-spelled (`UNLAWFUL-RM` — the law, against the derived set rather
than the committed one), removals may not exceed a decl's declared
multiplicity (`RM-OVERCOUNT`), cargo digests must match the artifact's
host-line multiset exactly (`CARGO-MISS`), and under `--library` every pub
entry-module decl must be a committed root and vice versa
(`ROOT-MISSING`/`ROOT-STRAY`; any root in a program compile is forged).
The `STRIP_AST_CHECK` marker arms it in the regression harness under
`KORU_WITNESS=1`; `220_074` is the first live `strip-root` coverage — a
`post.sh` `koruc lib` compile whose ledger is re-decided in `--library`
mode (program compiles commit zero roots, so the root machinery only saw
synthetic corpora before). Named boundary, measured not assumed: the pass
filters the *post-transform* tree while the artifact is pre-transform, so
removals of transform-introduced decls can't be re-decided from this
channel — `690_380` shows 14 such; the oracle reports them rather than
fails. Closing that needs the filter-input decl set committed, a separate
ledger. For K3 the same artifact carries the arm premises claim evidence
commits — the channel pattern generalizes; only the strip side is wired
today.

**Claims channel leg landed (2026-10-29) — the K3 half of the same
boundary.** The claims pass commits its FM pre-image as
`[claim-term]`/`[claim-goal]`/`[claim-head]`/`[claim-edge]` lines, and
ClaimsCheck.lean re-decides the entailment *given* those rows — but
whether the rows correspond to the actual program was still the pass's
word. `verify/claims_ast/claims_ast_check.py` closes it: a faithful
Python port of the claims pipeline over the raw `program.ast.json`
(claim-site harvest from `std.spec:claim` flow items, subject
resolution, `&`-type rows, the guard parser + DNF case walk, arm meets,
fold-head entry bindings, back-edge substitutions through the binding
map, and the integer FM discharge itself — `linFeasible` included).
The oracle requires the committed ledger to equal the artifact's own
derivation line for line: site coverage both ways (`SITE-MISS`/`SITE-STRAY`),
the verdict word AND detail prose (`VERDICT`), every premise row and
substitution in order (`EVID-DIFF`/`EVID-MISS`/`EVID-STRAY`), and the
census cross-counted against both the ledger and the derived verdicts
(`CENSUS`/`CENSUS-ART`). A claim whose committed `proven` cannot be
re-derived fails — the verdict is now artifact-decided, not
pass-asserted. Same named boundary as the strip leg: `program.ast.json`
precedes `run-pre-transforms` inside `elaborate` while
`pass-claims-check` reads `mutable_ctx.ast` after it — a transform that
rewrites a claim's subject region makes the committed rows underivable
and the oracle fails loud; none is observed on the armed corpus
(12/12 live shapes re-derive: declared + inferred rank, honors
base+step, `&`-typed fields and payloads, conj/disj/mixed guards,
cond dispatch with binding rename and prior-arm negation, nested
if/cond). The `CLAIMS_AST_CHECK` marker arms it under `KORU_WITNESS=1`
on the five claims-ledger tests; `verify/claims_ast/fixtures/` carries
a minimal honest pair plus a forged-premise pair the selfcheck gates.

---

## 3. K3 — Proof-carrying obligations

### 3.1 The argument (against Bend 2's published shape)

Bend 2's public position: LAWS.bend is "AGENTS.md backed by proof," the AI writes PROOF.bend, the type
checker is "a proof checker, as in Lean and Rocq" but takes under a second, and NeoGen synthesizes —
"if it fails, an LLM is called," under the discipline of formal correctness. Three structural weaknesses:

1. Laws are hand-authored. Bend 2 itself documents that it cannot prevent errors in the
specifications — the laws are only as good as their author. Koru's obligations are grammar-derived:
mint/move/discharge edges follow from the invocation shape. There is no law-authoring step to get wrong.

2. Proofs enter via LLM drafting. At scale, LLM-drafted proofs are exactly the practice that produces
plausible-but-wrong derivations; the design's integrity then rests entirely on the checker — which is
proprietary, fast-by-claim code on an immature substrate (HVM2's own paper concedes the compiler is
"extremely immature"; Bend 1 programs do not even carry over).

3. Nothing in the chain carries a machine-checked soundness theorem. Speed of checking is claimed, not
proven; correctness of the checker is trust in a company, not a kernel.

Koru's design closes all three: grammar-derived obligations (no spec authoring), **algorithmic witness
synthesis** (no LLM in the trust chain — and none needed, because the fragment is decidable), and a
checker whose soundness is a Lean theorem. The checker is not fast because it is clever; it is fast
because the obligation calculus is a tiny decidable fragment, and it is trustworthy because its soundness
is machine-checked — the same reason CompCert's validators are trustworthy.

### 3.2 Non-negotiables (the N-list)

- **N1 — Solver ≠ checker.** No discharge on the solver's word; only the checker's verdict counts.
  Disagreement → refusal naming both. koruc's obligation solver is untrusted, however good it is. A discharge is
accepted only on the checker's verdict. Solver/checker disagreement → refusal naming both.
- **N2 — The checker is small, stable, machine-trusted.** Calculus formalized in Lean; soundness: checked
  witness ⇒ runtime obligation safety. Zig checker cross-checked batched against the Lean checker. The obligation calculus is formalized in Lean;
soundness theorem: a checked witness implies runtime obligation safety (no leak, no double-discharge, no
use-after-discharge) under the small-step semantics of flows. The in-tree Zig checker is cross-checked
batched against the Lean checker (lean_eval pattern: one #eval per batch; missing Lean oracle = FAIL).
- **N3 — Witnesses are data.** Synthesized at comptime, attached to flow records like FLOW/PROC/BRANCH
  markers; never hand-authored; removal is a refusal. Synthesized at comptime, attached to the flow record like the existing
FLOW/PROC/BRANCH source markers; never hand-authored; removing them is a refusal (load-bearing like
sha256 digests in golden fixtures).
- **N4 — Forged-witness gates are standing.** Known-bad witnesses must be rejected by both checkers. A checker that
accepts a forged witness is a red battery, not a caveat. 
- **N5 — No LLM in the trust chain.** The Lean kernel decides, nothing else does. Synthesis is algorithmic;
  where it fails, refusal is the honest output. LLMs may draft Lean lemmas about the checker; the Lean kernel decides
and nothing else does. Synthesis is algorithmic: grammar-bounded accessor sets make mint/move/discharge
edges finite and statically enumerable. Where synthesis fails (recursion-depth walls — the
liveness-interval ruling), refusal is the honest output, consistent with existing koru rulings.

### 3.3 Shape questions for Lars (the S-list)

- **S1** witness surface. - header annotation vs. sidecar vs. debug-build-only artifact.
- **S2** refusal rendering of failed witnesses. - whether refusals render the failed witness (debuggability).
- **S3** checker placement (RESOLVED, §3.5). - the checker is an additional comptime pass in the
coordinate pipeline; the Lean artifact is the calculus + conformance oracle, not the pass runtime.
- **S4** KORU code vocabulary. - for witness mismatches
- **S5** first-calculus fragment: which obligation kinds (proposal: the one-label-one-disposer kinds —
allocated!, taken-row custody, held handles — 690_007/690_015 territory).

### 3.5 The checker as a comptime pass (S3, resolved)

The verifier is an additional comptime pass in the coordinate pipeline — but precisely which part is
"Lean-proven" matters, so the roles are kept distinct.

Pipeline shape. Today the solver and the verdict-owner are blurred: auto_discharge_inserter
transforms (a solver act) and phantom_semantic_checker issues verdicts (a checking act), with the
ruling on record that "the obligation checker sees ordinary code and owns the verdict" (KORU030). N1
splits this into two named stages:

    elaborate |> analysis |> obligation-synthesis |> witness-check |> optimizer |> emission

As wired today (`koru_std/compiler.kz`), the two abstract stages are four concrete passes:

    check-phantom-args |> pass-auto-discharge |> pass-witness-check |> check-phantom-semantic

- `check-phantom-args` — pre-insertion call-site checks (`.args_only` mode).
- `pass-auto-discharge` — the "obligation-synthesis" stage: untrusted solver, rewrites, mints
  `@witness` marks onto inserted disposals (`.marks` — pass-produced, unauthorable).
- `pass-witness-check` — the "witness-check" stage: consumes prepared marks, owns the verdict,
  prints `[witness] site` lines under `std/witness:enforce`.
- `check-phantom-semantic` — post-insertion walls (`.full` mode); emits `custody-edge` witness
  lines over the real settle paths (mint|held|discharge|issued).

- `obligation-synthesis` — untrusted solver pass (today's auto-discharge family): mints witnesses, may
  rewrite, does not own verdicts.
- `witness-check` — trusted verdict pass: never rewrites, idempotent (re-run yields the identical verdict —
  the one-contract-one-verdict rule). the trusted verdict pass: Program + Witnesses → Program + verdicts | refusals.
Never rewrites; idempotent by construction (re-running yields the identical verdict — the property
that satisfies the one-contract-one-verdict rule: silent divergence between runs is a red battery,
not a quirk).

**Lean's two roles:** 
- **Role A (the theorem)** — the calculus + soundness lemma is a Lean artifact; the pass is its
Zig implementation. The obligation calculus — mint/move/discharge rules plus the soundness lemma
(checked witness ⇒ runtime obligation safety) — is a Lean artifact. This is what "proven" means. The
witness-check pass implements these rules in Zig.
- **Role B (the conformance oracle)** — batched cross-check with `lean_eval` pattern, verdicts must match. What Lean does
not do: run inside the build — `lake env lean` is an oracle budget, not a comptime budget. This is the
foundational-PCC discipline: smallest verifier over smallest axiom set, so drift is mechanically detectable. The Lean checker
evaluates the standing witness corpus; verdicts must match the pass's on every batch; mismatch = red
battery. Forged-witness gates (N4) run through both, and both must reject. **Live since the witness
tranche:** `verify/witness/WitnessCheck.lean` re-decides `stored-write-numeric`, `auto-discharge`
(incl. the `all:` completeness commitment), and `custody-edge` site lines; `scripts/witness_gate.sh`
gates golden/forged/real corpora under the `WITNESS_CHECK` test marker + `KORU_WITNESS=1`.

**What Lean does not do:** run inside the build. A lake env lean batch costs ~25s and an external
toolchain — that is an oracle budget, not a comptime budget. Comptime passes must be fast, deterministic,
and hermetic; therefore the pass is a Zig implementation of the proven calculus, and the Lean artifact
attests (a) the rules are sound and (b) the implementation conforms, gated on standing corpora. This is
the foundational-PCC discipline: the trusted core is the smallest possible verifier plus the smallest
possible axiom set — small enough that implementation drift is mechanically detectable, which is exactly
what the conformance gates detect.

**PCC accounting: (why this is the historical shape, not a novel one)**Proof-carrying code's whole
viability rested on the certifying compiler: Touchstone generated the proofs automatically — nobody
hand-wrote them; the original TCB accounting is "checker + proof-generating tools (for honest users)."
Koru's mapping: producer = untrusted solver pass, proof = synthesized witness, host checker =
`witness-check` pass, trusted core = pass + Lean calculus. The stdlib self-check option becomes:
expose witness-check also as a callable comptime tor, so the store/list take-pop-watch rules gate their
own discharge sites with the same pass — plug-in verifier over a trusted core, the open-verifier-framework
shape.

### 3.4 Estimator

Why smaller than CompCert: Memory-model and aliasing chapters have no spelling in koru; the simulation invariant is a cell-valuation
map plus binding environment, local per branch. First fragment: one obligation kind, the take/consume-or-give-back cell flow. The xdu-style equivalence cell from
K1 is the executable shadow of the eventual simulation lemma.

---

## 4. K4 — Attested CI (zk receipts)

 - **Battery-in-guest:** (RISC-V: koruc cross-builds; ccomp RISC-V port; fixtures + sha256 manifest). Receipt pins:
  - **Receipt pins:** git tree hash, koruc digest, ccomp digest, fixture manifest, gate outcomes.
  - **Tiering (declared schedule regimes, not moods):** fast native per commit, zk on releases.
  - **New certificate tier:** `attested` between `witness` and `proof`.
  - **Honesty clause:** Receipts attest process, not semantics — the pyramid stands.

**Rung 1 landed (2026-10-14) — the receipt regime, not the guest.** No
Rust/zk toolchain and no CI infrastructure exist in the tree, so the
first rung is the receipt itself rather than its proof channel:
`scripts/attest.py emit` runs the pinned battery (`witness_gate.sh`,
`semantics_gate.sh`), and writes a signed `koru-attest/1` receipt into
`receipts/` carrying the tree hash, `tree_dirty` honestly,
koruc/ccomp/lean digests, corpus, semantics-kernel and gate-script
digests, per-gate verdicts, host ABI (`uname`, `ldd`),
and `proof: null`. Signing is Ed25519; the signer is a `did:key` and
the repo pins *which* did counts in `tools/attest.pub` — a valid
signature from an unpinned key is not an attestation, it is a signature.
`attest.py verify` checks all three claims separately: signature valid
(the record is untampered), signer trusted (the pinned attester signed
it), digests match (the artifacts the receipt names are the ones
present). `verify --re-run` re-executes the recorded battery and
compares verdicts instead of trusting them — re-decide, don't trust,
applied at the top layer too; without it, recorded verdicts are
self-attestation. A tampered verdict invalidates the signature, not
the digest check — the failure names which claim broke.
**What this rung does NOT attest:** the signature is self-attestation
by the key holder — it records that the battery ran, signed by the
pinned attester, on the artifacts digested. It does not prove the run
was unmodified; that is the zk execution channel the `proof` field is
reserved for. See `koru-verification-gaps.md` for the full ledger.

---

## 5. Totality, holes, and refused surfaces

What each layer currently *covers*, what it *refuses by name*, and what is
still open — the honest inventory the "verified path" claim is scoped by.
A hole not listed here that surfaces later is a defect of this section,
not a loophole of the layers.

### 5.1 Witness corpus (K3 channel)

| Surface | Status | Boundary |
|---|---|---|
| `stored-write-numeric` | covered | per-line verdicts re-decided in Lean; `unproven`/`unresolved` are named verdicts, not skips |
| `auto-discharge` | covered | the `all:` enumeration commits the solver's universe; candidates outside it are malformed — but the enumeration itself is solver-reported (an event the solver never saw is invisible; completeness needs the declaration corpus, not the mark) |
| `custody-edge` | covered | per-edge vocabulary + corpus-level ledger replay per arrow (mint ⇒ exactly one settle; held may end contract-settled) |
| `descriptor` / `descriptor-scope` | covered | decl↔emit claim parity re-derived in Lean; census `count=` must equal descriptor lines per scope |
| `?` proto edges | **MALFORMED by design** | a `discharge` that saw no live binding record prints proto `?`; the ledger counts the edge but cannot re-check its proto — the checker losing a record is itself flagged, never normalized |
| `-> expr` compound returns | covered by refusal | `issued` mints only when the expr names the obligation (identifier or *unique* mention) AND the flow's declared `-> T<state!>` return matches (type, state); ambiguity, no carrier, wrong carrier, and unmentioned live obligations all refuse KORU030 — the checker never guesses whether an obligation rides a compound expression |
| witness format | strict | `|`/`;`/`=` separators assume type spellings never contain them; a spelling that does would fail loudly, not mis-parse |

### 5.2 Phantom / obligation checker (`phantom_semantic_checker`, KORU030-family)

| Surface | Status | Boundary |
|---|---|---|
| mint/discharge/issued/held | covered | the four ops are the complete lifecycle vocabulary the `.full` pass prints |
| auto-discharge candidate set | solver-bounded | `sole`/`preferred` insertions are forced choices over the *enumerated* set; the enumeration is what the solver saw — see the `all:` row above |
| call-shape invocations (`wrap(r)`) | different node kind | parses as `.invocation`, not `.expression` — outside the arm-exit compound audit by construction; its custody is the callee's contract edge, not a return-carrier question |

### 5.3 C lane (K1)

| Surface | Status | Boundary |
|---|---|---|
| declared-width arithmetic | pinned | wrapping ops use *declared* integer width, not storage width; 230_007 pins refusal where neither operand resolves to a declared integer width |
| `usize` | pinned as `u64` | on Zig and C lanes `usize` lowers to u64; `usize -> i64` claims are *deferred*, not refused — named gap |
| watches / interceptors / rules | **partial** | basic scalar singleton watches lower on C — per-arm `@retain` event invoked after the write settles (`690_001`/`690_010`/`690_102`/`690_385` green); interceptors, dischargers, guarded arms and rules remain named refusals — pinned per class: `690_336` rules, `690_386` lifecycle arms, `690_387`-`392` tree/char[N]/index/entity/owned/ref |
| host lines, `!`-effect arms, pump/rings/worker.spawn | refused | §1 refusal table — sequential deterministic subset only |

### 5.4 Alive2 leg (K2, landed shape)

| Surface | Status | Boundary |
|---|---|---|
| intra-procedural opt instances | covered | `alive-tv --passes=` proves each a refinement of clang -O0 IR from `output_emitted.c` |
| unmodeled libcalls | **scope:libcall** | `fputs`/`fflush`/`fprintf`/`abort`/`strlen` are outside alive2's modeled fragment — IO wrappers and panic paths are named, counted, never tallied as correct |
| `sret` / aggregate returns | **scope:untranslatable** | untranslatable into Alive IR entirely — named, counted |
| loops beyond unroll bound | **scope:unroll** | bounded by design (`--unroll=8` measured); deeper loops fail loudly, not pass silently |
| timeouts on pure-IR functions | **FAIL** | genuinely undecided is a failure; `scope:libcall-timeout` applies only when *every* call in the region targets a declared-only external (causation proven: stubbing the three libcalls makes the same transform verify) |
| koru-level transforms | **not covered** | clang's `.ll` can only see LLVM's transforms, never koru's — Use B needs the emitter to expose pre/post IR; tracked |
| negative control | pinned | forged same-signature `mul`->`add` reports `incorrect input_wmul` |

### 5.5 The boundary nobody verifies (named, not fixed)

- **Source → emitter faithfulness has no independent oracle.** ccomp verifies
  compilation *of* the emitted C; whether the emitted C is faithful to the
  koru source rests on byte-diff + tests + refusal honesty. The zig
  self-hosted backend (`backend`/`output` binaries) is likewise unverified
  substrate. "100%" needs a verified emitter or a semantics-preservation
  proof — the declared pass graph with `contract:requires`/`contract:preserves`
  invariants is the staged instrument for it, and ISAR may give it teeth —
  concretely: isar-proofs proves its `InvariantLayer` quotient *terminal* in
  a category of dialects (`Dialect` = encode/decode/eval + preservation),
  which is the N²→N collapse for emitter congruence. Without a kernel
  object, lanes pair off (Zig↔C, Zig↔LLVM, …) and per-instance checks pay
  per artifact forever; a `FlowDialect` instance (koru flow carrier +
  preservation proof, prototyped in isar-proofs, ported back if it checks
  out) derives cross-lane congruence through the quotient once per view
  instead. Per-instance refinement keeps buying coverage while that proof
  debt accrues; the factorization retires the debt class.
- **Lean-side trust:** `WitnessCheck.lean` is checked by the Lean kernel; the
  *rules* it encodes are the specification — soundness theorems (Role A)
  cover the verdict definitions, not the koru pipeline that minted the marks.
- **Witness marks are emitted under `std/witness:enforce` only** — a run
  without enforcement produces no corpus and the oracle's `lines.isEmpty`
  check fails rather than passes vacuously.
- **The full gap ledger** lives in `koru-verification-gaps.md` — the
  per-layer list of what each oracle does *not* cover, kept honest as
  layers land. The `[requires]` spelling collision was ruled on by Lars
  (2026-10-17): the family spells `contract:requires`/`contract:preserves`/
  `contract:obliges`; resolution recorded in `verify-path-handoff.md`.

---

## 6. Sequencing

- **K1** now on `ccomp`
- **K3's Lean calculus** starts in parallel (gates nothing until first fragment
lands)
- **K2** is opportunistic once K1's emitter stabilizes
- **K4** after K1 (needs a stable battery); rides the agents-store certificate regime where convenient.

**Foot-down summary:** N1–N5. Everything else is shape.

---

## 7. Academic provenance

### 6.1 Where each idea comes from

| Plan § | Idea | Pulled from | What it solves | Prior art / new synthesis |
|---|---|---|---|---|
| 0, 1 | Verified-compiler reference; semantic preservation by forward simulation | Leroy, *Formal verification of a realistic compiler* (CACM 2009); CompCert project | what makes an oracle's verdict trustworthy rather than test-suite-shaped | prior art (theirs); **NS-1**: CompCert as *emit-target behavioral oracle for a non-C language* — two realizations of one semantic space gated on stdout+rc — is new |
| 1 | Loud refusal beats silent miscompile; differential oracle epistemics | Yang, Chen, Eide, Regehr, *Finding and understanding bugs in C compilers* (PLDI 2011) — CompCert's refusals were the healthy signal under Csmith testing | why G-CC-3 (refusal tests) is a first-class gate, not an error-reporting nicety | prior art (evidence), reused |
| 1 | TCB honesty for the reference | Monniaux & Boulmé, *The Trusted Computing Base of the CompCert Verified Compiler* (ESOP 2022) | scope claims for what the oracle actually certifies (parser/typechecker unverified, external oracles) | prior art |
| 2 | Translation validation: check one compilation instead of proving a compiler | Pnueli, Siegel, Singerman, *Translation validation* (TACAS 1998) | the very idea of per-instance checking (K2, and the N1 seam) | prior art |
| 2 | Bounded SMT instance checking of LLVM IR | Lopes, Lee, Hur, Liu, Regehr, *Alive2* (PLDI 2021, Distinguished Paper) | the concrete mechanism for K2 | prior art |
| 3.5 | Certifying compiler: proofs generated automatically, nobody hand-writes them | Necula & Lee, *Proof-carrying code* (POPL 1997); *The design and implementation of a certifying compiler* (PLDI 1998) | the feasibility argument for N3/N5 — "humans won't write proofs" has a 25-year-old solution shape | prior art (pattern); **NS-3**: the seam realized as *named comptime passes* in a metacircular compiler whose passes are library tors — new |
| 3.5 | Smallest verifier + smallest axiom set; conformance gap closable | Appel, *Foundational proof-carrying code* (LICS 2001); Appel & Felty, *A semantic model of types and machine instructions for PCC* (POPL 2000) | why the Zig pass can be trusted despite being an implementation: rules small enough that drift is mechanically detectable | prior art |
| 3.5 | Plug-in verifiers over a trusted core | Chang, Chlipala, Necula, Schneck, *The Open Verifier Framework for foundational verifiers* (TLDI 2005) | the stdlib self-check: `witness-check` as a callable comptime tor | prior art (shape), new instantiation |
| 3 | Obligations as linear, erasable proof terms | Xi, *Applied Type System* (RTA 2003); ATS project | proof-carrying obligations — the K3 concept exists and has been built | prior art; **NS-2**: *grammar-derived* obligations (mint/move/discharge follow from the invocation shape) making witnesses algorithmically synthesizable is new — and is precisely where ATS's authoring burden dies |
| 3 | Grammar-level refusal (no spelling for the error) | Armstrong, *The development of Erlang* (ICFP 1997) — single assignment at grammar level | precedent that a language can refuse a whole category structurally | prior art |
| 3.1 | The counter-position (hand-authored laws, LLM-drafted proofs, unverified fast checker) | Bend 2 (bend-lang.com; bendlang/bend) — engineering position, not academic | delimits what N1–N5 foreclose | documented position; contrast, not citation-backed theory |
| 3.2, 4 | Batched spot-oracle conformance gating | isar-proofs practice (lean_eval.py: one `#eval` batch per gate; missing oracle = FAIL) | N2's enforcement mechanism | internal practice; **NS-4**: applying it to gate a *compiler pass's verdicts* is new |
| 4 | zk-attested provenance of compilation runs | *Verifiable Provenance of Software Artifacts with Zero-Knowledge Proofs* (arXiv:2602.11887, 2026); RISC Zero zkVM docs | process attestation for K4 — receipts pin toolchain digests | prior art (zk provenance); **NS-5**: the `attested` tier inside an obligation/certificate regime is new |
| 0, 2 | Engineering facts: Zig self-hosted x86_64 backend default in Debug (0.15.x); LLVM leg via `-fllvm` | Zig 0.15.1 release notes; ziglang.org devlog | K2's coverage honesty clause | engineering citations |

**The new-synthesis list, stated once:** 
 - NS-1 CompCert as emit-target oracle for a non-C language;
 - NS-2 grammar-derived (hence synthesizable) obligations; 
 - NS-3 solver≠checker as named comptime pipeline stages in a metacircular compiler; 
 - NS-4 batched spot-oracle gating of a compiler pass; 
 - NS-5 zk receipts as a certificate tier. Each is a composition of prior art that is individually well-established — the honest
claim is the composition, not any component.

### 6.2 BibTeX

```bibtex
@article{leroy2009compcert,
  author  = {Leroy, Xavier},
  title   = {Formal verification of a realistic compiler},
  journal = {Communications of the ACM},
  volume  = {52}, number = {7}, pages = {107--115}, year = {2009},
  doi     = {10.1145/1538788.1538814}
}
@inproceedings{rideau2010validating,
  author    = {Rideau, Silvain and Leroy, Xavier},
  title     = {Validating register allocation and spilling},
  booktitle = {Compiler Construction (CC 2010)}, series = {LNCS}, volume = {6011},
  year = {2010}, note = {the untrusted-oracle / verified-validator seam}
}
@inproceedings{pnueli1998translation,
  author    = {Pnueli, Amir and Siegel, Michael and Singerman, Eli},
  title     = {Translation validation},
  booktitle = {Tools and Algorithms for the Construction and Analysis of Systems (TACAS'98)},
  year = {1998}
}
@inproceedings{necula1997pcc,
  author    = {Necula, George C. and Lee, Peter},
  title     = {Proof-carrying code},
  booktitle = {Proceedings of POPL'97}, year = {1997}
}
@inproceedings{necula1998certifying,
  author    = {Necula, George C. and Lee, Peter},
  title     = {The design and implementation of a certifying compiler},
  booktitle = {Proceedings of PLDI'98}, year = {1998}
}
@inproceedings{appel2001fpcc,
  author    = {Appel, Andrew W.},
  title     = {Foundational proof-carrying code},
  booktitle = {Proceedings of LICS'01}, year = {2001}
}
@inproceedings{appel2000semantic,
  author    = {Appel, Andrew W. and Felty, Amy P.},
  title     = {A semantic model of types and machine instructions for proof-carrying code},
  booktitle = {Proceedings of POPL'00}, year = {2000}
}
@inproceedings{chang2005ovf,
  author    = {Chang, Bor-Yuh Evan and Chlipala, Adam and Necula, George C. and Schneck, Robert R.},
  title     = {The Open Verifier framework for foundational verifiers},
  booktitle = {ACM SIGPLAN Workshop on Types in Language Design and Implementation (TLDI'05)},
  year = {2005}
}
@inproceedings{lopes2021alive2,
  author    = {Lopes, Nuno P. and Lee, Juneyoung and Hur, Chung-Kil and Liu, Zhengyang and Regehr, John},
  title     = {Alive2: Bounded translation validation for {LLVM}},
  booktitle = {Proceedings of PLDI 2021}, year = {2021},
  note      = {Distinguished Paper Award; doi:10.1145/3453483.3454030}
}
@inproceedings{yang2011finding,
  author    = {Yang, Xueyi and Chen, Yang and Eide, Eric and Regehr, John},
  title     = {Finding and understanding bugs in {C} compilers},
  booktitle = {Proceedings of PLDI 2011}, year = {2011}
}
@inproceedings{monniaux2022tcb,
  author    = {Monniaux, David and Boulm{\'e}, Sylvain},
  title     = {The Trusted Computing Base of the {CompCert} Verified Compiler},
  booktitle = {ESOP 2022}, series = {LNCS}, volume = {13240}, year = {2022},
  doi       = {10.1007/978-3-030-99336-8_8}
}
@inproceedings{xi2003ats,
  author    = {Xi, Hongwei},
  title     = {Applied Type System (extended abstract)},
  booktitle = {Rewriting Techniques and Applications (RTA 2003)}, year = {2003}
}
@inproceedings{armstrong1997erlang,
  author    = {Armstrong, Joe},
  title     = {The development of {Erlang}},
  booktitle = {Proceedings of ICFP 1997}, year = {1997},
  note      = {single assignment at grammar level}
}
@misc{compcertmanual,
  author = {{Inria -- CompCert project}},
  title  = {The {CompCert} {C} verified compiler: documentation and user's manual},
  note   = {compcert.org/man; supported {C} subset: ISO C99 minus VLA, setjmp/longjmp, long double}
}
@misc{zig0151,
  author = {{Zig Software Foundation}},
  title  = {Zig 0.15.1 Release Notes},
  note   = {self-hosted x86_64 backend default in Debug mode; ziglang.org/download/0.15.1/release-notes.html}
}
@misc{bend2,
  author = {{HigherOrderCO}},
  title  = {Bend 2: laws, proofs, and a fast proof checker},
  note   = {bend-lang.com; bendlang/bend on GitHub; engineering position — the K3 counter-position}
}
@misc{zkprovenance2026,
  author = {[TODO: complete authors from arXiv page]},
  title  = {Verifiable Provenance of Software Artifacts with Zero-Knowledge Proofs},
  note   = {arXiv:2602.11887, 2026 — compiler runs inside a zkVM, provenance receipts}
}
@misc{risczero,
  author = {{RISC Zero}},
  title  = {RISC Zero zkVM: cryptographic security model},
  note   = {dev.risczero.com — permissionless receipt verification}
}
```
