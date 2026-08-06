---
type: belief
id: frag-a-kjs-facet-carries-host-lines-not-only-proc-bodies
provenance: W4 host-fixture porting — the wave brief prohibited host lines in a .kjs on the grounds that the Zig emitter emits them unconditionally; the guard that makes that false is `hostLineRoutesToZig`, and 140_010 is the test that pins it. Evolved during the std/string port, where the same completeness claim turned out to hold only at the scope it had been checked at.
ts: 2026-08-06
---

# A `.kjs` facet is complete — host lines included, not proc bodies alone

The host-fixture wave went out with a prohibition at the top of every brief:
a `.kjs` may contain only `~proc NAME|js { … }` blocks and comments, because
the Zig emitter emits every host line of a selected module unconditionally
and a JavaScript host line would therefore leak into emitted Zig and break
the Zig target. The prescribed workaround was to hoist module state onto
`globalThis` and initialise it lazily inside a proc body.

The prohibition describes a bug that has already been fixed.
`hostLineRoutesToZig` (`src/visitor_emitter.zig:35`) resolves a host line's
language from its file extension and drops it unless it is Zig; the guard is
applied at *both* emission sites, `:1072` and `:3972` — including the "emit
ALL its contents" loop the prohibition was reasoning from. A `null` host (a
synthesized line, or a pure `.k` contract) still passes, as it must, because
host-agnostic compiler infrastructure has no extension to route on.

Verified against the artifact rather than the source:
`020_005_void_event_chained`, given an `input.kjs` opening with three bare
`let` declarations, compiled for the default target, produces an
`output_emitted.zig` containing no JavaScript and an executable whose output
is byte-identical to `expected.txt`.

The belief worth keeping is the general one: **a facet is a whole translation
of a module for one host, not a patch of function bodies over a shared
skeleton.** Module state is part of what a host implementation *is* — a
counter is as much the JavaScript facet's business as the procedure that
increments it. The corpus already said so;
`140_010_cross_target_host_line_routing` exists for no other purpose, and
both pre-existing corpus `.kjs` files open with a module-level `let`. The
brief invented a restriction the tree had already refuted, and it propagated
because it was stated with an emitter line number attached, which reads as
evidence.

Second-order, and the more expensive lesson: **a cited line number is not a
verified claim.** The number was real and the code near it did once emit
unconditionally; what had changed was a guard the reader did not reach. The
constraint came from a design note dated two months earlier that described
the asymmetry as latent — a document is a claim about the repo with a date on
it, and its provenance decays exactly like the code it describes. A
constraint expensive enough to distort six agents' output is worth the sixty
seconds of compiling one fixture and grepping the result.

Open question: whether the three-file layout (`input.k` contract + `.kz` +
`.kjs`) and the two-file layout used here (`input.kz` as both contract and
Zig facet, `.kjs` as companion) should both stay legal. The two-file form is
what makes an untouched `input.kz` possible, and an untouched `input.kz` is
the cleanest available evidence that a port left the Zig board alone — so it
earns its place for migration work, whatever the eventual resting shape.

## The claim was checked at one scope and asserted at both

Porting `koru_std/string` found the completeness above true for the ENTRY
file and **silently false for an IMPORT**. A `.kjs` host line in the file you
hand `koruc` reached the output; the identical line in a stdlib module the
program imported did not, because an import arrives as a `module_decl` and
the JS emitter's host-line phase only ever scanned the top level. Nothing
failed. The declaration simply was not there, and the first thing to read it
got `undefined` several frames away — the failure shape this corpus already
has a name for.

The correction is one recursion and is now in the emitter, so it is not the
durable part. The durable part is the *shape of the mistake*: a facet's
completeness was verified on the cheapest available instance — a single-file
fixture, where "the facet" and "the program" are the same items array — and
then stated as a property of facets. **Entry and import are different scopes
for every phase the emitter has**, and a claim about what a facet may contain
is a claim about both. Neither the prohibition this fragment repudiated nor
the repudiation itself distinguished them.

That generalises past host lines: any "a facet may carry X" ruling wants
checking through an import before it is written down, because the entry path
is the one every author exercises by accident and the import path is the one
the stdlib lives on.
