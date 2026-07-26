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

## Invasiveness does not predict exposure; minting a name does

The intuition that a transform which rewrites more is more likely to break the
boundary is wrong, and it was wrong twice in a row about the same transform.
`std/taps:tap` walks the entire program, wraps the continuations of every
matching transition, and then erases its own declaration — nothing else on the
wall reaches that far — and it relocates green. Meanwhile `std/kernel:init`,
which appends one init tor and calls it, fails.

The line is not how much a transform rewrites. It is whether it MINTS A NAME
that something else has to resolve later. Rewriting in place, however sweeping,
carries no name across a boundary; appending a declaration and referring to it
does. That is also why the site-local class relocates for free and why
`liquid_template:emit`, bare keyword and all, was never at risk.

## The failure that does not fail

Every red on this wall is a compile error except one. `std/runtime:register`
declares a priced scope inside a module; the program then COMPILES, RUNS, and
takes its `| scope-not-found` branch instead of `| exhausted`. No diagnostic, no
crash — a different answer, delivered confidently, through a branch the author
legitimately declared.

That is the failure mode the whole no-fallbacks law exists to hate, arriving
from a direction nobody was watching: not a swallowed exception or a placeholder
value, but a comptime registry that came up empty and a well-formed program
built on the emptiness. A transform whose synthesized name is resolved at RUN
time rather than at emission has no compile step left to fail in.

It also sets the bar for the wall itself. A mirror that only asserted "compiles
clean" would have called this one green. Relocation tests have to assert OUTPUT,
and the pins carrying MUST_RUN without an expected.txt (115_031, 115_032,
115_034, 115_037) are weaker for exactly this reason — they inherit that
convention from the originals, and they would not catch this.

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
body met a parser refusal that had nothing to do with the boundary, because the
subflow-DEFINITION path stitched only `|>` lines onto the head and left a block
that opened there unterminated. Ruled legal and fixed (210_168). A `|>` tail
after such a block is still dropped in silence — 210_169, entry file, no module
involved.

That gap was worth more than the mirror that found it: it blocked writing the
kernel:self mirror at all, so the boundary question for the shape that library
is actually written for could not be asked until the parser moved.

So every red on this wall needs its entry-file twin before it counts as a module
finding. That is not wall bureaucracy — it is the difference between a fault
list and a list of things that happened to be red at the same time.

## std/store is not the fixed exemplar it reads as

690_079 is green and it is easy to read that as "store crossed the boundary."
What crossed is the SCALAR path: declare, write, read, all singular, all within
one module. The 115 store mirrors take the rest of the library across and it
does not follow — plural inserts mint `lib:__store_insert_*` in the file domain,
and `watch` cannot find a module-declared store AT ALL, on a declaration
structurally identical to the one 690_079 proves works.

So a library is not "module-safe"; individual paths through it are. And the
path is not the transform either — std/kernel's pairwise, self and step all fail
identically at `init`, their own expansions never reached, while std/field's two
transforms fail in two different ways. What a red indicts is the FIRST
synthesized name the chain touches, which may belong to a transform the author
did not invoke.

That cuts both ways on counting. An inventory by library reads as more finished
than it is; an inventory by transform overstates the remaining work, because
several arms often die at one gate. Neither number is the number of bugs.

## Open

- Whether the appended-declaration-lost class (regex) and the
  bookkeeping-not-re-run class (field) are two classes or one seen twice.
  Unknown until both are fixed; the pins hold the question open.
- Why a `|>` tail after a multi-line source block on a definition line is
  dropped without a diagnostic (210_169). Silent truncation of a written step is
  worse than the refusal it replaced.
- Whether any library breaks on the boundary for a reason with no entry-file
  analogue at all — the remaining mirrors decide this, and a further fault class
  would weaken the single-surface remedy again.

Related: `frag-milestone-suites-are-instruments` (the gallery split is what
surfaced this hole, then dropped off the work list exactly as that belief
predicts), `frag-two-mechanisms-mark-a-transform`,
`frag-proc-body-module-scope-spelling` (the same shape one layer down: a lib
reaching an emitter internal, silent until the internal moved).
