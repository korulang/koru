/-
Witness checker.

Role A (calculus + soundness) and Role B (conformance oracle) for the
witness kinds pass-witness-check consumes — `stored-write-numeric` (marks
the `stored` transform mints onto lowered write invocations,
koru_std/store.cols.kz, storedWriteCheck), `auto-discharge` (marks the
inserter mints onto lowered disposals, src/auto_discharge_inserter.zig),
and `custody-edge` (obligation lifecycle edges the .full phantom checker
emits, src/phantom_semantic_checker.zig).
The passes are the untrusted solvers; this file re-decides every witness
from its own definitions and rules on agreement (N1: solver ≠ checker).

Independence: the float literal rule here is a direct search for an exact
`m·2^e` witness over the format's whole exponent range — a different
derivation from the solver's odd-part/bit-length formula, so drift in
either one surfaces as a mismatch rather than agreeing by construction.

Run (Role B):  lean --run WitnessCheck.lean <corpus>            — every site line must MATCH
               lean --run WitnessCheck.lean --forged <corpus>   — every line must be REJECTED (N4)
A corpus is backend output; only `[witness] site …` lines are read. A
corpus with zero site lines FAILs: an empty batch is not a passed batch.
-/

namespace Koru.WitnessCheck

/-! ## The type table — mirrors `writeNumInfoOf` -/

inductive NumTy where
  | i32 | i64 | f32 | f64
deriving DecidableEq, Repr

inductive Cls where
  | si | fl
deriving DecidableEq, Repr

def NumTy.cls : NumTy → Cls
  | .i32 => .si | .i64 => .si | .f32 => .fl | .f64 => .fl

def NumTy.rank : NumTy → Nat
  | .i32 => 1 | .i64 => 2 | .f32 => 1 | .f64 => 2

def NumTy.ofName : String → Option NumTy
  | "i32" => some .i32 | "i64" => some .i64
  | "f32" => some .f32 | "f64" => some .f64
  | _ => none

/-! ## Value semantics

Integers of width `w`: `-2^(w-1) ≤ v ≤ 2^(w-1) - 1`, as a sign + magnitude.
Floats: the finite values are exactly `±m·2^e` with `m < 2^p` and
`emin ≤ e ≤ emax` — subnormals and normals in one set. -/

structure FFmt where
  p    : Nat
  emin : Int
  emax : Int

def NumTy.width : NumTy → Nat
  | .i32 => 32 | .i64 => 64 | _ => 0

def NumTy.fmt : NumTy → FFmt
  | .f32 => ⟨24, -149, 104⟩
  | .f64 => ⟨53, -1074, 971⟩
  | _    => ⟨0, 0, 0⟩

/-- Sign-magnitude integer `(neg, q)` is a value of the `w`-bit signed type. -/
def InInt (w : Nat) (neg : Bool) (q : Nat) : Prop :=
  if neg then q ≤ 2 ^ (w - 1) else q + 1 ≤ 2 ^ (w - 1)

/-- `(m, e)` is a representation of a finite value of format `f`. -/
def InFloat (f : FFmt) (m : Nat) (e : Int) : Prop :=
  m < 2 ^ f.p ∧ f.emin ≤ e ∧ e ≤ f.emax

/-! ## Verdicts -/

inductive Verdict where
  | lossless | deferred | rounds | nonNumeric | refused
deriving DecidableEq, Repr

def Verdict.ofTag : String → Option Verdict
  | "lossless" => some .lossless | "deferred" => some .deferred
  | "rounds" => some .rounds | "non-numeric" => some .nonNumeric
  | "refused" => some .refused
  | _ => none

def Verdict.tag : Verdict → String
  | .lossless => "lossless" | .deferred => "deferred" | .rounds => "rounds"
  | .nonNumeric => "non-numeric" | .refused => "refused"

/-! ## Typed writes: a proven source type into a column type -/

def decideTyped (dest src : NumTy) : Verdict :=
  if src.cls ≠ dest.cls ∨ src.rank > dest.rank then .refused else .lossless

/-! ## Literal writes

A decimal literal `±n / 10^k` (digits[.digits], optional leading `-`). -/

structure Lit where
  neg : Bool
  n   : Nat
  k   : Nat

def digitsVal (cs : List Char) : Nat :=
  cs.foldl (fun a c => a * 10 + (c.toNat - '0'.toNat)) 0

def parseLit (cs : List Char) : Option Lit :=
  let (neg, body) := match cs with
    | '-' :: rest => (true, rest)
    | _ => (false, cs)
  let (ip, rest) := body.span (· != '.')
  if ip.isEmpty || !ip.all Char.isDigit then none
  else match rest with
    | [] => some ⟨neg, digitsVal ip, 0⟩
    | _ :: fp =>
      if fp.isEmpty || !fp.all Char.isDigit then none
      else some ⟨neg, digitsVal (ip ++ fp), fp.length⟩

def intExact (w : Nat) (l : Lit) : Bool :=
  l.n % 10 ^ l.k == 0 &&
    (if l.neg then decide (l.n / 10 ^ l.k ≤ 2 ^ (w - 1))
     else decide (l.n / 10 ^ l.k + 1 ≤ 2 ^ (w - 1)))

/-- Does `n / 10^k = m · 2^e` hold for some integer `m < 2^p`, at this `e`? -/
def witnessAt (f : FFmt) (l : Lit) (e : Int) : Bool :=
  if e ≤ 0 then
    -- n · 2^(-e) = m · 10^k
    l.n * 2 ^ e.natAbs % 10 ^ l.k == 0 && decide (l.n * 2 ^ e.natAbs / 10 ^ l.k < 2 ^ f.p)
  else
    -- n = m · 10^k · 2^e
    l.n % (10 ^ l.k * 2 ^ e.natAbs) == 0 && decide (l.n / (10 ^ l.k * 2 ^ e.natAbs) < 2 ^ f.p)

def floatExact (f : FFmt) (l : Lit) : Bool :=
  (List.range ((f.emax - f.emin).toNat + 1)).any fun i => witnessAt f l (f.emin + i)

def litExact (dest : NumTy) (l : Lit) : Bool :=
  match dest.cls with
  | .si => intExact dest.width l
  | .fl => floatExact dest.fmt l

/-! ## The checker: one witness triple → the verdict it must carry

`none` = malformed witness (an unknown source token, an unparseable
literal) — never a verdict. -/

def prefixLiteral : List Char := "literal:".toList

def decideWitness (dest src : String) : Option Verdict :=
  match NumTy.ofName dest with
  | none => if dest == "unresolved" then some .nonNumeric else none
  | some td =>
    if src == "unproven" then some .deferred
    else if src.toList.take prefixLiteral.length == prefixLiteral then
      (parseLit (src.toList.drop prefixLiteral.length)).map fun l =>
        if litExact td l then .lossless else .rounds
    else (NumTy.ofName src).map (decideTyped td)

/-! ## Role A — soundness

A `lossless` verdict is a promise that every value the source can hold
lands in the column unchanged. These theorems discharge that promise
against the value semantics above. -/

/-- Typed widening: the source's value set embeds in the column's. -/
theorem typed_lossless_sound (dest src : NumTy) (h : decideTyped dest src = .lossless) :
    (src.cls = .si → ∀ neg q, InInt src.width neg q → InInt dest.width neg q) ∧
    (src.cls = .fl → ∀ m e, InFloat src.fmt m e → InFloat dest.fmt m e) := by
  cases dest <;> cases src <;> simp [decideTyped, NumTy.cls, NumTy.rank] at h <;>
    refine ⟨fun hc => ?_, fun hc => ?_⟩ <;> simp [NumTy.cls] at hc <;>
    first
    | (intro neg q hq; cases neg <;> simp [InInt, NumTy.width] at hq ⊢ <;> omega)
    | (intro m e hmf; simp [InFloat, NumTy.fmt] at hmf ⊢; omega)

/-- A `lossless` literal into an integer column is an in-range integer. -/
theorem int_literal_sound (w : Nat) (l : Lit) (h : intExact w l = true) :
    l.n % 10 ^ l.k = 0 ∧ InInt w l.neg (l.n / 10 ^ l.k) := by
  simp only [intExact, Bool.and_eq_true, beq_iff_eq] at h
  refine ⟨h.1, ?_⟩
  unfold InInt
  cases hn : l.neg <;> simp_all

/-- A `lossless` literal into a float column has an exact representation
`(m, e)` in the format: the decimal equals `m · 2^e` exactly. The format
must have a non-empty exponent range — both real formats do. -/
theorem float_literal_sound (f : FFmt) (l : Lit) (hf : f.emin ≤ f.emax) (h : floatExact f l = true) :
    ∃ m e, InFloat f m e ∧
      (e ≤ 0 → l.n * 2 ^ e.natAbs = m * 10 ^ l.k) ∧
      (0 < e → l.n = m * (10 ^ l.k * 2 ^ e.natAbs)) := by
  simp only [floatExact, List.any_eq_true, List.mem_range] at h
  obtain ⟨i, hi, hw⟩ := h
  have hlo : f.emin ≤ f.emin + (i : Int) := by omega
  have hhi : f.emin + (i : Int) ≤ f.emax := by omega
  unfold witnessAt at hw
  split at hw
  · rename_i he
    simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at hw
    refine ⟨l.n * 2 ^ (f.emin + i).natAbs / 10 ^ l.k, f.emin + i, ⟨hw.2, hlo, hhi⟩, ?_, ?_⟩
    · intro _
      exact (Nat.div_mul_cancel (Nat.dvd_of_mod_eq_zero hw.1)).symm
    · intro h0; omega
  · rename_i he
    simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at hw
    refine ⟨l.n / (10 ^ l.k * 2 ^ (f.emin + i).natAbs), f.emin + i, ⟨hw.2, hlo, hhi⟩, ?_, ?_⟩
    · intro h0; omega
    · intro _
      exact (Nat.div_mul_cancel (Nat.dvd_of_mod_eq_zero hw.1)).symm

/-! ## Role B — the batch oracle -/

def splitOnArrow : List Char → Option (List Char × List Char)
  | '<' :: '-' :: rest => some ([], rest)
  | c :: rest => (splitOnArrow rest).map fun (a, b) => (c :: a, b)
  | [] => none

structure SiteLine where
  kind    : String
  site    : String
  arrow   : String
  verdict : String
  extra   : String      -- optional fifth payload token ("" when absent)

/-- `[witness] site <kind> <site> <arrow> <verdict> [extra]` — the arrow and
verdict are interpreted per kind; `extra` is per-kind optional payload
(auto-discharge carries `all:` — the enumeration commitment). -/
def parseSiteLine (line : String) : Option SiteLine :=
  match (line.splitOn " ").filter (· ≠ "") with
  | ["[witness]", "site", kind, site, arrow, verdict] => some ⟨kind, site, arrow, verdict, ""⟩
  | ["[witness]", "site", kind, site, arrow, verdict, extra] => some ⟨kind, site, arrow, verdict, extra⟩
  | _ => none

inductive Ruling where
  | match_ | mismatch (want : String) | malformed
deriving Repr, DecidableEq

/-! ## Kind `auto-discharge` — the unattended-discharge policy

The inserter (src/auto_discharge_inserter.zig, `pickUnattendedDischarge`)
splices a disposer at a scope exit only when the choice is forced: exactly
one candidate (`sole`), or several of which exactly one carries `[!]`
(`preferred`). The mark records the obligation's state, the chosen
disposer, the rule, and the full candidate list with `[!]` flags:

    <state>-><chosen>   <rule>:<cand>[!],<cand>[!],...

