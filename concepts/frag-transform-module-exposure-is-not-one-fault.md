---
type: belief
id: frag-transform-module-exposure-is-not-one-fault
provenance: surfaced running the first arm of the 115_COMPTIME_MIRROR wall 2026-07-26, the morning after 690_079 closed the same hole for std/store; the one-fault story it repudiates was drawn from reading five call sites the night before, and did not survive running them
ts: 2026-07-26
---

# The module boundary is a shared EXPOSURE for comptime transforms, not a shared fault (belief)

When a transform's subject moves out of the entry file, several libraries break
at once. The tempting reading — and the one we held for a night — is that this
is a single fault reinvented by every author: *the author spelled a name the
framework should have spelled*. In the entry file the file-derived name, the
import-derived logical name, and the emitted `main_module` all collapse into one
word, so a path minted from the wrong domain is indistinguishable from a correct
one until the declaration lands in a module. That collapse is real, and it is
why nothing diverged for months.

It is not the whole fault, and treating it as the whole fault mis-designs the
fix.

## What the boundary actually is

The module boundary is the first position where a transform's *assumptions get
told apart*. Everything a transform silently relies on — which namespace it
mints into, whether its appended declaration is reachable from the use site,
whether the emitter's per-flow bookkeeping re-runs over nodes the transform
rebuilt — is uniformly satisfied in the entry file and independently violable
outside it. So one relocation exposes many different bugs simultaneously, and
their simultaneity is an artifact of the instrument, not evidence of a common
cause.

The 115 cluster is that instrument. Its reds are separately diagnosed and each
pins its own diagnostic; read them there rather than trusting a summary here.
`115_008`/`115_010` matter as much as the reds: they relocate the same shapes
with no synthesizing library and stay green, which is what makes a red
attributable to the library rather than to modules in general.

## Why the distinction is load-bearing

The proposed remedy is an authoring surface that makes the namespace
**un-nameable** — the author says what they declare and that it belongs to this
site, the framework owns placement and qualification. That is the right move and
this belief does not weaken it. But it addresses the *misnaming* class only. A
transform that loses its appended declaration at the use site, or one whose
rebuilt subtree escapes emitter bookkeeping it never knew existed, is not
holding a name at all — there is nothing for an un-nameable namespace to
prevent.

So: an authoring surface is not a fix for the module boundary. It removes one
class of exposure. The others need their own walls, and the wall has to exist
first, because it is the only thing that says which classes are present.

## The methodological point, which is the durable half

Five call sites read carefully produced a confident, elegant, wrong
generalisation. Three probes run produced three faults. The failure mode was not
carelessness — it was that reading a transform tells you what its author
*intended* the names to be, and the fault is always in what the machinery does
with them. In this area, reasoning off a read has now been wrong every single
time it has been tried; the same note appears in the store work that preceded
it. Probe, change one variable, and let the diagnostic name the fault class.

## The instrument also finds things that are not about modules

Relocating a body is not a semantics-preserving edit, and assuming it was cost
one wrong reading already: a source-block-carrying transform moved into a tor
body meets a parser refusal that has nothing to do with the boundary, because a
subflow-DEFINITION line cannot open a source block anywhere on it. Held by
115_017 in the entry file, where no module exists to blame. The same construct
relocates cleanly once the block closes on its line.

So every red on this wall needs its entry-file twin before it counts as a module
finding. That is not wall bureaucracy — it is the difference between a fault
list and a list of things that happened to be red at the same time.

## Open

- Whether the appended-declaration-lost class (regex) and the
  bookkeeping-not-re-run class (field) are two classes or one seen twice.
  Unknown until both are fixed; the pins hold the question open.
- Whether a source block may open on a subflow-definition line at all. Unruled,
  and the reading decides whether 115_017 is a parser gap or a missing negative
  wall. Under either reading its diagnostic is wrong: it reports a missing
  closing brace for balanced braces.
- Whether any library breaks on the boundary for a reason with no entry-file
  analogue at all — the remaining mirrors decide this, and a further fault class
  would weaken the single-surface remedy again.

Related: `frag-milestone-suites-are-instruments` (the gallery split is what
surfaced this hole, then dropped off the work list exactly as that belief
predicts), `frag-two-mechanisms-mark-a-transform`,
`frag-proc-body-module-scope-spelling` (the same shape one layer down: a lib
reaching an emitter internal, silent until the internal moved).
