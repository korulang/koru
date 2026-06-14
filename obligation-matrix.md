# The Obligation Matrix

The permutation matrix of Koru’s phantom-obligation discharge system — every (resource × state) × discharge scenario, the behavior the ratified model designs for it, and whether the compiler matches today.

> Generated from `tests/regression/300_ADVANCED_FEATURES/336_OBLIGATION_MATRIX/` + the live test snapshot. **Do not edit by hand** — run `node scripts/generate-obligation-matrix.js`. Each cell IS a canonical test; the grid is a pure projection, so it cannot drift.

Snapshot: `5cae8fd5` @ 2026-06-14T05:11:21.144Z

✅ compiler matches the designed behavior · ❌ diverges (the to-do list) · · no cell yet (gap)

| resource × state | drop · single path | drop · multi-branch | drop · discard branch | escape · declared out | leak · subflow bound | ambiguous · 2 voids | non-void only | transition chain |
|---|---|---|---|---|---|---|---|---|
| **String** `<view!>` | ✅ | ✅ | · | · | · | · | · | · |
| **String** `<instance!>` | ✅ | · | ❌ | · | · | · | · | · |
| **Connection** `<connected!>` | · | · | · | · | · | · | · | · |
| **Connection** `<active!>` | ✅ | · | · | · | · | · | · | · |
| **Transaction** `<started!>` | · | · | · | · | · | · | · | · |
| **Transaction** `<active!>` | · | · | · | · | · | · | ✅ | · |

## Cells

### ✅ String `<view!>` — drop-single

- **Designed:** `auto-discharge`
- **Pinned by:** `336_001_string_view_drop_single`
- **Live status:** success
- A view! String dropped at the end of a single path auto-frees via `free` (the void terminal disposer).

### ✅ String `<instance!>` — drop-single

- **Designed:** `auto-discharge`
- **Pinned by:** `336_002_string_instance_drop_single`
- **Live status:** success
- An instance! String (via take) dropped at the end of a single path auto-frees via `free` (void terminal; release is non-void so excluded — unambiguous).

### ❌ String `<instance!>` — drop-discard-branch

- **Designed:** `auto-discharge`
- **Pinned by:** `336_003_string_instance_drop_discard_branch`
- **Live status:** failure
- An instance! String live on an all-discard `| err _ |> _` branch of a borrowing op (append) MUST auto-free on that branch. Currently RED — the inserter does not materialize `free` on an empty discard branch (branch-asymmetry / Root-B family). Goes green when the cluster fix lands.

### ✅ String `<view!>` — drop-multibranch

- **Designed:** `auto-discharge`
- **Pinned by:** `336_004_string_view_drop_multibranch`
- **Live status:** success
- A view! String live across both real-body branches of a borrowing op (parse-int) auto-frees on each branch independently.

### ✅ Transaction `<active!>` — nonvoid-only

- **Designed:** `reject-call`
- **Pinned by:** `336_005_transaction_active_nonvoid_only`
- **Live status:** success
- An active! Transaction has only NON-void disposers (commit/rollback — a choice, no void terminal), so it cannot auto-discharge. KORU030 names commit and rollback; the self-loop tx.exec is correctly excluded.

### ✅ Connection `<active!>` — drop-single

- **Designed:** `auto-discharge`
- **Pinned by:** `336_006_connection_active_drop_single`
- **Live status:** success
- A committed Connection<active!> dropped at the end of a single path auto-discharges via close — the [!] void terminal disposer for <!active>.

---

**6 cells** · 5 matching the model · 1 diverging (the to-do list).
