---
type: belief
id: frag-a-hardcoded-value-disguises-a-collector-that-finds-nothing
provenance: Lars, 2026-07-31 — "running `koruc deps` in downloads only lists zig"
ts: 2026-07-31
---

# A hardcoded value does not merely give the wrong answer — it removes the surface's ability to look broken (belief)

`koruc downloads.k deps` reported one dependency for a program that links
libcurl. The cause was a collector walking `program.items`, which is only the
entry file, so every declaration made by an imported library was unreachable.

That bug is ordinary. What made it survive is not.

`std/deps` seeds its list with a hardcoded `zig` entry before the scan runs. So
the command printed a plausible, correct-looking dependency report on every
project on the machine. The scan behind it was returning **zero results** the
entire time, and there was no project anywhere that would have made that visible,
because every project got the same one line whether the scan worked or not.

The project already bans hardcoding a value standing in for a computed one. This
is the sharpest reason why, and it is not the one usually given. The stated harm
is that the demo lies about the machine behind it. The larger harm is
**diagnostic**: a hardcoded floor under a computed result destroys the empty
case, and the empty case is the only cheap signal that a collector is broken. A
scan that finds nothing is loud. A scan that finds nothing behind a seeded value
is indistinguishable from a scan that works.

## The pairing that makes it lethal

Alone it would still have been caught eventually. It lasted because it was paired
with a test that could not fail: `310_047` ran `koruc input.kz deps || true` and
then unconditionally echoed "Test passed". Green for the whole life of the bug,
and green if the command had printed nothing at all.

So the two failure modes compose exactly:

- the hardcode removed the signal a human would have noticed
- the vacuous test removed the signal the suite would have noticed

Neither is remarkable on its own. Together they make a broken surface
*unfalsifiable* — there was no observation, manual or automated, that the working
and broken versions would have distinguished. That is the state to fear, and it
is reachable by two individually-minor lapses.

Sibling of [[frag-a-check-that-cannot-match-reports-clean]] and of
[[frag-a-transforms-filesystem-anchor-is-the-compilation-root]], where a green
test also passed for a reason unrelated to what it claimed to guard. The common
shape across all three: **ask what observation would differ if this were broken.**
If the answer is "none", it is not tested, however green it is.

## Open

The seeded `zig` entry is kept, now deduped against `koru_std/compiler.kz`'s real
declaration, because "the toolchain requires zig" is true independent of what any
program declares. That is defensible as a designed default rather than a
stand-in — but the line between the two is exactly where this bug lived, and the
honest test is whether the value would still be correct if every collector
returned nothing. Here it would. Elsewhere that answer should be checked rather
than assumed.
