---
type: belief
id: frag-a-fix-that-moves-a-failure-is-not-thereby-pinned
provenance: 2026-08-09 — unified six emitter sites onto one spelling for kebab branch names, watched a real orisha error disappear, wrote a minimal test to hold it, and only on reverting the change discovered the test passes either way. Three shapes tried; none distinguish
ts: 2026-08-09
---

# A fix that moves a real failure is not thereby pinned, and the test you write to hold it is a hypothesis

Two facts feel like one and are not:

1. **The change removed a real error.** Watched, in a real consumer, before and
   after. This is strong evidence the change is doing something.
2. **A test now covers it.** This is a claim about the test, and nothing about
   fact 1 establishes it.

The gap between them is invisible from the passing side, because the test is
green and the error is gone and both of those are true. What the test cannot
tell you, by construction, is whether it would have been red before — that
question has exactly one answer and it costs a revert and a rebuild.

**What happened.** Kebab branch names had two Zig spellings — mangled in one
emitter, escaped in five others — and unifying them made an orisha compile error
disappear. A minimal test was written for it: a library declaring
`| parse-error`, a consumer switching on it across a module boundary. Green.
Reverting the compiler change and rebuilding: **still green.** Two further
shapes — nested under a subflow arm, and as an event implementation body — also
green both ways. Whatever reaches the escaped spelling is on the
transform-generated path, which none of the three touch.

Without the revert, that test would have shipped as the fix's pin, the comment
in the source would have cited it, and the first person to break the unification
would have been told by a green test that nothing was wrong.

**The rule, mechanically:** a test claimed as the pin for a fix must be run
against the code WITHOUT the fix, and observed to fail. Not reasoned about —
run. If that costs a rebuild, it costs a rebuild; it is the only step that
distinguishes a pin from a coincidence.

**And when it will not go red, say so in the test.** Deleting it is wrong — it
is a real positive case and worth keeping — but leaving its header claiming to
hold a defect it does not hold converts an honest gap into a false assurance.
020_062 carries that admission in its own first paragraph.

Sibling to [[frag-a-test-can-be-load-bearing-by-accident]], which is the same
seam from the other side: there a test's teeth came from something nobody
intended, here a test has no teeth and nothing said so. Both are only visible
by changing the code underneath and watching what the test does.

**What would correct this:** a harness that runs a named test against the parent
commit's compiler automatically when a fix declares it as its pin. Then the
revert is not a discipline anyone can skip, and this fragment describes a hazard
the machine has absorbed.
