---
type: belief
id: frag-signature-validation-precedes-flow-analysis
provenance: surfaced fixing the 330_110 dormant-wall pass-ordering bug — KORU033 existed and worked but only fired under --auto-discharge=disable (2026-07-20)
ts: 2026-07-20
---

# Declaration-shape validation precedes obligation-flow analysis (belief)

A wall on a tor's OWN SIGNATURE — illegal obligation polarity like issuing
`<owned!>` on an input parameter, or an unknown phantom module — is a
**declaration-shape** error: it is true of the declaration alone, before any
program flow is considered. Obligation-FLOW passes (auto-discharge insertion,
phantom flow checking) *reason about programs using* those declarations. If a
flow pass runs first, a malformed declaration doesn't get rejected — it gets
**misdiagnosed**: the flow pass chokes on the nonsense the declaration implies
and halts with a spurious flow error (a KORU030 "leak" for an obligation that
should never have existed), while the real declaration wall sits dormant behind
it. The wall exists, works, and never fires — the worst kind of broken, because
every probe of the wall in isolation says it's fine.

The ruling: in the `~analysis` chain, declaration-shape checks on signatures run
BEFORE any pass that does obligation-flow reasoning. This is why
`check-phantom-signatures` sits between `check-structure` and
`pass-auto-discharge`, while `check-phantom-semantic` (the flow half) stays
after auto-discharge — it must validate the inserted disposal calls. The split
is principled, not incidental: one checker library, two pipeline homes, chosen
by which QUESTION each half answers (is the declaration well-formed? vs. does
the program's flow satisfy it?).

The pit this walls: adding a signature-level wall to a checker that runs late in
the chain, testing it in isolation (or under a flag that disables the earlier
flow pass), and shipping it dormant. Detector: if a new declaration-level
diagnostic only fires with some pass disabled, its home is wrong — move the
check earlier, never document the flag. The 330_110 / 330_111 pins guard the
polarity instance.

Open: other declaration-shape checks still living inside post-auto-discharge
passes (the flow checker's own signature-ish walls) may deserve the same lift;
nobody has swept for them.
