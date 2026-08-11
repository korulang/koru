---
type: belief
id: frag-a-transforms-filesystem-anchor-is-the-compilation-root
provenance: found 2026-07-29 building std/vendor, after a hand probe passed and the harness failed
ts: 2026-07-29
---

# A comptime transform that touches the filesystem must anchor on the compilation root, not on `flow.location.file` (belief)

A `[transform]` proc runs inside the **backend**, which `koruc` spawns with
`cwd = dirname(output)` (`src/main.zig:8307`). Every relative path the transform
opens resolves against that directory.

`flow.location.file` is a different thing: the path as the *user* typed it,
relative to wherever they invoked `koruc` from. The two agree in exactly one
case — compiling a file from the directory that file lives in — and that is the
case anyone reaches for when probing by hand.

So `dirname(flow.location.file)` is not a location. It is a coincidence that
holds under the most convenient way to test.

## Why this one is hard to catch

Building `std/vendor`, the anchor was derived from the declaring file, and a full
hand probe went green end to end: `vendor sync` wrote the lock, a clean compile
passed, tampering with a vendored file produced the refusal with the right
filename, exit 1, no binary. Every observable behaviour was correct because the
probe ran `koruc input.kz` from the probe directory.

Under the harness, `koruc` is invoked from the repo root with a long relative
path. The anchor became `tests/regression/…/130_004…/` *resolved against the test
directory* — a path that does not exist. Nothing crashed. `readLock` got
`FileNotFound`, which is a legitimate state meaning "never pinned", and reported
it faithfully.

## The part worth remembering

It produced a **lying test**. `130_005_vendor_unpinned_refused` pins the refusal
for a program with no `vendor.lock`. It passed while the anchor was broken —
because an unreachable lock path and a genuinely absent lock are the *same
observation*. A green test was asserting the behaviour it guards was working,
and it was not.

The general shape: when a lookup's failure mode is indistinguishable from a
legitimate state the code already handles, a wrong path does not fail, it
*reports*. Tests over the reporting path go green on a broken lookup. This is a
sibling of [[frag-a-check-that-cannot-match-reports-clean]] — there the check
could never fire; here it fired for the wrong reason.

What separates them is that only the harness varies the invocation directory. A
hand probe cannot see this class of bug at all, so "I probed it end to end and
it worked" carries no information about it.

## Open

`std/vendor` resolves this by anchoring on `"."` and treating the lock as
one-per-program at the compilation root — which is independently the right shape,
since a per-file lock would let two files pin the same vendored tree to two
different hashes with neither being wrong. Whether a transform ever legitimately
needs a path relative to its *declaring* file — a module in a subdirectory
declaring its own bindings — is unsettled, and would need the compilation root
passed in rather than inferred from CWD.