The checker re-runs the policy over the recorded candidates. The optional
fifth token is the completeness commitment — `all:` followed by EVERY decl
the solver enumerated for this (state, base) pair, `(x)`-suffixed on the
enumerated-but-ineligible (output-carrying, re-issuing, unfillable input):

    <state>-><chosen>   <rule>:<cand>[!],...   all:<name>[!][(x)],...

The checkable contract: the recorded candidate list must BE exactly the
non-`(x)` members of the enumeration — the solver commits to its universe,
so a candidate outside `all` or an eligible `all` member dropped from the
candidates is internally inconsistent data, not a judgment call. What
remains solver-reported is the enumeration itself: an event the solver
never saw is invisible to this fragment — that completeness needs the
declaration corpus, not the mark. -/

structure Cand where
  name : String
  dflt : Bool
deriving DecidableEq, Repr

def parseCand (s : String) : Option Cand :=
  if s.isEmpty then none
  else if s.endsWith "!" then
    let n := String.ofList (s.toList.dropLast)
    if n.isEmpty then none else some ⟨n, true⟩
  else some ⟨s, false⟩

def parseCands (s : String) : Option (List Cand) :=
  (s.splitOn ",").mapM parseCand

/-- The policy. `none` = not unattended-dischargeable: nothing may be inserted. -/
def pick (cs : List Cand) : Option (String × String) :=
  match cs with
  | [c] => some ("sole", c.name)
  | _ => match cs.filter (·.dflt) with
    | [c] => some ("preferred", c.name)
    | _ => none

/-- Role A for the policy: whatever `pick` returns was a candidate, and the
choice was forced — the only candidate, or the only `[!]` one. -/
theorem pick_sound (cs : List Cand) (r n : String) (h : pick cs = some (r, n)) :
    ∃ c ∈ cs, c.name = n ∧
      ((r = "sole" ∧ cs = [c]) ∨ (r = "preferred" ∧ c.dflt = true ∧ cs.filter (·.dflt) = [c])) := by
  unfold pick at h
  split at h
  · rename_i c
    simp only [Option.some.injEq, Prod.mk.injEq] at h
    exact ⟨c, by simp, h.2, Or.inl ⟨h.1.symm, rfl⟩⟩
  · split at h
    · rename_i c hf
      simp only [Option.some.injEq, Prod.mk.injEq] at h
      have hmem : c ∈ cs.filter (·.dflt) := by rw [hf]; simp
      have hc := List.mem_filter.mp hmem
      exact ⟨c, hc.1, h.2, Or.inr ⟨h.1.symm, by simpa using hc.2, hf⟩⟩
    · exact absurd h (by simp)

def splitOnRight : List Char → Option (List Char × List Char)
  | '-' :: '>' :: rest => some ([], rest)
  | c :: rest => (splitOnRight rest).map fun (a, b) => (c :: a, b)
  | [] => none

/-- A member of the `all:` enumeration — `(x)` suffix marks a consumer the
solver enumerated but could not auto-insert (output-carrying, re-issuing,
or unfillable inputs). Returns (cand, excluded). -/
def parseAllEntry (s : String) : Option (Cand × Bool) :=
  let excluded := s.endsWith "(x)"
  let base := if excluded then String.ofList (s.toList.take (s.toList.length - 3)) else s
  (parseCand base).map (·, excluded)

def ruleDischarge (s : SiteLine) : Ruling :=
  if !s.extra.startsWith "all:" then .malformed else
  match splitOnRight s.arrow.toList, s.verdict.splitOn ":" with
  | some (st, chosen), claimed :: rest =>
    if st.isEmpty then .malformed else
    match (String.ofList (s.extra.toList.drop 4)).splitOn "," |>.mapM parseAllEntry,
          parseCands (":".intercalate rest) with
    | some entries, some cs =>
      let names := entries.map (·.1.name)
      if names.length != names.eraseDups.length then .malformed else
      let eligible := entries.filterMap fun (c, ex) => if ex then none else some c
      -- completeness: the candidate list is exactly the eligible slice —
      -- names AND `!` flags must agree (Cand equality carries `dflt`)
      if !(cs.length == eligible.length && cs.all fun c => eligible.contains c) then .malformed else
      match pick cs with
      | none => .mismatch "not-dischargeable"
      | some (r, n) =>
        if r == claimed && n == String.ofList chosen then .match_
        else .mismatch s!"{r}->{n}"
    | _, _ => .malformed
  | _, _ => .malformed

def ruleNumeric (s : SiteLine) : Ruling :=
  match splitOnArrow s.arrow.toList with
  | none => .malformed
  | some (d, src) =>
    match decideWitness (String.ofList d) (String.ofList src), Verdict.ofTag s.verdict with
    | some v, some claimed => if v == claimed then .match_ else .mismatch v.tag
    | _, _ => .malformed

/-! ## Kind `custody-edge` — obligation mint/settle edges

The phantom semantic checker (src/phantom_semantic_checker.zig) walks the
post-insertion flow and prints one edge per custody event it observes:

    [witness] site custody-edge <name> <name><-<T<state!>> <op>

`<name>` is the binding; the arrow repeats it and carries the obligation's
proto (`base_type<phantom_state>`). The ops:

  - `mint`      — a `state!` binding entered the cleanup audit
                  (BindingContext.setWithType, requires_cleanup).
  - `held`      — an obligation arrived through a declared consume input
                  (`<!state>`): the debt is real but settled by the event's
                  contract, so it never enters the leak audit.
  - `borrow`    — an owned obligation was exercised through a declared
                  borrow input (`<state>`, no `!`) at a call site
                  (`validateArgument`): custody stays with the caller —
                  an exercise edge, the static twin of the runtime's
                  `use` event. The edge names the arg binding and carries
                  the binding's own `<...!>` proto like every other op.
  - `discharge` — a consume call or field-suffix settled the obligation
                  (BindingContext.markDisposed).
  - `issued`    — the obligation exited live through a declared `[!]`
                  output; custody transferred to the caller.

Per line the checker can only re-decide well-formedness: the site name must
be the arrow's name, the proto must carry a `!`-state, and the op must be in
vocabulary. The real verdict is corpus-level — `custodyBalance` replays the
edge list per arrow and requires

    mint      ⇒ exactly one settle (discharge or issued) before re-bind/end
    held      ⇒ at most one discharge (settlement may be contract-invisible)
    borrow    ⇒ an outstanding mint or held must precede it — custody is
                unchanged (exercise ≠ transfer); without it the ledger
                could not tell "borrowed live" from "never touched"
    discharge/issued ⇒ an outstanding mint or held must precede them

— the witness-level twin of the checker's own leak walls. -/

def protoHasBang (proto : String) : Bool :=
  -- the proto's trailing `<state>` group must end in `!`: `...<...!>`
  proto.endsWith "!>" || proto.endsWith "!"

def ruleCustody (s : SiteLine) : Ruling :=
  match splitOnArrow s.arrow.toList with
  | none => .malformed
  | some (nm, proto) =>
    let name := String.ofList nm
    if name.isEmpty || s.site != name then .malformed
    else match s.verdict with
      | "mint" | "held" | "borrow" | "discharge" | "issued" =>
        if !protoHasBang (String.ofList proto) then .malformed else .match_
      | _ => .malformed

/-- Ledger state for one arrow's edge sequence. -/
inductive CustodySt where
  | clean    -- no outstanding obligation
  | minted   -- a mint awaits its settle
  | heldSt   -- a held obligation may discharge or end contract-settled
deriving DecidableEq, Repr

/-- One transition; `none` = the edge is illegal here. `borrow` needs an
outstanding hold and moves nothing — exercise, not transfer. -/
def custodyStep : CustodySt → String → Option CustodySt
  | .clean,    "mint"      => some .minted
  | .clean,    "held"      => some .heldSt
  | .minted,   "borrow"    => some .minted
  | .heldSt,   "borrow"    => some .heldSt
  | .minted,   "discharge" => some .clean
  | .minted,   "issued"    => some .clean
  | .heldSt,   "discharge" => some .clean
  | .heldSt,   "issued"    => some .clean
  | _,         _           => none

/-- An arrow's ledger closes iff every mint settled. A live `held` may end
open — a host impl's contract settles it invisibly. -/
def custodyClosed : CustodySt → Bool
  | .clean | .heldSt => true
  | .minted => false

/-- Replay one arrow's ops; `none` = an illegal edge occurred. -/
def custodyRun : List String → CustodySt → Option CustodySt
  | [], st => some st
  | op :: rest, st => match custodyStep st op with
    | some st' => custodyRun rest st'
    | none => none

/-! #### Borrow-edge pins — the op's fixture classes, decided at compile time -/

-- a borrow on an outstanding mint is legal and moves nothing
example : custodyStep .minted "borrow" = some .minted := rfl
-- a borrow on an outstanding held is legal and moves nothing
example : custodyStep .heldSt "borrow" = some .heldSt := rfl
-- a forged borrow with no outstanding obligation is refused
example : custodyStep .clean "borrow" = none := rfl
-- repeated borrows do not discharge: the ledger still owes a settle
example : custodyRun ["mint", "borrow", "borrow"] CustodySt.clean = some .minted := rfl
example : custodyClosed .minted = false := rfl
-- golden spines close: mint → exercise → settle, held → exercise → settle
example : custodyRun ["mint", "borrow", "discharge"] CustodySt.clean = some .clean := rfl
example : custodyRun ["held", "borrow", "discharge"] CustodySt.clean = some .clean := rfl
-- relay: a held obligation exits live through a declared `!` return —
-- custody transfers onward, it does not discharge here
example : custodyRun ["held", "issued"] CustodySt.clean = some .clean := rfl
example : custodyRun ["held", "borrow", "issued"] CustodySt.clean = some .clean := rfl
-- but a bare clean ledger still cannot issue what it never held
example : custodyRun ["issued"] CustodySt.clean = none := rfl
-- a borrow edge carrying a bare `<state>` proto is malformed — the edge
-- names the caller's obligation, so it carries `!` like every other op
example : ruleCustody ⟨"custody-edge", "h", "h<-*Handle<input:owned>", "borrow", ""⟩ = .malformed := by native_decide
example : ruleCustody ⟨"custody-edge", "h", "h<-*Handle<input:owned!>", "borrow", ""⟩ = .match_ := by native_decide

/-- Corpus-level balance: group custody-edge lines by arrow, replay each
group's ops in file order, every ledger must close. Returns the failing
arrows (empty list = balanced). Lines that failed per-line parse are
skipped — the per-line pass already flags them. -/
def custodyBalance (sites : List SiteLine) : List String :=
  let edges := sites.filter (·.kind == "custody-edge")
  let arrows := (edges.map (·.arrow)).eraseDups
  arrows.filter fun a =>
    let ops := (edges.filter (·.arrow == a)).map (·.verdict)
    match custodyRun ops CustodySt.clean with
    | some st => !custodyClosed st
    | none => true

/-! ## Kind `descriptor` — registry descriptor ↔ event-decl fidelity

The `register|zig` transform (koru_std/runtime.kz) builds each emitted
`scope_events` row from an `EventDecl` and prints, per event,

    [witness] site descriptor <scope> <mod>:<event> <verdict> cost=<n>;decl=<atoms>;emit=<atoms>

