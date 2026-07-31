---
type: belief
id: frag-a-test-can-be-load-bearing-by-accident
provenance: 395_010, 2026-07-31 — its only assertion was an unguarded union read that panicked on the wrong branch; making that read safe removed the test's teeth and it still reported 2/2 passed
ts: 2026-07-31
---

# A test can be load-bearing by accident, and hardening the code beneath it is what disarms it (belief)

`395_010_unexpected_branch_fails` pins something worth pinning: when a mock
returns a branch the test does not handle, the test must **fail**, not silently
pass. It had been green for a long time.

Nobody had written its assertion.

The emitted test body contained an **unguarded union read** — `const result =
result_0.ok;`. A mock returning `.error_result` therefore *panicked*, `zig test`
exited non-zero, and the test's `post.sh` passed precisely because of that
non-zero exit. **The crash was the assertion.** It was an artifact of how the
emitter happened to lower a head-position branch read, not a mechanism anyone
chose.

Then an ordinary, correct-looking improvement landed: passing the callee path at
head sites so `callee_bare_return` could compute. That woke a tag guard, which
rewrote the read as `if (result_0 == .ok) { ... }` — safer code by any normal
standard. The panic became a silent no-op, and the harness reported **2/2 tests
passed over an unexpected branch**.

The test did not go red in a way that named the problem. It went red on
`post-validation` while its own log cheerfully said everything passed.

## Why this is not the same as a test that asserts nothing

The `expected_output.txt` family — tests whose assertion file the harness never
reads — never guarded anything. The absence is total and, once you know to look,
mechanically detectable: no readable expectation, no guard.

This is the inverse and it is harder. **The assertion was real and it worked.**
It would have caught the regression it was written for. It just wasn't *written*
— it was emergent from an implementation detail one layer down, and nothing
recorded the dependency. No comment, no pin, no name.

So the usual audit question ("does this test assert something?") returns **yes**,
correctly, and tells you nothing about whether the assertion survives the next
refactor of the layer beneath it.

## The rule

**A passing negative test is not evidence that anything intentional is guarding.
It is evidence that *something* currently fails.** Those are different claims,
and only the first survives a change to the implementation.

Two practical consequences:

- When a negative test passes, ask **what specifically makes it fail** and
  whether that mechanism is the one the test names. If the test says "unexpected
  branch" and the mechanism is "a panic on an unguarded union read," the test is
  riding a coincidence.
- **Hardening is the dangerous direction.** Making code safer, more guarded, more
  total is exactly the change that removes an accidental wall — and it arrives
  looking like an improvement, which is why it gets waved through. The change
  that broke this was correct on its own terms and I would approve it again.

## Open

- No way to detect this class in bulk. You cannot grep for "this green depends on
  a crash." The only handle found so far is the one that worked here: a full
  board after every merge, and taking a single unexplained flip seriously enough
  to stop and read its log.
- Related but distinct: [[frag-a-misnamed-assertion-is-silently-no-assertion]]
  (the assertion was never read) and
  [[frag-a-wall-guards-one-direction-of-a-symmetry]] (the rule was enforced one
  way). This is a third species — the assertion exists, works, and is unowned.
