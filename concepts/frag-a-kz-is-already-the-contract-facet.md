---
type: belief
id: frag-a-kz-is-already-the-contract-facet
provenance: std/string JS port — the port was budgeted as "extract koru_std/string.k, then write koru_std/string.kjs"; adding the .kjs alone against an untouched string.kz took 0/55 to 32/55 and the extraction was never performed
ts: 2026-08-06
---

# A `.kz` is already the contract facet — the `.k` extraction is not owed

The JavaScript-target plan carried a prerequisite in front of every runtime
stdlib port: a `koru_std/<mod>.kz` must first be **split** into a pure `.k`
contract plus a `.kz` holding only the Zig bodies, because only then could a
`.kjs` sibling supply JavaScript ones. It was stated as a hard dependency, not
a preference — the frontier map prints it in its own legend, and it is the
reason the runtime half of the surface was sized as the expensive half.

It is not a dependency. `koru_std/string.kjs` was added beside a
**byte-for-byte untouched** `string.kz` and every one of the module's twelve
procs lowered. The mechanism was never in doubt once looked at: facet merge
is by *stem*, and `~pub tor` declarations are host-agnostic wherever they are
written. A `.kz` is "Koru with Zig bodies" — the Koru part of it is already
the contract, and it is visible to a `.kjs` sibling for exactly the same
reason it is visible to the `.kz`'s own procs.

`koru_std/args` is the three-file split (`args.k` + `args.kz` + `args.kjs`)
and was read as the pattern a port must follow. It is a pattern a port *may*
follow. Nothing in it is load-bearing for the JS side.

Two things follow, and the second is the reason this is worth a fragment.

**The cheap shape is also the honest one.** An untouched `.kz` is the
strongest available evidence that a port left the Zig target alone: there is
no diff to audit. Extraction moves every event declaration in a module across
a file boundary — a large, reviewable-only-by-eye change to shared code that
the Zig backend compiles, undertaken to enable something that was already
enabled. The prerequisite made the *riskier* layout mandatory.

**The prerequisite was inherited, not measured.** It survived one round of
correction already: `std/store` escaped it on the grounds that transform
bodies stay in `.kz`, which quietly conceded the general claim for everything
else. Nobody ran the one-file experiment that refutes it, because the claim
had a plausible mechanism attached — separate host languages, separate files
— and a plausible mechanism reads as evidence. **A prerequisite is a claim
about the system and decays like any other; the cost of testing one is
usually a single file, and it was here.**

Open: whether `args`'s three-file split should be collapsed back to two. It
costs nothing to leave, and the extraction is a legal layout — but as long as
it stands as the only stdlib example, the next reader will infer the
prerequisite from it again.
