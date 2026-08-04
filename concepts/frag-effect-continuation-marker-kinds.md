---
type: belief
id: frag-effect-continuation-marker-kinds
provenance: introduced by the 400_171/172 pin — the !/| marker-kind mismatch is silently accepted, 2026-07-23; wall built + "frontend" corrected to Stage-C analysis, 2026-07-25
ts: 2026-07-23
---

# `!` and `|` are separate branch KINDS — the marker must match the call

Koru has two branch markers and they are **separate kinds, not interchangeable
syntax**:

- **`!` — effect arms.** Handle the effects/tors an invocation *fires*: `query`
  and `watch` install standing rules, lifecycle interceptors (`! inserted` /
  `! removed`), streaming (`! line` / `! row`), capture (`! as`). The invocation
  is a producer; the `!` arms are its effect handlers.
- **`|` — continuation / outcome branches.** The outcome a call *returns* — you
  match which one it yielded: `insert … | row | full`, `from-page … | ok | err`,
  `take … | item`. A sum-type result.

**The rule (Lars, 2026-07-23): the marker at a call site MUST match the tor's
declared branch-kind, and the mismatch is a hard reject.** `!` and `|` are to be
kept extremely well separated — an effect marker on an outcome-branch call, or a
continuation marker on an effect, is not a stylistic choice, it is a kind error.
(Open edge, leaning "no": whether one tor may declare both a `!name` and a
`|name` sharing a name — probably disallowed.)

## As built — the wall lives at Stage-C ANALYSIS, not the frontend

Landed on main `4f7ecfa2` (2026-07-25). The pins are green: `400_171` (`!` on an
outcome branch) and `400_172` (`|` on an effect).

The wall is **not** a frontend (Stage-A) reject, and it *cannot* be — the belief
originally said "frontend" but that was wrong about the architecture. The
store's `take`/`query`/`insert` are `~[…|transform]` **comptime transform tors**
(`store.kz`): they mint their branch structure — the generated event
`__store_take_<s>` with its `| item` / `| empty` outcomes — during the
metacircular pipeline. At the Stage-A frontend those branch-kinds **do not yet
exist**, so the mismatch can only be seen after transforms, in Stage-C
**analysis**. This still fires *before any host code is emitted* (analysis runs
ahead of emission), so no leaking program is ever produced — the spirit holds,
the stage was just wrong.

Two sites, by where each kind's branches become visible:

- **Outcome direction (`!` on a `|` branch)** — `KORU025` in the **phantom
  semantic checker**, where a transform-generated event first exposes its branch
  kinds (`branch 'item' is declared as terminal '|' but the handler uses effect
  '!'`, single-sourced via `errors.branchKindMismatch`, shared with the local-event
  pins `510_100/101`). Classifies as `BACKEND_RUNTIME_ERROR`.
- **Effect direction (`|` on an effect)** — the **`query`/`preorder` transform**
  in `store.kz` validates its own standing-rule branch vocabulary (it mints no
  matchable outcome event), rejecting `| query` with `continuation marker '|'
  used where an effect branch is required — 'query' fires the effect arm
  '! query'`. Classifies as `BACKEND_COMPILE_ERROR`.

The markers ARE semantically distinct *to the compiler* — the correct `| item`
form is leak-clean and only the marker changed to produce the leak — which is why
this was a missing wall, not lenient-by-design grammar.
