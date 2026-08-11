---
type: belief
id: frag-region-colouring-cannot-see-its-regions
provenance: calibration probe 2026-08-08 (probes/concurrency_calibration — sabotage.py, analyse.py, measured.txt); landed 2026-08-11 from worktree-agent-a4c0e547f7e3868fc
ts: 2026-08-08
---

# Auto-mutex insertion cannot colour what it must lock — the regions it would colour are not Koru (belief)

The automatic-mutex-insertion design brief premises "a thread handle is an
obligation (spawn mints, join consumes)" and cites `koru_std/threading.kz` as
the sketch of that discipline. The probe falsified the citation: the WorkerHandle
there wraps a `std.Thread` with no phantom, so nothing is minted or consumed; the
thread body is a host function pointer (`*const fn (*anyopaque) *anyopaque`), so
the region has no Koru contents to colour even in principle; the shared state is
`*anyopaque`, unattributable; and the level-1 `worker.spawn` detaches — there is
no join for the obligation to consume. The premise does not match the file it
cites, and the mismatch is structural, not a fix-up.

Where regions DO exist, the colouring cannot see inside them: 2154 of 3800
effectful leaves (56.7%) are opaque host proc bodies — a floor, since those
bodies hold ~15k statements between them while a store touch is one operation.
Corpus-wide implementation opacity is ~85% (app+std), ~98% inside koru_std, and
13 of 2167 implementations declare themselves pure.

The calibration also shows what IS tractable, so follow-up lands there rather
than on colouring: region delimiting — 318 of 7134 app call sites unresolved
(4.5%), none of them caused by indirection or dynamic dispatch — and state
attribution to a named store, 1573/1646 (95.6%).

## The rung that follows

The blocking layer is not the colouring algorithm: it is visibility. Either the
threading surface becomes pure Koru (real, compiler-visible obligations) or the
checker learns to trust a purity declaration (13 claims exist today). Designing
the mutex insertion before one of those lands is designing for a region that
does not exist.

## Open question

Is the "no Koru in the region" a threading.kz gap or a host-interop boundary
ruling? The 400_160–166 lesson is the warning on the side of "gap": host facets
made a pure-Koru feature (prototype mode) read as a host add-on until the pins
migrated to `.k`. Threading's surface is host through and through — whether that
is the feature's nature or its current spelling is unruled.

Numbers are the instrument's, not this belief's: `probes/concurrency_calibration/measured.txt`,
reproducible via `sabotage.py` / `analyse.py` there. Restated prose lies.