`decl` is the declared contract serialized straight off the `EventDecl`;
`emit` is the row the transform actually generated. The obligation atoms:

  - `dis:<mod>:<state>@<arg>`           — a declared consume input `<!state>`
  - `cr:<mod>:<state>@<field>#<branch>` — a declared `<state!>` branch payload
  - `cr:<mod>:<state>@__type_ref`       — a declared `<state!>` bare return

plus shape atoms (`in:`/`br:`) mirrored verbatim on both sides. The
checker re-derives the claim set from the `decl` spellings — the same
token rule `parsePhantom` uses: a leading `!` marks a discharge, a
trailing `!` a create, and `mod:name` splits the obligation's module
from its name (falling back to the event's module) — then rules on
agreement with the `emit` claims. `discharge-refused` licenses an empty
emitted `dis` only when the declared side really carried discharges: a
declaration-only event's unsatisfiable promise is named, not silently
dropped. A `descriptor-scope` census line closes the set corpus-wide:
one per scope, `count=` equal to its descriptor lines — a resolved row
that produced no line unbalances the count. -/

/-- The first `<…>` group of a type spelling — the raw phantom token. -/
def phantomToken (t : String) : Option String :=
  match t.splitOn "<" with
  | _ :: tok :: _ =>
    match tok.splitOn ">" with
    | nm :: _ :: _ => if nm.isEmpty then none else some nm
    | _ => none
  | _ => none

/-- Mirror of `parsePhantom` (koru_std/runtime.registry.kz): leading `!`
discharges, trailing `!` creates, `mod:name` overrides the event module.
Both marks may co-occur. Returns (discharge claim, create claim) as
`mod:name` bodies. -/
def claimOf (evMod tok : String) : Option String × Option String :=
  let (dis, s1) := if tok.startsWith "!" then (true, (tok.drop 1).toString) else (false, tok)
  let (cr, s2) := if s1.endsWith "!" then (true, String.ofList s1.toList.dropLast) else (false, s1)
  if s2.isEmpty || (!dis && !cr) then (none, none)
  else
    let (m, n) := match s2.splitOn ":" with
      | a :: b :: rest => (a, ":".intercalate (b :: rest))
      | _ => (evMod, s2)
    (if dis then some s!"{m}:{n}" else none, if cr then some s!"{m}:{n}" else none)

structure DescSide where
  ins : List String   -- `in:` atoms, verbatim
  brs : List String   -- `br:` atoms, verbatim
  crs : List String   -- `cr:` claim atoms
  dis : List String   -- `dis:` claim atoms

/-- Re-derive the obligation claims a `decl` atom list carries — the
independent reading the emitted row must agree with. `none` on any atom
outside the declared vocabulary. -/
def declSide (evMod : String) : List String → DescSide → Option DescSide
  | [], acc => some acc
  | a :: rest, acc =>
    if a.startsWith "brf:" then
      match (a.drop 4).toString.splitOn "=" with
      | [lhs, ty] =>
        match lhs.splitOn ":" with
        | [br, f] =>
          let (d, c) := match phantomToken ty with
            | some tok => claimOf evMod tok
            | none => (none, none)
          let acc := match c with
            | some cl => { acc with crs := acc.crs ++ [s!"cr:{cl}@{f}#{br}"] }
            | none => acc
          let acc := match d with
            | some cl => { acc with dis := acc.dis ++ [s!"dis:{cl}@{f}#{br}"] }
            | none => acc
          declSide evMod rest acc
        | _ => none
      | _ => none
    else if a.startsWith "in:" then
      match (a.drop 3).toString.splitOn "=" with
      | [n, ty] =>
        let acc := { acc with ins := acc.ins ++ [a] }
        match phantomToken ty with
        | none => declSide evMod rest acc
        | some tok =>
          let (d, c) := claimOf evMod tok
          let acc := match d with
            | some cl => { acc with dis := acc.dis ++ [s!"dis:{cl}@{n}"] }
            | none => acc
          let acc := match c with
            | some cl => { acc with crs := acc.crs ++ [s!"cr:{cl}@{n}"] }
            | none => acc
          declSide evMod rest acc
      | _ => none
    else if a.startsWith "br:" then
      declSide evMod rest { acc with brs := acc.brs ++ [a] }
    else if a.startsWith "ret:" then
      -- Registry normalization: a bare `-> T` return IS the single branch
      -- `| ok (__type_ref: T)` (runtime.contract `wireDeclOutcome` renders
      -- the singleton ok branch as `-> T`). The emit side prints resolved
      -- branches, so the derived side must carry the synthesized `br:ok`.
      let acc := { acc with brs := acc.brs ++ ["br:ok"] }
      match phantomToken (a.drop 4).toString with
      | none => declSide evMod rest acc
      | some tok =>
        let (d, c) := claimOf evMod tok
        let acc := match c with
          | some cl => { acc with crs := acc.crs ++ [s!"cr:{cl}@__type_ref"] }
          | none => acc
        let acc := match d with
          | some cl => { acc with dis := acc.dis ++ [s!"dis:{cl}@__type_ref"] }
          | none => acc
        declSide evMod rest acc
    else none

/-- Partition an `emit` atom list; `none` on any atom outside the emitted
vocabulary — a claim shape the checker cannot read is flagged, not
skipped. -/
def emitSide : List String → DescSide → Option DescSide
  | [], acc => some acc
  | a :: rest, acc =>
    if a.startsWith "cr:" then emitSide rest { acc with crs := acc.crs ++ [a] }
    else if a.startsWith "dis:" then emitSide rest { acc with dis := acc.dis ++ [a] }
    else if a.startsWith "in:" then emitSide rest { acc with ins := acc.ins ++ [a] }
    else if a.startsWith "br:" then emitSide rest { acc with brs := acc.brs ++ [a] }
    else none

def parseDescExtra (extra : String) : Option (List String × List String) :=
  match extra.splitOn ";" with
  | [cTok, dTok, eTok] =>
    if !cTok.startsWith "cost=" || !dTok.startsWith "decl=" || !eTok.startsWith "emit=" then none
    else match (cTok.drop 5).toString.toNat? with
      | none => none
      | some _ =>
        some ((dTok.drop 5).toString.splitOn "|" |>.filter (· ≠ ""),
              (eTok.drop 5).toString.splitOn "|" |>.filter (· ≠ ""))
  | _ => none

def setEq (a b : List String) : Bool := a.all (· ∈ b) && b.all (· ∈ a)

def ruleDescriptor (s : SiteLine) : Ruling :=
  let evMod := match s.arrow.splitOn ":" with
    | m :: _ => m
    | [] => ""
  if evMod.isEmpty then .malformed else
  match parseDescExtra s.extra with
  | none => .malformed
  | some (declAtoms, emitAtoms) =>
    match declSide evMod declAtoms ⟨[], [], [], []⟩, emitSide emitAtoms ⟨[], [], [], []⟩ with
    | some d, some e =>
      let shape := setEq d.ins e.ins && setEq d.brs e.brs && setEq d.crs e.crs
      if s.verdict == "registered" then
        if shape && setEq d.dis e.dis then .match_
        else .mismatch s!"{d.ins ++ d.brs ++ d.crs ++ d.dis} vs {e.ins ++ e.brs ++ e.crs ++ e.dis}"
      else if s.verdict == "discharge-refused" then
        if shape && e.dis.isEmpty && !d.dis.isEmpty then .match_
        else .mismatch s!"refused {d.dis} vs {e.dis}"
      else .malformed
    | _, _ => .malformed

def ruleDescriptorScope (s : SiteLine) : Ruling :=
  if s.site != s.arrow || s.verdict != "events" then .malformed
  else match s.extra.splitOn "=" with
    | ["count", n] => match n.toNat? with
      | some _ => .match_
      | none => .malformed
    | _ => .malformed

/-- Corpus-level completeness: every scope carrying descriptor lines must
carry exactly one `descriptor-scope` census whose `count=` equals the
number of its descriptor lines — a resolved row that produced no line
unbalances the count; a scope with no census line fails too. -/
def descriptorScopeBalance (sites : List SiteLine) : List String :=
  let descs := sites.filter (·.kind == "descriptor")
  let cens := sites.filter (·.kind == "descriptor-scope")
  let scopes := (descs.map (·.site) ++ cens.map (·.site)).eraseDups
  scopes.filter fun sc =>
    let n := (descs.filter (·.site == sc)).length
    match cens.filter (·.site == sc) with
    | [c] =>
      (match c.extra.splitOn "=" with
       | ["count", k] => k.toNat? != some n
       | _ => true)
    | _ => true

/-! ## Kind `transform-app` — whole-program transform accounting (K2 Use B)

`whole_program` is the one SiteResult splice where a handler may rewrite
top-level items outside its site (koru_std/taps.kz); the comptime-only-site
flow removal is the only other transform-driven top-level removal. The
runner (src/transform_pass_runner.zig `emitTransformAppLine`) commits, per
application, the site's canonical-AST digest and the multiset diff of
top-level item digests:

    <transform> <site-flow>   wp   site=<d>;sitepath=<p>;preserves=..;rm=<d,...>;rmk=..;add=<d,...>;addk=..;inv+=<p*n,...>;inv-=<p*n,...>;obliges=..
    <transform> <site-flow>   gc   site=<d>;rm=<d>;add=

The checkable contract is accounting honesty plus, when the transform
declares it, the blast-radius bound: `contract:preserves` atoms are the declared
invariant kinds (`!kind` = preserve-all-except; a bare/`!` mix is a
malformed contract), `rmk`/`addk` carry the kinds positionally aligned
with `rm`/`add`, and the site item itself is always licensed — it is the
point of application, not collateral. Every other changed item must be
a kind the transform did not preserve. `gc` lines keep the plain
`site=;rm=;add=` shape — the singleton site removal needs no bound.

`wp` lines additionally commit the runner-MEASURED invocation-path
multiset delta: `sitepath` is the consumed call's canonical spelling,
`inv+=`/`inv-=` are `path*count` lists of what the write-back gained and
lost below top-level — measured by the runner over both trees, never
reported by the handler, so a transform cannot self-certify its own
delta. `consume-only` obligations are re-decided against `inv-`. -/

def isHexDigest (d : String) : Bool :=
  d.length == 16 && d.all fun c => c ∈ "0123456789abcdef".toList

def digestList (raw : String) : Option (List String) :=
  if raw.isEmpty then some []
  else
    let parts := raw.splitOn ","
    if parts.all isHexDigest then some parts else none

/-- The Item union tag vocabulary — mirrored from src/ast.zig, the same
closed list the frontend validates `contract:preserves` atoms against. -/
def itemKinds : List String :=
  ["module_decl", "event_decl", "proc_decl", "flow", "event_tap",
   "label_decl", "immediate_impl", "import_decl", "host_line",
   "host_type_decl", "parse_error", "native_loop", "fused_event",
   "inlined_event", "inline_code", "facet_decl"]

def kindList (raw : String) : Option (List String) :=
  if raw.isEmpty then some []
  else
    let parts := raw.splitOn ","
    if parts.all (· ∈ itemKinds) then some parts else none

/-- Preserves atoms: bare = "preserve exactly these", `!` = "preserve all
except these". Mixed atoms are malformed; an atom naming no kind is too. -/
def preservesAtoms (raw : String) : Option (List String) :=
  if raw.isEmpty then some []
  else
    let parts := raw.splitOn ","
    let bodies := parts.map fun a => if a.startsWith "!" then (a.drop 1).toString else a
    let hasExcept := parts.any (·.startsWith "!")
    let hasBare := parts.any fun a => !a.startsWith "!"
    if hasExcept && hasBare then none
    else if bodies.all (· ∈ itemKinds) then some parts else none

/-- Is `kind` inside the declared invariant set? Mirrors the runner's
`kindIsPreserved` — the oracle resolves `!` against its own vocabulary. -/
def preservedKind (atoms : List String) (kind : String) : Bool :=
  if atoms.any (·.startsWith "!")
  then !(atoms.any fun a => (a.drop 1).toString == kind)
  else atoms.contains kind

def fieldOf (toks : List String) (pfx : String) : Option String :=
  (toks.find? (·.startsWith pfx)).map fun t => (t.drop pfx.length).toString

/-- The obligation predicate vocabulary — mirrored from
`src/pass_graph.zig oblige_names`. A `transform-oblige` line's verdict
position names which predicate the evidence decides. -/
def obligeNames : List String := ["kind-stable", "matched-only", "consume-only"]

/-- Oblige atoms: comma-separated names, each in the vocabulary. -/
def obligeAtoms (raw : String) : Option (List String) :=
  if raw.isEmpty then some []
  else
    let parts := raw.splitOn ","
    if parts.all (· ∈ obligeNames) then some parts else none

/-- A `path*count` comma list — the invocation-path multiset delta the
runner commits on `wp` lines (`inv+=`/`inv-=`). Each part is a canonical
path spelling, `*`, and a multiplicity. -/
def invPathList (raw : String) : Option (List (String × Nat)) :=
  if raw.isEmpty then some []
  else
    raw.splitOn "," |>.mapM fun p =>
      match p.splitOn "*" with
      | [path, n] =>
        match n.toNat? with
        | some k => if path.isEmpty || path.contains ' ' then none else some (path, k)
        | none => none
      | _ => none

structure AppExtra where
  siteD : String
  pres : List String
  rm : List String
  rmk : List String
  add : List String
  addk : List String
  obs : List String
  sitepath : Option String
  invAdd : Option (List (String × Nat))
  invRm : Option (List (String × Nat))

def parseAppExtra (extra : String) : Option AppExtra :=
  let toks := extra.splitOn ";"
  match fieldOf toks "site=", fieldOf toks "rm=", fieldOf toks "add=" with
  | some siteTok, some rmTok, some addTok =>
    match digestList rmTok, digestList addTok with
    | some rm, some add =>
      let pres := (fieldOf toks "preserves=").getD ""
      let rmk := (fieldOf toks "rmk=").map kindList |>.getD (some [])
      let addk := (fieldOf toks "addk=").map kindList |>.getD (some [])
      let obs := (fieldOf toks "obliges=").getD ""
      let invAdd := (fieldOf toks "inv+=").bind invPathList
      let invRm := (fieldOf toks "inv-=").bind invPathList
      let sitepath := fieldOf toks "sitepath="
      let invPresent := invAdd.isSome || invRm.isSome || sitepath.isSome
      -- All-or-none: the runner writes the three fields together on wp
      -- lines and never on gc; a partial set is an evidence forgery.
      let invOk :=
        if invPresent then invAdd.isSome && invRm.isSome && sitepath.isSome
        else true
      match preservesAtoms pres, rmk, addk, obligeAtoms obs, invOk with
      | some p, some rk, some ak, some ob, true =>
        if invPresent then some ⟨siteTok, p, rm, rk, add, ak, ob, sitepath, invAdd, invRm⟩
        else some ⟨siteTok, p, rm, rk, add, ak, ob, none, none, none⟩
      | _, _, _, _, _ => none
    | _, _ => none
  | _, _, _ => none

def ruleTransformApp (s : SiteLine) : Ruling :=
  if s.verdict != "wp" && s.verdict != "gc" then .malformed
  else match parseAppExtra s.extra with
  | none => .malformed
  | some e =>
    if !isHexDigest e.siteD then .malformed
    else if s.verdict == "wp" && (e.invAdd.isNone || e.invRm.isNone) then .malformed
    else if s.verdict == "gc" && (e.invAdd.isSome || e.invRm.isSome) then .malformed
    else if s.verdict == "wp" && !(e.rmk.length == e.rm.length && e.addk.length == e.add.length) then
      .malformed
    else if s.verdict == "wp" && !e.rm.contains e.siteD then
      .mismatch s!"site {e.siteD} absent from rm {e.rm}"
    else if s.verdict == "gc" && !(e.rm == [e.siteD] && e.add.isEmpty) then
      .mismatch s!"gc {e.siteD} vs rm {e.rm} add {e.add}"
    else if s.verdict == "wp" &&
            (((e.rm.zip e.rmk).any fun (d, k) => d != e.siteD && preservedKind e.pres k) ||
             (e.addk.any (preservedKind e.pres))) then
      .mismatch s!"blast radius exceeds declared bound {e.pres}"
    else .match_

def ruleTransformAppCensus (s : SiteLine) : Ruling :=
  if s.site != "transform" || s.arrow != "transform" then .malformed
  else match s.verdict.splitOn "=", (fieldOf (s.extra.splitOn ";") "obliges=").bind (·.toNat?) with
    | ["count", n], some _ => match n.toNat? with
      | some _ => .match_
      | none => .malformed
    | _, _ => .malformed

/-- Corpus-level completeness for transform-app: at most one census line,
and when applications were emitted its count must equal them — the same
for the oblige lines it also counts. A dropped or forged line of either
kind unbalances its count. -/
def transformAppBalance (sites : List SiteLine) : Bool :=
  let apps := sites.filter (·.kind == "transform-app")
  let obl := sites.filter (·.kind == "transform-oblige")
  let cens := sites.filter (·.kind == "transform-app-census")
  match apps, obl, cens with
  | [], [], [] => true
  | _, _, [c] =>
    (match c.verdict.splitOn "=", (fieldOf (c.extra.splitOn ";") "obliges=").bind (·.toNat?) with
     | ["count", k], some m => k.toNat? == some apps.length && m == obl.length
     | _, _ => false)
  | _, _, _ => false

/-! ## Kind `transform-oblige` — declared obligations, decided

`contract:obliges("pred",...)` on a `[transform]` decl claims predicates about the
write-back's touches — `contract:preserves` bounds which kinds may move; an
oblige decides what must be TRUE of the moves. The runner refuses a
violated obligation (KORU182) BEFORE emitting, so an honest corpus only
ever carries `ok` verdicts — a line whose evidence does not support its
`ok` is a forgery, re-derived here from the committed sets:

    <transform> <site-flow> kind-stable  ok
    <transform> <site-flow> matched-only ok;justified=<d,...>

kind-stable carries NO evidence of its own — every field it needs is
already committed on the sibling transform-app line the corpus check
pairs it to (site digest, rmk, addk); emitting them twice from the same
accounting would duplicate surface without covering a new failure mode.
matched-only commits `justified=` — the digest set of collateral
removals that contained a matching invocation — which the app line does
not carry and the oracle cannot re-derive without the AST.

The per-line rule validates shape only; the corpus-level check does the
re-decision against the paired app's commits: kind-stable requires the
app's rmk minus ONE occurrence of the site item's kind (licensed point
of application) to equal addk as a multiset; matched-only requires
justified to equal exactly the app's rm minus the site — every removed
non-site item contained an invocation the transform fires on, and a
superset claim is a lie too; consume-only requires every path in the
app's inv-= multiset to equal its committed sitepath — the write-back
removed only the call it consumed (additions are free — a transform's
job is inserting calls; an `inv-` naming another path is a silent
deletion the `ok` cannot hide). Every obligation the app declared must be
followed by exactly one oblige line before any other line kind. -/

/-- Multiset equality on lists of strings: remove each element of `a`
from `b` one occurrence at a time; equal iff everything cancels. -/
def strMultisetEq (a b : List String) : Bool :=
  a.length == b.length &&
  (a.foldl (init := (b, true)) fun (rest, ok) x =>
    if !ok then (rest, false)
    else if x ∈ rest then (rest.erase x, true)
    else (rest, false)).snd

def ruleTransformOblige (s : SiteLine) : Ruling :=
  if !(s.verdict ∈ obligeNames) then .malformed
  else
    match s.extra.splitOn ";" with
    | ["ok"] =>
      if s.verdict == "kind-stable" || s.verdict == "consume-only" then .match_ else .malformed
    | ["ok", just] =>
      if s.verdict == "matched-only" && just.startsWith "justified=" &&
         (digestList (just.drop 10).toString).isSome then .match_ else .malformed
    | _ => .malformed

/-- One pending wp application awaiting its oblige lines: the app's
committed fields plus which declared obligations are still owed. -/
structure PendingApp where
  name : String
  site : String
  rm : List String
  rmk : List String
  addk : List String
  sitepath : Option String
  invrm : Option (List (String × Nat))
  owed : List String

/-- Corpus-level pairing: a `transform-oblige` line belongs to the
transform-app immediately preceding it — same transform name, an
obligation that app declared via `obliges=`, and a verdict the app's
own commits must support (the oblige commits the CLAIM; the oracle
re-decides it against the application's evidence, so a forged `ok`
fails the re-decision, not the parse). Every obligation the app
declared must be followed by exactly one oblige line before any other
line kind arrives. -/
def transformObligeCheck (sites : List SiteLine) : List String :=
  let step := fun (pend : Option PendingApp) (bad : List String) (s : SiteLine) =>
    if s.kind == "transform-app" then
      let bad' := match pend with
        | some p => if p.owed.isEmpty then bad else bad ++ [s!"app {p.name} owed {p.owed} but {p.owed.length} oblige line(s) never arrived"]
        | none => bad
      if s.verdict != "wp" then (none, bad')
      else match parseAppExtra s.extra with
        | some e =>
          (some ⟨s.site, e.siteD, e.rm, e.rmk, e.addk, e.sitepath, e.invRm, e.obs⟩, bad')
        | none => (none, bad')  -- malformed app ruled on per-line
    else if s.kind == "transform-oblige" then
      match pend with
      | none => (none, bad ++ ["transform-oblige with no preceding transform-app"])
      | some p =>
        let toks := s.extra.splitOn ";"
        if s.site != p.name then (some p, bad ++ [s!"oblige {s.site} does not name app {p.name}"])
        else if !(s.verdict ∈ p.owed) then (some p, bad ++ [s!"oblige {s.verdict} not declared (or already discharged) by app {p.name}"])
        else
          -- Re-decide the obligation against the app's own commits.
          let holds :=
            if s.verdict == "kind-stable" then
              match (p.rm.zip p.rmk).find? (·.1 == p.site) with
              | some (_, siteKind) => strMultisetEq (p.rmk.erase siteKind) p.addk
              | none => false
            else if s.verdict == "consume-only" then
              match p.sitepath, p.invrm with
              | some sp, some ir => ir.all (·.1 == sp)
              | _, _ => false
            else
              match (fieldOf toks "justified=").bind digestList with
              | some j =>
                let collateral := p.rm.erase p.site
                collateral.all (· ∈ j) && j.all (· ∈ collateral)
              | none => false
          if holds
          then (some { p with owed := p.owed.erase s.verdict }, bad)
          else (some p, bad ++ [s!"oblige {s.verdict} does not hold against app {p.name}'s commits"])
    else
      let bad' := match pend with
        | some p => if p.owed.isEmpty then bad else bad ++ [s!"app {p.name} owed {p.owed} — an unrelated line interrupted the oblige block"]
        | none => bad
      (none, bad')
  let (pend, bad) := sites.foldl (fun acc s => step acc.1 acc.2 s) ((none : Option PendingApp), ([] : List String))
  match pend with
  | some p => if p.owed.isEmpty then bad else bad ++ [s!"app {p.name} owed {p.owed} at corpus end"]
  | none => bad

/-! ## Kind `strip-*` — dead-strip reachability re-decision (K2 Use B)

`pass-dead-strip` (src/dead_strip.zig) removes every `event_decl`/`proc_decl`
the program never spells and every comment-only `host_line`. Its semantic
claim reduces to a decidable set law, so under `std/witness:enforce` the
pass commits the pre-image rather than the verdict:

    strip-use   <path>  collect marked     — a key in the pass's `used` set
    strip-root  <path>  seed    rooted     — a seeded library export
    strip-rm    <key>   <alt>   removed    — a removed decl, both spellings tested
    strip-cargo <h,…>   text    cargo      — comment-cargo digests (fnv1a-64),
                                             packed up to 64 per line
    strip-census dead-strip totals uses=<u>;roots=<r>;removed=<n>;cargo=<c>

The oracle re-decides the lawful-removal law the pass itself enforces:
`isPathUsed` probes `used` with the canonical spelling AND the
enclosing-module fallback, so a removal is lawful iff NEITHER committed key
is in the committed `used` set. Roots are seeded INTO `used`, so every
`strip-root` must also appear as a `strip-use`. The inverse law (a kept decl
was reachable or retained) is NOT re-decided — keep-ness is the default, and
committing every kept key plus its `@retain` marks is a different leg.

Honest boundary, same as the claims lane: the oracle re-decides
verdict-follows-evidence. That the committed `used` set faithfully mirrors
the program's invocations (evidence-follows-AST) is still the pass's word —
the wire is the trusted channel. -/

/-- Path spellings on the wire: dotted segments, `module:` qualifiers,
hyphenated emitted-name variants, identifier characters. Nothing else —
a space, quote, or template char is never a path. -/
def stripPathOk (p : String) : Bool :=
  !p.isEmpty && p.toList.all fun c =>
    c.isAlphanum || c == '.' || c == '_' || c == ':' || c == '-'

def ruleStripUse (s : SiteLine) : Ruling :=
  if s.arrow == "collect" && s.verdict == "marked" &&
     stripPathOk s.site && s.extra.isEmpty
  then .match_ else .malformed

def ruleStripRoot (s : SiteLine) : Ruling :=
  if s.arrow == "seed" && s.verdict == "rooted" &&
     stripPathOk s.site && s.extra.isEmpty
  then .match_ else .malformed

def ruleStripRm (s : SiteLine) : Ruling :=
  if s.verdict == "removed" && stripPathOk s.site &&
     (s.arrow == "-" || stripPathOk s.arrow) && s.extra.isEmpty
  then .match_ else .malformed

def ruleStripCargo (s : SiteLine) : Ruling :=
  if s.arrow == "text" && s.verdict == "cargo" &&
     (s.site.splitOn ",").all isHexDigest && s.extra.isEmpty
  then .match_ else .malformed

def ruleStripCensus (s : SiteLine) : Ruling :=
  if s.site != "dead-strip" || s.arrow != "totals" || !s.extra.isEmpty
  then .malformed
  else
    let toks := s.verdict.splitOn ";"
    match fieldOf toks "uses=", fieldOf toks "roots=",
          fieldOf toks "removed=", fieldOf toks "cargo=" with
    | some u, some r, some n, some g =>
      if u.toNat?.isSome && r.toNat?.isSome && n.toNat?.isSome && g.toNat?.isSome
      then .match_ else .malformed
    | _, _, _, _ => .malformed

/-- Corpus-level strip re-decision. Violations are reported, not rulings:
a well-formed `strip-rm` naming a path the committed `used` set still spells
is a semantic forgery the per-line rules cannot see — the same class
`tampered.txt` carries on the claims lane.

`used`/`root` keys are committed once each (set membership), so a repeated
one is drift. Removed keys may legitimately repeat — welded modules carry
same-named decl objects whose canonical spellings coincide — so `strip-rm`
keys are counted for the census, never deduplicated. -/
def stripCheck (sites : List SiteLine) : List String :=
  let uses := (sites.filter (·.kind == "strip-use")).map (·.site)
  let roots := (sites.filter (·.kind == "strip-root")).map (·.site)
  let rms := sites.filter (·.kind == "strip-rm")
  let cargo := sites.filter (·.kind == "strip-cargo")
  -- `strip-cargo` payloads are packed: comma-joined digests per line.
  -- The census counts DIGESTS, not lines — sum the payload lengths.
  let cargoCount := cargo.foldl (fun acc c => acc + (c.site.splitOn ",").length) 0
  let cens := sites.filter (·.kind == "strip-census")
  let live := uses ++ roots
  let unlawful := rms.filter fun r =>
    live.contains r.site || (r.arrow != "-" && live.contains r.arrow)
  let stray := roots.filter (!uses.contains ·)
  let dupKeys := fun (ks : List String) =>
    (ks.eraseDups.filter fun k => ks.count k > 1).map fun k => s!"{k} committed twice"
  let censusBad :=
    if uses.isEmpty && roots.isEmpty && rms.isEmpty && cargo.isEmpty && cens.isEmpty
    then []
    else match cens with
      | [c] =>
        let toks := c.verdict.splitOn ";"
        match fieldOf toks "uses=", fieldOf toks "roots=",
              fieldOf toks "removed=", fieldOf toks "cargo=" with
        | some u, some r, some n, some g =>
          if u.toNat? == some uses.length && r.toNat? == some roots.length &&
             n.toNat? == some rms.length && g.toNat? == some cargoCount
          then [] else ["census mis-counts committed lines"]
        | _, _, _, _ => ["census fields unparsable"]
      | _ => ["census missing or duplicated"]
  (unlawful.map fun r => s!"removed {r.site} ({r.arrow}) still spelled in used/roots")
    ++ (stray.map fun r => s!"root {r} absent from committed uses")
    ++ dupKeys uses ++ dupKeys roots
    ++ censusBad

example : stripCheck [
    ⟨"strip-use","ev.tick","collect","marked",""⟩,
    ⟨"strip-use","app:ev.bump","collect","marked",""⟩,
    ⟨"strip-root","app:ev.bump","seed","rooted",""⟩,
    ⟨"strip-rm","dead.fn","-","removed",""⟩,
    ⟨"strip-census","dead-strip","totals","uses=2;roots=1;removed=1;cargo=0",""⟩] = [] := by native_decide
example : (stripCheck [
    ⟨"strip-use","ev.tick","collect","marked",""⟩,
    ⟨"strip-rm","ev.tick","-","removed",""⟩,
    ⟨"strip-census","dead-strip","totals","uses=1;roots=0;removed=1;cargo=0",""⟩]).length > 0 := by native_decide
example : (stripCheck [
    ⟨"strip-use","a.b","collect","marked",""⟩,
    ⟨"strip-rm","c","mod:c","removed",""⟩,
    ⟨"strip-use","mod:c","collect","marked",""⟩,
    ⟨"strip-census","dead-strip","totals","uses=2;roots=0;removed=1;cargo=0",""⟩]).length > 0 := by native_decide
example : (stripCheck [
    ⟨"strip-use","a.b","collect","marked",""⟩,
    ⟨"strip-root","lib:exported","seed","rooted",""⟩,
    ⟨"strip-census","dead-strip","totals","uses=1;roots=1;removed=0;cargo=0",""⟩]).length > 0 := by native_decide
example : (stripCheck [
    ⟨"strip-use","a.b","collect","marked",""⟩,
    ⟨"strip-census","dead-strip","totals","uses=2;roots=0;removed=0;cargo=0",""⟩]).length > 0 := by native_decide

/-! ## Kind `pass-graph-*` — the declared pass graph as committed artifacts

The frontend validator (src/pass_graph.zig) checks declared ordering
edges against the chains it observed; under enforce the backend commits
what it checked — edges, observed root-chain orders, transform stage
rows — so the oracle re-decides the same rules rather than trusting the
check ran. Kinds:

    pass-graph-edge    <consumer> requires <req>   — pipeline requires edge
    pass-graph-order   <chain> runs <step,...>     — observed root order
    pass-graph-tedge   <consumer> requires <req>   — intra-transform edge
    pass-graph-tstage  <name> at <stage>           — transform stage row
    pass-graph-census  graph counts edges=N orders=M,tedges=K,tstages=L

The corpus rules mirror pass_graph.validate: wherever a consumer runs in
a root order, every requirement must run strictly earlier (non-root
chains are never emitted — the absent-tolerance is the frontend's, not
the oracle's); a transform edge is satisfiable only when the producer's
stage is strictly earlier (pre < main < post). -/

def rulePassGraphEdge (s : SiteLine) : Ruling :=
  if s.arrow != "requires" || s.verdict.isEmpty || s.verdict.contains ',' then .malformed
  else .match_

def rulePassGraphOrder (s : SiteLine) : Ruling :=
  if s.arrow != "runs" || s.verdict.isEmpty then .malformed else .match_

def rulePassGraphTstage (s : SiteLine) : Ruling :=
  if s.arrow != "at" ||
     !(s.verdict == "pre" || s.verdict == "main" || s.verdict == "post")
  then .malformed else .match_

def rulePassGraphCensus (s : SiteLine) : Ruling :=
  if s.site != "graph" || s.arrow != "counts" then .malformed
  else match s.verdict.splitOn "=" with
    | ["edges", n] =>
      match n.toNat? with
      | none => .malformed
      | some _ =>
        let fields := s.extra.splitOn ","
        if fields.length == 3 &&
           fields.all (fun f => match f.splitOn "=" with
             | [k, _] => k == "orders" || k == "tedges" || k == "tstages"
             | _ => false)
        then .match_ else .malformed
    | _ => .malformed

/-- A step or req spelling `qual:name` or bare `name` — the last segment
is the identity; a qualifier refines it. Mirrors the frontend's
matchStep spelling rules (`/` normalizes to `.`). -/
def pgSplit (spelling : String) : String × String :=
  match spelling.splitOn ":" with
  | [q, n] => (q, n)
  | _ => ("", (spelling.splitOn ":").getLastD "")

def pgStepMatchesReq (req : String) (step : String) : Bool :=
  let (rq, rl) := pgSplit req
  let (sq, sl) := pgSplit step
  rl == sl && (rq.isEmpty || rq == sq)

/-- Last position where `req` matches a step — the frontend asks "did ANY
position satisfy it", so the latest match is the checkable bound. -/
def pgLastIdx (steps : List String) (req : String) : Option Nat :=
  ((List.range steps.length).filter (fun i => steps[i]? == some req && true || steps[i]?.any (pgStepMatchesReq req))).getLast?

/-- Positions where the consumer name runs — the frontend checks every
step with the consumer's last segment. -/
def pgConsumerIdxs (steps : List String) (consumer : String) : List Nat :=
  (List.range steps.length).filter (fun i => match steps[i]? with | some s => (pgSplit s).2 == consumer | none => false)

def pgFieldN (fields : List String) (i : Nat) : Option String :=
  (fields[i]?).bind (fun f => (f.splitOn "=").getLast?)

def pgStageOrd (stage : String) : Option Nat :=
  if stage == "pre" then some 0 else if stage == "main" then some 1 else if stage == "post" then some 2 else none

/-- Corpus-level linearization + stage check: every observed root order
must satisfy every declared pipeline edge at every consumer position;
every transform edge's producer stage must be strictly earlier than the
consumer's (over every row that names it — a bare name hitting several
transforms resolves ambiguously, so all rows must satisfy). The census
must count the lines honestly. -/
def passGraphCheck (sites : List SiteLine) : List String :=
  let edges := sites.filter (·.kind == "pass-graph-edge")
  let orders := sites.filter (·.kind == "pass-graph-order")
  let tedges := sites.filter (·.kind == "pass-graph-tedge")
  let tstages := sites.filter (·.kind == "pass-graph-tstage")
  let cens := sites.filter (·.kind == "pass-graph-census")
  let orderV := edges.foldl (init := ([] : List String)) fun acc e =>
    orders.foldl (init := acc) fun acc2 o =>
      let steps := o.verdict.splitOn ","
      (pgConsumerIdxs steps e.site).foldl (init := acc2) fun acc3 i =>
        match pgLastIdx steps e.verdict with
        | some p =>
          if p < i then acc3
          else acc3 ++ [s!"order {o.site}: {e.site} requires {e.verdict} at pos {i} but {e.verdict} last runs at {p}"]
        | none => acc3 ++ [s!"order {o.site}: {e.site} requires {e.verdict} but the root order never runs it"]
  let stageV := tedges.foldl (init := ([] : List String)) fun acc e =>
    let cs := tstages.filter (·.site == e.site)
    let rs := tstages.filter (·.site == e.verdict)
    if cs.isEmpty then acc ++ [s!"tedge consumer {e.site} has no stage row"]
    else if rs.isEmpty then acc ++ [s!"tedge requirement {e.verdict} has no stage row"]
    else
      cs.foldl (init := acc) fun acc2 c =>
        match pgStageOrd c.verdict with
        | none => acc2 ++ [s!"tstage {c.site} carries unknown stage {c.verdict}"]
        | some oc =>
          rs.foldl (init := acc2) fun acc3 r =>
            match pgStageOrd r.verdict with
            | none => acc3 ++ [s!"tstage {r.site} carries unknown stage {r.verdict}"]
            | some or_ =>
              if or_ < oc then acc3
              else acc3 ++ [s!"tedge {e.site} requires {e.verdict} but {e.verdict} stage {r.verdict} is not earlier than {e.site} stage {c.verdict}"]
  let countsOk := match edges, orders, tedges, tstages, cens with
    | [], [], [], [], [] => true
    | _, _, _, _, [c] =>
      (match c.verdict.splitOn "=" with
       | ["edges", n] =>
         let fields := c.extra.splitOn ","
         n.toNat? == some edges.length && fields.length == 3 &&
           pgFieldN fields 0 == some (toString orders.length) &&
           pgFieldN fields 1 == some (toString tedges.length) &&
           pgFieldN fields 2 == some (toString tstages.length)
       | _ => false)
    | _, _, _, _, _ => false
  orderV ++ stageV ++ (if countsOk then [] else ["pass-graph census count drift"])


/-! ## Mark-file corpus input — `@witness(...)` lines

`[witness] site` lines are the *printed* rendering the witness pass emits
into backend output; the marks channel itself serializes as
`@witness("kind","site","arm<-mechanism","verdict","payload?")` — the
artifact shape command-side solvers (koruos/realize's `*.marks` files)
commit. Both decode to `SiteLine`; a mark's fifth field is ONE payload
string, so `extra` carries the whole field, spaces included. Marks carry
four or five quoted fields — the same shape `witnessMark`
(koru_std/witness.kz) and `witnessCheckParseMark`
(koru_std/compiler.witness.kz) accept. There are no escapes: a `"`
inside a field ends the parse, and the channel refuses such fields at
commit. -/

/-- Split a mark body's char list on the `","` field separator. Fields
cannot contain `"` (no escapes — the channel refuses them at commit), so
the separator is unambiguous. -/
def splitMarkFields : List Char → List (List Char)
  | [] => [[]]
  | '"' :: ',' :: '"' :: rest => [] :: splitMarkFields rest
  | c :: rest =>
    match splitMarkFields rest with
    | f :: fs => (c :: f) :: fs
    | [] => [[c]]

def parseMarkLine (line : String) : Option SiteLine :=
  match line.toList with
  | '@' :: 'w' :: 'i' :: 't' :: 'n' :: 'e' :: 's' :: 's' :: '(' :: rest =>
    match rest.getLast? with
    | some ')' =>
      let inner := rest.dropLast
      match inner.head?, inner.getLast? with
      | some '"', some '"' =>
        let fields := (splitMarkFields ((inner.drop 1).dropLast)).map String.ofList
        -- no field may carry a stray quote — the `","` separators are the
        -- only quotes in a well-formed mark body
        if fields.any (·.toList.contains '"') then none else
        match fields with
        | [k, s, a, v] =>
          if k.isEmpty || s.isEmpty || a.isEmpty || v.isEmpty then none else some ⟨k, s, a, v, ""⟩
        | [k, s, a, v, e] =>
          if k.isEmpty || s.isEmpty || a.isEmpty || v.isEmpty then none else some ⟨k, s, a, v, e⟩
        | _ => none
      | _, _ => none
    | _ => none
  | _ => none

/-! ## Kind `admission` — one demanded-iface bind verdict (koruos/realize)

A solver run commits one mark per demanded interface:

    @witness("admission","<iface>","<arm><-<mech>","<verdict>","<payload>")

The checker cannot re-run the row match — the row catalog is solver-side
data the mark does not carry — but the verdict is FORCED by the payload's
evidence shape, and that is what is re-decided: a mark whose payload does
not carry the evidence its verdict claims is rejected, not trusted.

    bound    <arm><-<mech>, mech ∉ {none, std-codegen}
             row=<site> declared_by=<prov> bind_by=<prov> grade=<V|M|C|D>
             — the serving row names the demanded iface (row == site);
             `declared_by` is the row's provenance, `bind_by` the bind's
             (a provider-supplied bind on a builtin row reports
             bind_by=koruos.native, not declared_by=builtin)
    refused  <arm><-none
             reason=missing-row                                — no row declared the iface
             row=<site> declared_by=<prov> reason=missing-binding [serves=<csv>]
                                                               — row exists, this arm doesn't bind it
    waived   <arm><-std-codegen   reason=std-pure              — std-pure demand admits no provider

Corpus-level (`admissionCheck`): one verdict per (site, arm) — the solver
emits each demanded iface once per run — and one arm per corpus: a
`*.marks` artifact is a single solver run. -/

def parseAdmissionArrow (arrow : String) : Option (String × String) :=
  match splitOnArrow arrow.toList with
  | some (a, m) => if a.isEmpty || m.isEmpty then none else some (String.ofList a, String.ofList m)
  | none => none

def isGrade (g : String) : Bool := g == "V" || g == "M" || g == "C" || g == "D"

def hasProv (tok : String) (pfx : String) : Bool :=
  tok.startsWith pfx && !(tok.drop pfx.length).isEmpty

/-- The serving row names the demanded site, allowing for tor scoping. A
site `<mod>.<path>:<tor>` may be served by a row whose declared iface is
the module path `<mod>/<path>` (a module-level row covers every tor) or
`<mod>/<path>:<rtor>` where `<rtor>` is a prefix of the demanded tor (a
tor-scoped row). Rows may also be declared in the site's own dotted
form — the exact-match arm covers that. A tor-scoped row never serves a
tor outside its prefix, and a tor demand is never served by a row
naming a different module. -/
def rowServesSite (row site : String) : Bool :=
  row == site ||
  match site.splitOn ":" with
  | [smod, stor] =>
    let spath := String.ofList (smod.toList.map fun c => if c == '.' then '/' else c)
    row == spath ||
    (match row.splitOn ":" with
     | [rmod, rtor] => !rtor.isEmpty && rmod == spath && stor.startsWith rtor
     | _ => false)
  | _ => false

def ruleAdmission (s : SiteLine) : Ruling :=
  match parseAdmissionArrow s.arrow with
  | none => .malformed
  | some (_, mech) =>
    let mechOk :=
      (s.verdict == "bound" && mech != "none" && mech != "std-codegen") ||
      (s.verdict == "refused" && mech == "none") ||
      (s.verdict == "waived" && mech == "std-codegen")
    if !mechOk then .malformed else
    match s.extra.splitOn " " with
    | [x, y, z, w] =>
      -- bound: row=<serving-row> declared_by=<p> bind_by=<p> grade=<g>
      if s.verdict == "bound" &&
         x.startsWith "row=" && rowServesSite (x.drop 4).toString s.site &&
         hasProv y "declared_by=" && hasProv z "bind_by=" &&
         w.startsWith "grade=" && isGrade (String.ofList (w.toList.drop 6))
      then .match_
      -- refused (row exists, unbound): ... reason=missing-binding [serves=<csv>]
      else if s.verdict == "refused" && z == "reason=missing-binding" &&
              x.startsWith "row=" && rowServesSite (x.drop 4).toString s.site &&
              hasProv y "declared_by=" && w.startsWith "serves="
      then .match_
      else .malformed
    | [x, y, z] =>
      if s.verdict == "refused" && z == "reason=missing-binding" &&
         x.startsWith "row=" && rowServesSite (x.drop 4).toString s.site &&
         hasProv y "declared_by="
      then .match_ else .malformed
    | [rsn] =>
      if s.verdict == "refused" && rsn == "reason=missing-row" then .match_ else
      if s.verdict == "waived" && rsn == "reason=std-pure" then .match_ else .malformed
    | _ => .malformed

/-- Role A: a `bound` admission the checker accepts carries a real
mechanism — the verdict could not have been minted on the refusal
(`none`) or waiver (`std-codegen`) channel. -/
theorem admission_bound_mechanism (s : SiteLine) (a m : String)
    (h : parseAdmissionArrow s.arrow = some (a, m))
    (hv : s.verdict = "bound") (hr : ruleAdmission s = .match_) :
    m ≠ "none" ∧ m ≠ "std-codegen" := by
  unfold ruleAdmission at hr
  rw [h, hv] at hr
  by_cases hm : m = "none" ∨ m = "std-codegen"
  · cases hm with
    | inl hm => subst hm; simp at hr
    | inr hm => subst hm; simp at hr
  · exact not_or.mp hm

/-! #### Admission/declaration pins — the relations' fixture classes,
decided at compile time -/

-- a bound mark's evidence: real mechanism, row naming the site, both
-- provenances, a grade in the evidence vocabulary
example : ruleAdmission ⟨"admission","koru.runtime","u<-kconfig","bound","row=koru.runtime declared_by=builtin bind_by=builtin grade=V"⟩ = .match_ := by native_decide
-- a provider-supplied bind on a builtin row: bind_by names the binder
example : ruleAdmission ⟨"admission","std.io:print","u<-native-runtime","bound","row=std.io:print declared_by=builtin bind_by=koruos.native grade=M"⟩ = .match_ := by native_decide
-- a bound claim cannot ride a refusal mechanism
example : ruleAdmission ⟨"admission","koru.runtime","u<-none","bound","row=koru.runtime declared_by=builtin bind_by=builtin grade=V"⟩ = .malformed := by native_decide
-- a bound claim cannot omit its evidence
example : ruleAdmission ⟨"admission","koru.runtime","u<-kconfig","bound","reason=missing-row"⟩ = .malformed := by native_decide
-- the same evidence cannot mint two verdicts: what proves bound rejects waived
example : ruleAdmission ⟨"admission","std.io:print","u<-kconfig","waived","row=std.io:print declared_by=builtin bind_by=builtin grade=V"⟩ = .malformed := by native_decide
-- a bound row serving a different iface than demanded is inconsistent data
example : ruleAdmission ⟨"admission","std.io:print","u<-kconfig","bound","row=other declared_by=p bind_by=q grade=M"⟩ = .malformed := by native_decide
-- a row absent from the catalog: missing-row carries no row identity —
-- a fabricated row= is rejected
example : ruleAdmission ⟨"admission","rzfix.badrow:ping","u<-none","refused","reason=missing-row"⟩ = .match_ := by native_decide
example : ruleAdmission ⟨"admission","rzfix.badrow:ping","u<-none","refused","reason=missing-row row=rzfix.badrow:ping"⟩ = .malformed := by native_decide
-- declared-but-unbound: the row's provenance rides the refusal
example : ruleAdmission ⟨"admission","std.io:print","u<-none","refused","row=std.io:print declared_by=builtin reason=missing-binding serves=hosted"⟩ = .match_ := by native_decide
example : ruleAdmission ⟨"admission","std.io:print","u<-none","refused","row=std.io:print declared_by=builtin reason=missing-binding"⟩ = .match_ := by native_decide
-- std-pure demand admits no provider mechanism
example : ruleAdmission ⟨"admission","std.fmt:fmt","u<-std-codegen","waived","reason=std-pure"⟩ = .match_ := by native_decide
example : ruleAdmission ⟨"admission","std.fmt:fmt","u<-kconfig","waived","reason=std-pure"⟩ = .malformed := by native_decide
-- a grade outside V|M|C|D is not evidence
example : ruleAdmission ⟨"admission","s","u<-kconfig","bound","row=s declared_by=p bind_by=q grade=X"⟩ = .malformed := by native_decide

-- tor scoping: a module-level row serves every tor of its module; a
-- tor-scoped row serves only its prefix; neither serves another module
example : rowServesSite "koruos/silo" "koruos.silo:open" := by native_decide
example : rowServesSite "koruos/silo:ca" "koruos.silo:call" := by native_decide
example : rowServesSite "std.io:print" "std.io:print" := by native_decide
example : !rowServesSite "koruos/silo:ca" "koruos.silo:open" := by native_decide
example : !rowServesSite "std.io:print" "std.io:scan" := by native_decide
example : !rowServesSite "koruos/other" "koruos.silo:open" := by native_decide
example : !rowServesSite "koruos/silo" "koruos.silo" := by native_decide

-- the real koruos marks: tor demands served by the module-level row
example : ruleAdmission ⟨"admission","koruos.silo:open","u<-kconfig","bound","row=koruos/silo declared_by=koruos.silo bind_by=koruos.silo grade=V"⟩ = .match_ := by native_decide
example : ruleAdmission ⟨"admission","koruos.spawn:grant","u<-none","refused","row=koruos/spawn declared_by=koruos.spawn reason=missing-binding serves=hosted"⟩ = .match_ := by native_decide
-- a row naming another module cannot claim the tor site
example : ruleAdmission ⟨"admission","koruos.silo:open","u<-kconfig","bound","row=koruos/spawn declared_by=p bind_by=q grade=V"⟩ = .malformed := by native_decide

/-! ## Kind `declaration` — a malformed row-decl refusal (koruos/realize)

A row declaration the parser refuses commits:

    @witness("declaration","<declaring-site>","decl<-parsed","refused","<class ...>")

The checker cannot re-parse the row — the declared source is not
committed — but a refusal must name a CLASS in the declared vocabulary,
with the fields that class commits:

    no-source-block                          — row site carried no JSON block
    lacks-iface-or-binds                     — row missing both identity fields
    lacks-field <field>                      — row missing a required field
    binds-<N>-lacks-arm-or-mechanism         — bind entry N missing its pair
    contradiction <iface> vs <prov>          — field set differently than earlier decl
    duplicate-arm <iface> <arm> [vs <prov>]  — same (iface, arm) declared twice
    new-row-lacks-stack <iface>              — first decl for iface carries no stack
    malformed-json <file>:<line>             — the JSON block itself refused

A declaration mark is only ever a refusal of a parse — `bound` is not in
its vocabulary. -/

def ruleDeclaration (s : SiteLine) : Ruling :=
  if s.arrow != "decl<-parsed" || s.verdict != "refused" || s.site.isEmpty then .malformed else
  match s.extra.splitOn " " with
  | ["no-source-block"] => .match_
  | ["lacks-iface-or-binds"] => .match_
  | ["lacks-field", f] => if f.isEmpty then .malformed else .match_
  | ["contradiction", i, "vs", p] => if i.isEmpty || p.isEmpty then .malformed else .match_
  | ["duplicate-arm", i, a] => if i.isEmpty || a.isEmpty then .malformed else .match_
  | ["duplicate-arm", i, a, "vs", p] => if i.isEmpty || a.isEmpty || p.isEmpty then .malformed else .match_
  | ["new-row-lacks-stack", i] => if i.isEmpty then .malformed else .match_
  | ["malformed-json", fl] =>
    match (fl.splitOn ":").getLast? with
    | some l =>
      -- file = everything before the last colon, non-empty (Windows
      -- paths carry a drive colon — only the LAST segment is the line)
      if l.toNat?.isSome && fl.length > l.length + 1 then .match_ else .malformed
    | none => .malformed
  | [t] =>
    if t.startsWith "binds-" && t.endsWith "-lacks-arm-or-mechanism" then
      let cs := t.toList.drop "binds-".length
      let mid := String.ofList (cs.take (cs.length - "-lacks-arm-or-mechanism".length))
      if mid.toNat?.isSome then .match_ else .malformed
    else .malformed
  | _ => .malformed

-- declaration: every refusal class in the vocabulary
example : ruleDeclaration ⟨"declaration","rzfix.badrow","decl<-parsed","refused","binds-0-lacks-arm-or-mechanism"⟩ = .match_ := by native_decide
example : ruleDeclaration ⟨"declaration","m","decl<-parsed","refused","binds-3-lacks-arm-or-mechanism"⟩ = .match_ := by native_decide
example : ruleDeclaration ⟨"declaration","m","decl<-parsed","refused","binds-x-lacks-arm-or-mechanism"⟩ = .malformed := by native_decide
example : ruleDeclaration ⟨"declaration","m","decl<-parsed","refused","duplicate-arm koruos/silo hosted"⟩ = .match_ := by native_decide
example : ruleDeclaration ⟨"declaration","m","decl<-parsed","refused","duplicate-arm koruos/silo hosted vs koruos/other"⟩ = .match_ := by native_decide
example : ruleDeclaration ⟨"declaration","m","decl<-parsed","refused","contradiction koruos/silo vs koruos/other"⟩ = .match_ := by native_decide
example : ruleDeclaration ⟨"declaration","m","decl<-parsed","refused","new-row-lacks-stack koruos/silo"⟩ = .match_ := by native_decide
example : ruleDeclaration ⟨"declaration","m","decl<-parsed","refused","no-source-block"⟩ = .match_ := by native_decide
example : ruleDeclaration ⟨"declaration","m","decl<-parsed","refused","lacks-iface-or-binds"⟩ = .match_ := by native_decide
example : ruleDeclaration ⟨"declaration","m","decl<-parsed","refused","lacks-field iface"⟩ = .match_ := by native_decide
example : ruleDeclaration ⟨"declaration","m","decl<-parsed","refused","malformed-json C:/a/b.k:12"⟩ = .match_ := by native_decide
example : ruleDeclaration ⟨"declaration","m","decl<-parsed","refused","malformed-json b.k"⟩ = .malformed := by native_decide
example : ruleDeclaration ⟨"declaration","m","decl<-parsed","refused","unknown-class"⟩ = .malformed := by native_decide
-- a declaration mark is only ever a refusal of a parse — bound is not in
-- its vocabulary, and a refusal through another arrow is not a declaration
example : ruleDeclaration ⟨"declaration","m","decl<-parsed","bound","lacks-field iface"⟩ = .malformed := by native_decide
example : ruleDeclaration ⟨"declaration","m","x<-y","refused","no-source-block"⟩ = .malformed := by native_decide

/-- Corpus-level admission laws: one verdict per (site, arm) — the solver
emits each demanded iface once per run, so a repeated pair (agreeing or
not) is splice/double-count drift — and one arm per corpus: a `*.marks`
artifact is a single solver run, so mixed arms mean two runs were spliced
(or the arm was computed twice). Returns violation lines; empty = clean.
Malformed arrows are skipped — the per-line pass already flags them. -/
def admissionCheck (sites : List SiteLine) : List String :=
  let adm := sites.filter (·.kind == "admission")
  let keys := adm.filterMap fun s =>
    (parseAdmissionArrow s.arrow).map fun (arm, _) => s!"{s.site} ← {arm}"
  let arms := (adm.filterMap fun s =>
    (parseAdmissionArrow s.arrow).map (·.1)).eraseDups
  let dupes := (keys.filter fun k => keys.count k > 1).eraseDups
  dupes.map (fun k => s!"{k} admitted twice") ++
    (if arms.length > 1 then [s!"{arms.length} arms in one marks corpus: {", ".intercalate arms}"] else [])

/-! ## Kinds `catalog` / `projection` — matrix-mode re-decision (koruos/realize)

`realize matrix` commits the resolved catalog as data plus one derived
cell per arm:

    @witness("catalog","<iface>","row<-declared","listed","declared_by=<prov> binds=<csv>|binds=none")
    @witness("projection","<arm>","matrix<-catalog","holds","bound=<n> total=<m>")

The printed `arm-matrix.txt` cell `<arm>: n/m` is a projection of the
catalog — committing both lets the checker RECOUNT the projection over
the committed rows (`projectionCheck`) instead of trusting the cell:
`total` must equal the catalog mark count and `bound` the number of
catalog rows carrying the arm in their binds. -/

/-- `catalog` per-line shape: declared provenance plus the row's arm
set. `binds=none` is a row serving no arm — it still counts in `total`,
which is what a forged `bound` would have to account for. -/
def ruleCatalog (s : SiteLine) : Ruling :=
  if s.arrow != "row<-declared" || s.verdict != "listed" || s.site.isEmpty then .malformed else
  match s.extra.splitOn " " with
  | [p, b] =>
    if hasProv p "declared_by=" &&
       (b == "binds=none" || (b.startsWith "binds=" && b.length > 6))
    then .match_ else .malformed
  | _ => .malformed

def parseNatField (tok pfx : String) : Option Nat :=
  if tok.startsWith pfx then (tok.drop pfx.length).toString.toNat? else none

/-- `projection` per-line shape: `bound=<n> total=<m>` with `n ≤ m` —
a cell cannot claim more bounds than rows exist. -/
def ruleProjection (s : SiteLine) : Ruling :=
  if s.arrow != "matrix<-catalog" || s.verdict != "holds" || s.site.isEmpty then .malformed else
  match s.extra.splitOn " " with
  | [b, t] =>
    match parseNatField b "bound=", parseNatField t "total=" with
    | some n, some m => if n ≤ m then .match_ else .malformed
    | _, _ => .malformed
  | _ => .malformed

/-- Corpus-level projection laws: every `total` must equal the committed
catalog size, each cell's `bound` must equal the recount over catalog
binds, each arm cell appears once, each catalog row is listed once, and
every arm named in a catalog bind carries a cell. Violation lines;
empty = clean. Malformed payload lines are skipped — the per-line pass
flags them. -/
def projectionCheck (sites : List SiteLine) : List String :=
  let cats := sites.filter (·.kind == "catalog")
  let projs := sites.filter (·.kind == "projection")
  if cats.isEmpty && projs.isEmpty then [] else
  let rowIfaces := cats.map (·.site)
  let dupeRows := (rowIfaces.filter fun i => rowIfaces.count i > 1).eraseDups
  let rowBinds : List (List String) := cats.filterMap fun s =>
    match s.extra.splitOn " " with
    | [_, b] =>
      if b.startsWith "binds=" && b != "binds=none" then some ((b.drop 6).toString.splitOn ",")
      else if b == "binds=none" then some []
      else none
    | _ => none
  let boundArms := rowBinds.flatten.eraseDups
  let projArms := projs.map (·.site)
  let dupeCells := (projArms.filter fun a => projArms.count a > 1).eraseDups
  let cellViolations := projs.filterMap fun s =>
    match s.extra.splitOn " " with
    | [b, t] =>
      match parseNatField b "bound=", parseNatField t "total=" with
      | some n, some m =>
        let recounted := rowBinds.countP (·.contains s.site)
        if m != cats.length then some s!"{s.site}: total={m} but catalog has {cats.length} rows"
        else if n != recounted then some s!"{s.site}: bound={n} but recount gives {recounted}"
        else none
      | _, _ => none
    | _ => none
  let missingCells := boundArms.filter fun a => !projArms.contains a
  dupeRows.map (fun i => s!"catalog row {i} listed twice") ++
    dupeCells.map (fun a => s!"{a} projected twice") ++
    cellViolations ++
    missingCells.map (fun a => s!"{a} bound in catalog but no projection cell")

-- catalog: provenance plus an arm set (csv or the explicit `none`)
example : ruleCatalog ⟨"catalog","koruos/silo","row<-declared","listed","declared_by=koruos.silo binds=u,koru-native"⟩ = .match_ := by native_decide
example : ruleCatalog ⟨"catalog","std.fmt:ln","row<-declared","listed","declared_by=builtin binds=none"⟩ = .match_ := by native_decide
example : ruleCatalog ⟨"catalog","x","row<-declared","listed","binds=u"⟩ = .malformed := by native_decide
example : ruleCatalog ⟨"catalog","x","row<-declared","listed","declared_by= binds=u"⟩ = .malformed := by native_decide
example : ruleCatalog ⟨"catalog","x","row<-declared","bound","declared_by=p binds=u"⟩ = .malformed := by native_decide

-- projection: the cell claims a count within the committed catalog size
example : ruleProjection ⟨"projection","koru-native","matrix<-catalog","holds","bound=2 total=8"⟩ = .match_ := by native_decide
example : ruleProjection ⟨"projection","koru-native","matrix<-catalog","holds","bound=9 total=8"⟩ = .malformed := by native_decide
example : ruleProjection ⟨"projection","koru-native","matrix<-catalog","holds","bound=x total=8"⟩ = .malformed := by native_decide
example : ruleProjection ⟨"projection","koru-native","matrix<-catalog","holds","bound=2"⟩ = .malformed := by native_decide

-- the recount is the re-decision: agreeing cells pass, drifted bound or
-- total fails, and a bound arm with no cell is caught
example : projectionCheck [
    ⟨"catalog","r1","row<-declared","listed","declared_by=p binds=u,koru-native"⟩,
    ⟨"catalog","r2","row<-declared","listed","declared_by=p binds=u"⟩,
    ⟨"projection","u","matrix<-catalog","holds","bound=2 total=2"⟩,
    ⟨"projection","koru-native","matrix<-catalog","holds","bound=1 total=2"⟩] = [] := by native_decide
example : (projectionCheck [
    ⟨"catalog","r1","row<-declared","listed","declared_by=p binds=u,koru-native"⟩,
    ⟨"projection","u","matrix<-catalog","holds","bound=2 total=1"⟩]).length > 0 := by native_decide
example : (projectionCheck [
    ⟨"catalog","r1","row<-declared","listed","declared_by=p binds=u,koru-native"⟩,
    ⟨"projection","u","matrix<-catalog","holds","bound=1 total=1"⟩]).length > 0 := by native_decide
example : (projectionCheck [
    ⟨"catalog","r1","row<-declared","listed","declared_by=p binds=u"⟩,
    ⟨"catalog","r1","row<-declared","listed","declared_by=p binds=u"⟩,
    ⟨"projection","u","matrix<-catalog","holds","bound=2 total=2"⟩]).length > 0 := by native_decide


def rule (s : SiteLine) : Ruling :=
  if s.kind == "stored-write-numeric" then ruleNumeric s
  else if s.kind == "auto-discharge" then ruleDischarge s
  else if s.kind == "custody-edge" then ruleCustody s
  else if s.kind == "descriptor" then ruleDescriptor s
  else if s.kind == "descriptor-scope" then ruleDescriptorScope s
  else if s.kind == "transform-app" then ruleTransformApp s
  else if s.kind == "transform-oblige" then ruleTransformOblige s
  else if s.kind == "transform-app-census" then ruleTransformAppCensus s
  else if s.kind == "pass-graph-edge" then rulePassGraphEdge s
  else if s.kind == "pass-graph-order" then rulePassGraphOrder s
  else if s.kind == "pass-graph-tedge" then rulePassGraphEdge s
  else if s.kind == "pass-graph-tstage" then rulePassGraphTstage s
  else if s.kind == "pass-graph-census" then rulePassGraphCensus s
  else if s.kind == "admission" then ruleAdmission s
  else if s.kind == "declaration" then ruleDeclaration s
  else if s.kind == "catalog" then ruleCatalog s
  else if s.kind == "projection" then ruleProjection s
  else if s.kind == "strip-use" then ruleStripUse s
  else if s.kind == "strip-root" then ruleStripRoot s
  else if s.kind == "strip-rm" then ruleStripRm s
  else if s.kind == "strip-cargo" then ruleStripCargo s
  else if s.kind == "strip-census" then ruleStripCensus s
  else .malformed

def isSiteLine (line : String) : Bool :=
  line.startsWith "[witness] site "

/-- A corpus line carrying a witness — the printed `[witness] site` shape
passes emit into backend output, or the raw `@witness(...)` mark shape a
marks artifact (`*.marks`) commits. -/
def isWitnessLine (line : String) : Bool :=
  isSiteLine line || line.startsWith "@witness("

def parseArgs : List String → Option (Bool × String)
  | ["--forged", p] => some (true, p)
  | [p] => some (false, p)
  | _ => none

def main (args : List String) : IO UInt32 := do
  let some (forged, path) := parseArgs args
    | do IO.eprintln "usage: WitnessCheck [--forged] <corpus>"; return 2
  let lines := (← IO.FS.lines path).toList.filter isWitnessLine
  if lines.isEmpty then
    IO.println s!"FAIL: no [witness] site/@witness lines in {path}"
    return 1
  let mut bad := 0
  let mut sites : List SiteLine := []
  for line in lines do
    let sOpt := if isSiteLine line then parseSiteLine line else parseMarkLine line
    if let some s := sOpt then sites := s :: sites
    let ruling := match sOpt with
      | none => Ruling.malformed
      | some s => rule s
    let accepted := match ruling with | .match_ => true | _ => false
    let label := match ruling with
      | .match_ => "MATCH"
      | .mismatch want => s!"MISMATCH (checker: {want})"
      | .malformed => "MALFORMED"
    -- In --forged mode every line must be rejected; otherwise every line must match.
    let ok := if forged then !accepted else accepted
    if !ok then bad := bad + 1
    IO.println s!"{if ok then "ok  " else "BAD "} {label}  {line}"
  -- Corpus-level custody balance: replay each arrow's edge ledger. An
  -- unclosed mint is a leaked obligation; an illegal edge is a ledger the
  -- checker itself could not have walked — both fail the batch either way.
  for a in custodyBalance sites.reverse do
    -- A corpus violation is rejection evidence: it fails a conformance
    -- batch, and in forged mode it is one more reason the batch can't
    -- pass — counting it as `bad` there would punish rejection itself.
    if !forged then bad := bad + 1
    IO.println s!"{if forged then "ok  " else "BAD "} UNBALANCED  {a}"
  -- Corpus-level descriptor census: every scope's count must equal its
  -- descriptor lines, and every descriptor scope must carry a census.
  for sc in descriptorScopeBalance sites.reverse do
    if !forged then bad := bad + 1
    IO.println s!"{if forged then "ok  " else "BAD "} SCOPE-DRIFT  {sc}"
  -- Corpus-level transform-app census: the count must equal the emitted
  -- application lines — a dropped or invented application unbalances it.
  if !transformAppBalance sites.reverse then
    if !forged then bad := bad + 1
    IO.println s!"{if forged then "ok  " else "BAD "} APP-DRIFT  transform-app census"
  -- Corpus-level obligation pairing: each wp application's declared
  -- obliges must be discharged by exactly the oblige lines following it,
  -- carrying evidence equal to the app's own commits.
  for v in transformObligeCheck sites.reverse do
    if !forged then bad := bad + 1
    IO.println s!"{if forged then "ok  " else "BAD "} OBLIGE-VIOLATION  {v}"
  -- Corpus-level pass-graph re-decision: declared edges must hold in
  -- every observed root order, transform edges must point at a strictly
  -- earlier stage, and the census must count the emitted lines honestly.
  for v in passGraphCheck sites.reverse do
    if !forged then bad := bad + 1
    IO.println s!"{if forged then "ok  " else "BAD "} GRAPH-VIOLATION  {v}"
  -- Corpus-level admission laws: one verdict per (site, arm) and one arm
  -- per marks artifact — a repeated pair or a mixed arm is splice drift.
  for v in admissionCheck sites.reverse do
    if !forged then bad := bad + 1
    IO.println s!"{if forged then "ok  " else "BAD "} ADMIT-DRIFT  {v}"
  -- Corpus-level projection re-decision: the matrix cells are recounted
  -- over the committed catalog marks, never trusted as printed.
  for v in projectionCheck sites.reverse do
    if !forged then bad := bad + 1
    IO.println s!"{if forged then "ok  " else "BAD "} PROJ-DRIFT  {v}"
  -- Corpus-level strip re-decision: every removed key must be absent from
  -- the committed use/root spellings — the pass's own membership law,
  -- replayed rather than trusted.
  for v in stripCheck sites.reverse do
    if !forged then bad := bad + 1
    IO.println s!"{if forged then "ok  " else "BAD "} STRIP-VIOLATION  {v}"
  let mode := if forged then "forged (all must reject)" else "conformance (all must match)"
  IO.println s!"{mode}: {lines.length} lines, {bad} bad"
  return (if bad == 0 then 0 else 1)

end Koru.WitnessCheck

def main (args : List String) : IO UInt32 := Koru.WitnessCheck.main args
