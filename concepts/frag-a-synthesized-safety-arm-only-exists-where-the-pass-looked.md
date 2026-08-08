---
type: belief
id: frag-a-synthesized-safety-arm-only-exists-where-the-pass-looked
provenance: 355_012 — a declined `?!` panic branch inside an arm gets no synthesized arm and no dispatch guard, on BOTH lanes; found via a shipped consumer's row removal
ts: 2026-08-08
---

# A synthesized safety arm exists only where the pass that synthesizes it looked (belief)

`| ?!` means "unsafe to ignore". A consumer may decline to write the arm, and
the compiler synthesizes a loud one in its place so the path cannot silently
proceed — the deliberate contrast with plain `| ?`, whose unhandled case is a
documented no-op (pinned at 355_009).

The synthesis reads **one flow's own continuations** and never descends into
them. So the guarantee holds at the top level of a flow and evaporates for any
invocation nested inside an arm — which is where consumers actually write
calls. Both lanes are affected; this is not a lane divergence.

**What it looks like when it fires** is the reason it survived. With no
synthesized arm the terminal count stays at one, and both emitters take their
"a lone branch always fires, so no guard is needed" path. The written arm's
body then runs against whatever the callee actually returned. On the Zig lane
the program ran to completion, exit 0, printing its final line. On the
JavaScript lane it failed with a type error — but only because that particular
body dereferenced the payload. A body that merely *binds* it is silent there
too, and that is exactly the shape a shipped consumer had: the DOM app's row
removal bound the payload and carried on, undetected.

**The belief, stated generally.** A pass that installs a safety net installs it
at the positions it visits, and the net's absence is invisible everywhere else —
because absence of a synthesized arm is indistinguishable from a callee that
genuinely has one outcome. Downstream, the emitters cannot tell those apart and
correctly optimize the guard away. So the failure is not "the pass forgot"; it
is "the pass's blind spot became an optimization opportunity for something
else". Any pass whose output is *the absence of code* needs its coverage pinned
at every position, not at one.

**The asymmetry worth remembering:** the harm is bounded by whether the arm's
body happens to touch the payload. That makes the bug's visibility a property
of the *consumer's* code rather than of the defect, which is why one lane
looked broken and the other looked fine while both were equally wrong.

**Open.** The fix is to descend — synthesize for every invocation reachable
through continuations, not just a flow's head. Not yet built; 355_012 is red
and pins the shape. Whether the same blind spot affects the other things this
pass installs (auto-discharge of obligations inside nested arms, the
`~[prototype]` hole arms) is unmeasured and is the first thing to check.

Relates to [[frag-a-fix-lands-in-one-lowering-path]] and
[[frag-two-lowerings-share-one-contract]] — same family, different axis. Those
are about one construct lowered two ways; this is about one construct at two
POSITIONS, and it is worse in one respect: a lowering that is missing produces
a compile error eventually, while a safety arm that is missing produces a
program that runs.
