# Koru verification gaps — what the battery does not cover

`koru-verification-path.md` describes what each layer checks. This doc
is the mirror: what each layer does **not** check, stated explicitly so
a "verified" claim has a visible boundary. Every gap is named; none is
silent. When a gap closes, delete its row — the doc is a ledger, not a
narrative.

Measured at `ccomp` `e94bfeeb9` (2026-10-14).

## K1 — CompCert on emitted C

- **The C lane only.** The zig emitter is the product lane and is
  unverified substrate — same elaborated flow graph, different
  translation arm. Source→emitter faithfulness rests on byte-diff,
  refusal honesty, and the test suite; no independent oracle reads it.
- **Upstream-of-oracle bugs.** ccomp validates compilation of the C it
  receives. If the C emitter mis-renders a construct, ccomp still
  compiles the wrong C correctly — the failure is above the oracle's
  view.
- **Refusal-defined fragment.** C-lane coverage is measured by named
  refusal classes (`C_REFUSES` pins, `c-lane-census.md`), not by a
  proved fragment boundary. A construct the census never classified is
  unaccounted, not unverifiable.

## K2 Use A — Alive2 congruence

- Intra-procedural optimization instances only. Whole-program pre/post
  IR congruence is not proven; the IR exposure itself is partial.

## K2 Use B — transform-app accounting

- **Digest honesty, not semantic congruence.** The `rm=`/`add=` lines
  prove the write-back touched the declared item multiset — not that
  the rewrite preserves meaning. Partially closed for `dead-strip`
  (2026-10-15): its semantic claim IS a set law (`removed ∩ uses ∪ roots
  = ∅`), and the pass now commits the `used` set plus both probed keys
  per removal as `strip-*` lines, so the oracle re-decides lawful
  removal — not meaning-preservation, but a real semantic property of
  the rewrite. Evidence-follows-AST partially closed (2026-10-27):
  `verify/strip_ast/strip_ast_check.py` re-derives the use set, decl
  multiset, pub roots, and cargo digests from `program.ast.json` — the
  serialized channel the backend deserializes — and re-decides the
  committed ledger (under-committed uses, unlawful/over-count removals,
  cargo fidelity, root coverage) rather than trusting the pass's `used`
  set. Still open there: the kept-side law is implied by the
  removal partition only while kept ⊆ uses∪retained holds; and the
  post-transform side of the walk is unchecked — decls transforms
  introduce or drop between serialization and strip are uncheckable
  from this channel (14 on `690_380`), as is the claims evidence
  following the same artifact (channel pattern landed, claims wiring
  not yet).
- **Only dead-strip re-decides.** Every other transform — tap
  write-backs, template procs, desugar, codegen lowering — remains at
  digest-accounting level; the `strip-*` pattern applies only where the
  transform's justification is itself a decidable relation.
- **`contract:preserves` bounds kinds, not content.** A transform may rewrite
  every item of a kind it declared preserved; the bound only refuses
  *collateral adds/removes* of held kinds.
- **`contract:obliges` closes the first two decidable obligation claims, not
  semantics.** `kind-stable` and `matched-only` are shape-level:
  a transform may rewrite its matched items into anything and no
  obligation yet says the rewrite preserves meaning. The vocabulary
  is closed — extending it is a declaration surface, not an escape
  hatch; the semantic claim needs the §6a Lean kernel to have a
  domain at all.
- **Obligation granularity is the canonical digest.** An item a
  transform *clones but does not change* still registers as touched
  if the clone drifts the digest (observed on `module_decl`) — the
  obligation correctly refuses. Honest write-backs pass untouched
  items through by value; clone-drift fidelity in `ast_functional`
  is a real latent issue the obligation made visible, not a loophole.
- **Canonical digest equivalence is pinned, not proved.** The zig
  emitter and the Lean oracle agree on digests because the corpora
  match — a shared digest drift would pass both.

## Declared pass graph (rungs 1-3)

- **Opt-in coverage.** An unannotated pass carries no edges. Nothing
  counts what fraction of the pipeline is declared; the graph
  constrains only what declarers declared.
- **Order, not function.** The check validates declared edges against
  observed chains — it never judges whether a pass does what its name
  claims.
