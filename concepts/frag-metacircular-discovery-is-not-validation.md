---
type: belief
id: frag-metacircular-discovery-is-not-validation
provenance: surfaced 2026-07-24 while probing auto-discharge with a flag that does not exist; pinned red as 903_unknown_flag_rejected
ts: 2026-07-24
---

# A metacircular DISCOVERY surface does not validate anything (belief)

`--help` is metacircular: it reads `flag.declare` entries out of the imported AST
rather than a hardcoded list, so a flag declared beside its own pass documents
itself. We treated that as "flags are handled." It is only half the loop.

**Discovery reads the registry; acceptance never consults it.** The arg parser
strips dashes off any token it does not recognise and installs it as a live
backend flag. So the compiler will happily tell you the truth about the flags
that exist, and will also accept one that does not, do nothing, and exit 0 —
which reads as the flag having worked. `903_unknown_flag_rejected` pins it.

The generalisation is the point, and it is not about flags: **any surface that
is metacircular for documentation and hardcoded for enforcement has two halves
that can disagree, and users only ever hit the enforcing half.** A registry that
exists to be *listed* proves nothing about what is *accepted*. Wherever we build
a self-describing surface, the question to ask immediately is which code path
rejects the things it does not describe — and if the answer is "none", the
self-description is a documentation feature wearing a validation costume.

This is a [[frag-no-fallbacks]] shape with the concealment moved one level out.
Nothing is swallowing an error, because no error is ever produced: the silent
absorb IS the substitute output, and it is indistinguishable from success.

## Why the fix is a sweep, not a patch

Adding the wall is small — diff the unknown-flag bucket against
`collectFlagDeclarations` post-parse (it must be post-parse; arg parsing runs
before there is an AST, and it matches whole tokens, since a declared name
embeds its value). The COST is that every flag currently reaching the backend
undeclared starts erroring the day the wall goes up. That population is unknown
until measured, and measuring it is the actual work — the same shape as any
enforcement that was never on: turning it on is a corpus migration, not a patch.
