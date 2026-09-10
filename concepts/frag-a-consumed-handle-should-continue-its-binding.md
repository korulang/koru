---
type: belief
id: frag-a-consumed-handle-should-continue-its-binding
provenance: Lars design discussion 2026-09-10 (raylib `frames`/`activate`, db `tx.exec`); LANDED 2026-09-10 on handle-continuation — bare-return and branch-payload halves, board 1638/1643 unchanged (same five reds). The first writing of this belief was aspirational and pinned red at 336_007/336_008.
ts: 2026-09-10
---

# A consumed same-typed handle is ONE entity advancing, not a value spent and a new one minted (landed)

A tor that consumes `*T<!s>` and re-mints `*T<s'!>` is describing the *same
entity* with a new state. The caller used to have to model it as death-and-birth:
the consumed binding is spent, and the re-minted handle is re-bound under a new
name. Every rebind of this kind carries no information — the new symbol is the
old pointer with a new state, and the implementation already proves it
(`raylib`'s `frames` is `return .{ .done = win }`; `window.activate -> win` is
the transition written out).

The ceremony was real and visible:

- `raylib/tests/draw_per_entity.k`: `| win w |> frames(win: w, …)` … `| done w2 |> close(win: w2)` — `w2` is `w`.
- `raylib/tests/texture.k`: `activate(win: w): wx |> close(win: wx)` — `wx` is `w`.
- `koru` `336_006`: `begin(conn: c): t |> exec(tx: t): t2` — here `t2` is `t`
  (same base type, `Transaction`); the `c → t` and `tx → Connection` re-binds
  either side are legitimate (different base types, genuinely new entities).

## The rule that landed

The **sole same-typed survivor advances its input binding in place**. Named or
anonymous payload, branch or bare return — one rule. The disambiguating rebind
(several same-typed handles in flight) stays, because there the name is the
thing that says *which* entity continues.

Landed in two halves on the same day, in this order: the **bare return**
(`-> *Handle<active!>`; the binding continues with the new phantom state and the
result is not re-minted) and the **branch payload** (`| advanced *Handle<active!>`
identity, or a named field that matches the input's name). Pins `336_007`/`336_010`
are the bare-return shape (identity-agnostic: `336_010` allocates a NEW handle and
the binding still continues); `336_008` is the identity branch payload; `336_009`
is the named-field form. All four are green as `MUST_RUN`.

## Four conditions — three of them learned by breaking the board

The rule does not fire on the base-type match alone. Two full boards produced six
new reds, and each round narrowed the rule to a condition the belief above had
left implicit. The lesson is the general one: **a rule stated as "same base type
continues" is a hypothesis until a board tells you what else it matched.**

1. **Sole survivor.** Two same-typed handles consumed and one minted means no
   sole survivor, so neither continues (`336_011`, the guard that must stay red).
2. **A genuine STATE CHANGE, not a same-state re-issue.** An event that consumes
   `<!s>` and hands `s` straight back has not advanced the entity — advancing it
   resurrects an obligation the call settled. The store's `__store_insertf_*`
   `full` branch is exactly this (the failed insert returns the foreign value);
   it broke `440_007` and `690_240` until the rule compared state NAMES rather
   than base types. A re-issue is the re-issue predicate's business, not the
   continuation rule's.
3. **No author-named rebind.** An explicit `| ok r |` on a payload that re-mints
   the input `t` is the disambiguating spelling the section above says STAYS;
   honoring it means `t` is spent, not continued. Firing there left `t`
   advanced-and-unused and leaked its obligation — it broke the whole `2104` db
   cluster. Only an implicit binder (`_`) or a name-matched field continues. The
   auto-discharge inserter's synthetic `_auto_N` rename must count as implicit,
   or the post-insertion pass and the pre-insertion pass disagree.
4. **Identity is invisible to the caller — the rule is base-type, not pointer.**
   The signature cannot say whether the implementation re-tags the same pointer
   or mints a new one, and it should not have to. `336_010` pins this: the
   binding continues regardless of allocation. A **type** change gets a new name,
   because there the old name would lie about what it holds (`begin`:
   `Connection → Transaction`).

## Which output continues which — the written/unwritten line again

The correspondence is not one mechanism but the same bright line the thread
already draws (`frag-the-thread-binds-by-type`: *"what you write binds by name,
what you do not write binds by type"*):

- A **named** payload field — `| advanced { h: *Handle<active!>, n: i32 }` —
  continues the same-named input `h`; the name does the matching, and the other
  fields (`n`) are ordinary new bindings.
- An **identity** payload — `| advanced *Handle<active!>` — has no field name to
  write, so the sole same-typed input continues by type, but only when the branch
  binder is itself unwritten (condition 3). This is the only legal spelling when
  there is a single output: a one-field record is refused (`KORU003`).

So the rule reuses the chain's existing matching machinery at the binding, rather
than inventing a third mechanism. The name matches where a name can be written,
the type matches exactly where the language removes the ability to write one, and
an author-written name always wins over the type match.

## The eventual refusal (the lever, not the whole)

A legal-but-inferior spelling never migrates; it accumulates beside the good
one. So the advance should land *with* a refusal of the unambiguous rebind — the
KORU115 move (retire the spelling, teach the fix), not a discouragement.
**Sequencing is load-bearing:** refuse first and the only legal spelling is
gone, so the transition cannot be expressed at all. Advance and refusal are one
ruling; the corpus that taught the wart (raylib) is the corpus that proves the
fix. The advance is now landed; the **refusal is still unruled** — and condition
3 is precisely the hold-out it must eventually retire.

## Open — and "hairy" by Lars's own flag

- **A borrow (no `!`) is not a transition and must not advance or consume** —
  pinned conceptually but not by a test.
- **`_` / auto-discharge**: a discarded advanced payload must leave the obligation
  live on the input binding, not heal it away (`: _` currently auto-discharges an
  obligation-carrying payload — `frag-phantom-bind-chain-threading`).
- **Auto-threading already exists in some cases**; the advance must not collide
  with it.
- **The thread/pun reaching further** — the hypothesis that name-continuity lets
  the sole-survivor thread carry obligations across more stages.
- **Same-state re-issue is deliberately NOT a continuation.** Whether an event
  that consumes and returns the SAME state should also advance its input is an
  open question; today it does not, and the re-issue predicate governs it.

No `tor`-syntax overload, and no mangling. The old binding is consumed *before*
the new value exists, so a second live value never shares the name — the emitter
reassigns one slot (`w = step(w)`). Mangling is owed only when two values are
live at once, which a consuming call rules out.

## Pins

- `336_007_same_type_handle_advances_in_place` — arrow/bare-return (`advance -> h`).
- `336_010_continuation_is_identity_agnostic` — the implementation **allocates a
  new handle**; the binding still continues.
- `336_008_branch_transition_continues_its_binding` — identity branch payload.
- `336_009_named_payload_field_continues_its_binding` — named multi-field payload:
  the NAME half.

Guard (must STAY red — the negative space that keeps the rule from over-applying):

- `336_011_ambiguous_survivor_forces_explicit_binding` — two same-typed handles
  consumed, one minted: no sole survivor, so neither input continues.

### Boundaries not yet pinned
- A **borrow** (no `!`) is not a transition and must not advance or consume.
- A consume with **no returned handle** spends the binding (safety guard).
- The **thread/pun reaching further**.
- The eventual **refusal** of the unambiguous rebind.