- **Corpus completeness rests on the emitter.** The Lean oracle
  re-decides the printed corpus; the wire between `validate()`'s
  summary and the printed lines is compiler code. The census makes a
  dropped arc inconsistent by count, but a backend that corrupts arcs
  and counts *consistently* is outside what the corpus can refute —
  that boundary is code review and the suite, not proof.
- **Two hand-written enumerations of one rule set.** The zig validator
  and the Lean checker mirror each other by hand; forged/drift corpora
  bound divergence but do not prove equivalence.
- **`collect` coverage tracks the AST.** Validation recurses into
  `module_decl` since rung 2 — a *new* `ast.Item` container kind would
  silently hide decls again, the way the seeded `compiler.kz` edges sat
  unvalidated for a full rung. No wall warns when the item vocabulary
  grows.

## K3 — Lean witness oracle

- Role A theorems cover the verdict definitions; the encoded *rules*
  are the specification. Lean re-decides the committed corpus — it
  cannot see what the backend never printed.
- The witness channel is `enforce`-gated by design: non-enforce runs
  produce no corpus, and the battery attests committed runs only.

## K3-adjacent — flow semantics kernel (`verify/semantics/`)

- **`FlowCheck.lean` now consumes real claims.** `comptime_eval.zig`
  emits one `[flow-eval]` line per interpreter-consumed comptime flow
  under `std/witness:enforce` — entry call with evaluated args, graph
  (subflow/bare/thunk defs), a fuel bound, the result or bare `refuse`,
  and every native thunk call as an asserted oracle leaf. The
  `FLOW_EVAL_CHECK` marker + `KORU_WITNESS=1` route a test's
  `backend.err` through `semantics_gate.sh`; `310_141` is the pinning
  test. Forged variants of real claims MISMATCH under re-decision.
- **Refusal classes are diagnostic-only.** The wire verdict is bare
  `refuse`; the kernel's `none` collapses the walker's named classes
  (unbound var, div-zero, uncallable head, …), so a claim verifies
  *that* a walk refused, never *why*. Divergence on refusal reason is
  undetected until the wire grows a `(refuse-class …)` field the
  checker can compare.
- **`[flow-eval-skip]` markers are not consumed.** A walk whose values
  can't serialize (unquotable string, fragment, later-rung node) prints
  a named skip marker — presence is auditable, but FlowCheck ignores
  the line; a corpus of only skips fails as "no claim lines", which is
  the correct loud shape, while a *mix* of claims and skips has no
  accounting that every walk produced one or the other.
- **Fuel is an exact certificate, but the accounting itself is
  unproved.** Emitted fuel is the count of kernel `run` calls along the
  walk's derivation spine — one Zig increment per mapped kernel step
  (`.invoke`/`.flow`/`.loop`/dispatch/armTry/dispatch-rest/`.armWalk`),
  no padding. Re-decision empirically confirms sufficiency per claim:
  an undercount exhausts kernel fuel into a loud MISMATCH on honest
  output, never a silent pass. What is not proved is the mapping itself
  — the Zig increment sites match the kernel's cost model only because
  the corpus pins them (measured: `route`=7, a six-iteration guarded
  loop=35). ISAR's `sufficient_fuel_correct` proves the bound inside
  the logic; ours is measured exact but trusted.
- **Identical walks are corpus-level drift.** Two byte-identical claims
  (same call walked twice) trip the duplicate rule — the checker cannot
  distinguish "same fact committed twice" from emitter double-counting,
  so `FLOW_EVAL_CHECK` tests must not repeat a walk verbatim.
