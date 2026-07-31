---
type: belief
id: frag-subprocess-term-read-optimistically-is-a-class
provenance: OOM-killed backend build (load 113, 2026-07-31) panicked koruc with "access of union field 'Exited' while field 'Signal' is active"; a benchmark port was misrecorded as BUILD FAILED with an empty diagnostic
ts: 2026-07-31
---

# A subprocess termination read optimistically is a class, and its failure misfiles machine events as compiler verdicts

koruc spawns children everywhere — the Stage B `zig build`, the backend
coordinator, package managers, installer probes, comptime commands, the
emitted backend's own Stage D — and every one of those sites read the
result as `term.Exited`, an unchecked union-field access. We believed
(implicitly, by never writing the other arms) that a child either exits
or the spawn fails. The contradiction: a child can be *ended from
outside* — the OOM killer under memory pressure, an external `kill` —
and then the active field is `.Signal` and the access panics. The panic
names koruc's own `main`, so a machine event (out of memory) presents as
a compiler crash and gets diagnosed as one. Measured: one line panicked,
but the same optimistic read existed at 15 sites across koruc and the
backend code it emits, plus koru_std (`deps.kz`, `package.kz`) — a
single panicking line is the visible tip of a habit.

The belief this leaves us with: **which process ended, and who ended it,
is diagnostic content, never control noise.** Every site that inspects a
`Child.Term` switches over all four variants, and the `.Signal` arm says
the true thing out loud — which subprocess, which signal, that the
ending came from outside (usually memory), and that the source program
was never judged. Folding a signal into a bare `exit 1` is the same
misfiling with the panic removed.

The one site that had it right before the sweep: `koru_std/invariants.kz`
guards with `term == .Exited and term.Exited == 0` — the guard idiom
existed in the repo; it just never propagated. Open: the koru_std sites
carry the class still (another lane's ground), and the checked-in
generated snapshot under `scripts/binary-size-comparison/build/` embeds
the old pattern until regenerated.