- **The decoder's fidelity is unproved.** `checkLine_{sound,complete,
  reject,none}` pin the executable to `WireOk` — "the line decodes to a
  claim the kernel reproduces" — but nothing proves `sxDecl`/`sxArm`/
  `sxVal` decode what the emitter *meant*. A decoder bug misreads both
  sides of the comparison consistently: the forged corpus catches gross
  shape errors, never semantic misreads (an arm's guard dropped on the
  floor would still "re-decide" the misdecoded graph). This is the
  encode/decode-preservation lemma the `FlowDialect` rung owns.
  Adjacent: `WireOk` inherits `==`'s IEEE corner — `+0.0 == -0.0` —
  because `Float` has no lawful `DecidableEq`; wire floats decode from
  rationals so `NaN` is inexpressible, but a kernel-computed `-0.0` can
  be claimed as `+0.0` and match. Bit-exactness, if ever wanted, is a
  wire-level decision, not a patch.
- **No shared code with koruc.** Independence is the point — divergence
  between the kernel and the compiler is a bug in one of them. With the
  emit leg landed that divergence is now *detectable* per run, but only
  on programs the marked tests actually exercise: coverage, not proof.
- **Kernel scope covers the walker's comptime expression surface:**
  int/float/bool/str/array/cell values, full binary/unary ops (with
  truncating `/`,`%` and floored `@mod` distinguished), lazy
  `and`/`or`/conditionals/`@as`, field access, array indexing, tagged/
  bare/void dispatch, `#label`+`@jump` loops, named args, thunk oracle
  leaves. Refused: effects, stores, `|*`, taps, transforms, modules,
  name resolution, recursion, function calls, fragments, destructured
  arms, `Source` args, non-enclosing labels, and i64 overflow (the
  kernel uses unbounded `Int`).
- **A.5 landed: claims carry `(residue ARM*)`, and `C_REFINE_CHECK`
  closes the graph→C seam per instance.** Every claim now commits the
  flow's unspliced residue arms (absent = `[]`, old corpora still
  decode); `renderObservable` in the kernel re-dispatches the result
  into those arms — `spliceResidue`'s own rule — and renders the
  `std.io:print[.ln]` node into expected stdout. FlowCheck's `--cref`
  mode then reads `output_emitted.c` (main's ordered `koru_flow_N`
  calls, per-fn `__koru_stdout_write[_i64]` statement lists, C escapes
  decoded) and requires equality. A forged C file MISMATCHes; an
  outside-subset residue or C shape FAILs the marked test rather than
  silently passing. `310_142` pins it: verdict re-decision and
  observable refinement on the same compile. The declared subset
  refuses: non-print residue nodes, `eprint` (stderr isn't the
  checked channel), floats (`%g` rendering isn't lawful here),
  nested arm continuations, literal-expr format holes, and C bodies
  that aren't flat write sequences.

## K4 — attested receipts

- **Rung 1 is self-attestation, not execution proof — but it is
  re-decidable.** The signed receipt records that the pinned battery
  ran on digested artifacts, signed by the attester the repo pins in
  `tools/attest.pub`. `verify --re-run` re-executes the recorded
  battery and compares verdicts, so the verifier confirms outcomes
  rather than trusting them; the signature then attests only
  provenance ("the pinned attester claims these inputs were tested").
  Without `--re-run` the verifier trusts the recorded verdicts — the
  residual is self-attestation for non-re-running readers. The
  `proof` field is reserved for the zk execution channel, which
  removes the attester's honesty from the trust base entirely
  (RISC-V guest — no toolchain yet).
- **The battery is two gates.** `attest.py`'s pinned list runs
  `witness_gate.sh` and `semantics_gate.sh`; the regression suite,
  ccomp oracle legs, and alive2 legs are outside the attested battery —
  widening the pinned list is the honest growth path, not a claim the
  suite is attested.
- **The attester key lives on one host.** `~/.agents/keys/` on the
  signing machine; a receipt from any other key verifies cryptographically
  but fails the trusted-signer pin — which is the intended refusal, and
  also means attestations cannot yet be issued from anywhere else.

## Cross-cutting

- Board snapshots and `test-results/` are evidence, not proof.
- Environment splits: node/dotnet absent on the WSL test image (js/cs
  legs unexercised there); ccomp resolves via `KORU_CC_ORACLE`; the
  backend binary cache salts on `ldd` output — a coarse ABI proxy.
- Toolchain PATH is part of the trusted environment: a toolchain dir
  that shadows `cc`/`clang`/`ld.lld` changes what `zig build` links
  (measured 2026-10-14: elan's bundled glibc-2.34 CRT produced
  un-runnable binaries on a 2.31 host). Oracle paths go through
  `KORU_*` env vars, never PATH mutation.
