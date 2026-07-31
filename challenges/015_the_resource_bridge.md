---
challenge: resource-bridge
kind: frame
status: standing
yields: an honest account of what cross-session resource safety already does, and the smallest real thing built on top of it
family: runtime
---

*Walker context — the recurrence that earned this frame. Buried in a parked
subsystem, at 147 lines, sits `koru_std/bridge.kz`. Its header calls the idea
**"Hollywood OS mode"**. Its second test calls the pattern this:*

> *"state persists across turns, human or AI can act on resources created in
> previous turns."*

*A resource obligation that survives a turn boundary is the shape an agent needs:
the AI opens something on turn 3, the human closes it on turn 9, and the compiler
still knows. `440_002` claims exactly that — open in session 1, discharge in
session 2.*

## ⛔ It does not work. Measured 2026-07-31, before you start.

*`440_RESOURCE_BRIDGE` is 2 tests and the board reports both green.* ***Both print
`FAIL` when you run them.***

```
440_001_bridge_basic              actual.txt:  FAIL: dispatch_error
440_002_cross_session_discharge   actual.txt:  FAIL: session 1 dispatch_error
```

*Reproduced by hand with the shipped `koruc` — session 1 does not even reach
session 2.* ***Cross-session discharge is not a beachhead. It is broken or
unimplemented, and nothing said so.***

*The mechanism: the harness compares `expected.txt` (`regression_lib.sh:1490`).
Both tests carry* ***`expected_output.txt`*** *— a filename the harness never
reads. A `MUST_RUN` test with no readable expectation* ***asserts nothing*** *and
passes if the program exits 0. There is a wall for the inverse case — expected
output with no `MUST_RUN` is a `config-error` at `regression_lib.sh:581` — and*
***no wall for this direction.***

*Corpus-wide:* ***29 tests*** *carry `expected_output.txt` with no `expected.txt`
and no `expected_patterns.txt`.* ***4 are green while their own captured output
contradicts what they claim to expect*** *— the two bridge tests,
`220_005_cross_module_type_nullable` (expects `done`, produces nothing), and
`321_nested_recursive_label`, whose "expected output" is a placeholder comment
stating that the test fails at codegen.*

*So this frame changes shape. It is no longer "build on a working seam." It is*
***find out whether the seam ever worked*** *— and the first question is
archaeology: did cross-session discharge ever run, or has it been
green-and-broken since `d7e2eae9` ("440_RESOURCE_BRIDGE goes green") landed on
2026-07-25, a claim the board had no way to check?*

---

## The brief (sealed — you are the contestant)

Establish **exactly what already works** at this seam, and then build the
**smallest thing that could not exist without it.**

Not a shell. Not a REPL. The smallest artifact that demonstrates a resource
obligation crossing a session boundary and being enforced — and, just as
importantly, an artifact that demonstrates the enforcement **failing loudly** when
the obligation is dropped.

## Ground yourself FIRST

**Start at `dispatch_error`.** Both tests reach it and stop, and session 1 never
reaches session 2. `~std/runtime:register(scope: "files") { open(10) close(1) }`
declares the scope; the run then fails to dispatch into it. The seam is failing
at its first joint. Until that is understood, everything else here is
speculation.

**Then read the emitted Zig, never the verdict.** The verdict has been wrong
since at least 2026-07-25.

**Then answer the archaeology question:** did this ever work? `d7e2eae9` claims
"440_RESOURCE_BRIDGE goes green" — check whether the program's *output* was ever
right, or whether only the marker was. `git log -p` on the two test directories
and on `koru_std/bridge.kz` is the fastest route.

**Read `koru_std/bridge.kz` in full.** It is 147 lines. It claims:

```
- Bridge holds a HandlePool with persistent allocation
- Multiple interpreter runs share the same bridge
- Per-handle locking for concurrent access
- No return values from runs — side effects accumulate on bridge
- Session end triggers discharge_all
```

**Verify each of those five claims against a test that runs.** Per-handle locking
and `discharge_all` in particular have no test in `440_` at all — two tests cannot
cover five claims. Anything unbacked is a **documentation claim, not a feature**,
and saying so is a finding.

**Note what the tests are made of.** Both reach directly into Zig:

```
const HandlePool = @import("root").koru_std.koru_interpreter.HandlePool;
var bridge_pool = HandlePool.init(std.heap.page_allocator);
```

The mechanism is real; the **Koru surface over it does not exist**. A user cannot
spell "give me a bridge" in Koru today — they hand-write a Zig pointer and pass
it as an argument to `std/runtime:run`. That is a library-boundary Zig leak of
exactly the kind `baton_library_boundary_zig_leaks_commission` describes, and it
is probably the highest-value thing to close here.

**Respect the park.** `project_runtime_interpreter_parked` covers
`std/runtime:run` and the interpreter family. This frame touches the same code.
So: **440 and the bridge surface are in scope; the 430/410 bug family is not.**
If a bridge finding requires fixing an interpreter bug, write it down and stop —
that belongs to challenge `014`, which is a survey, not a fix.

## The questions worth answering — once it runs at all

⚠️ These were the frame's original questions, written when the two tests were
believed green. **The 2026-07-31 probe could not reach any of them** — session 1
fails before session 2 is entered. They stay here because they are the right
questions the moment `dispatch_error` is understood, and because question 3 may
turn out to explain the whole thing.

Cross-session discharge is interesting only if it is **enforced**. So:

1. What happens today when session 2 **never** discharges the handle? Is it
   caught at session end, at process exit, or not at all?
2. Is the obligation checked by the **phantom checker** — the real one, the same
   machinery that refuses `2104_05` — or by a runtime handle count that merely
   resembles it?
3. Can a session **discharge something it never opened**? `440_002` passes a
   string literal `"file_1"` as the handle in session 2. If any string works,
   the identity is nominal and the guarantee is thinner than it reads.

Question 3 is the sharp one. **Test it before you build anything.** If forging a
handle works, that is the finding, it outranks every feature idea in this file,
and it should be pinned as a red `MUST_ERROR` with a named diagnostic the same
day.

## ⚖️ What this is not

**It is not a shell yet, and you should not build one.** "Hollywood OS" is a
sketch in a file header, not a ruled design. A REPL, a session protocol, a
command surface — every one of those needs spellings, and **syntax is Lars's**.

What you may build without a ruling: a **test**, a **wall**, a **measurement**, or
a **worked example** using only spellings that already pass in the suite. That is
a wide space. Use it.

If the work makes a spelling necessary — and it probably will, around naming a
bridge or scoping a session — that is the frame succeeding. Bring the question
with the evidence that raised it.

## The pre-garden

- **Two tests, five claims.** Enumerate which of `bridge.kz`'s promises are
  actually pinned. Every unpinned one is either a test to write or a claim to
  delete. Both are landable today.
- **Is `440` in the right place?** It sits under `400_RUNTIME_FEATURES` alongside
  parked subsystems, which is why nobody has looked at it. If cross-session
  resource safety is a first-class idea, its tests are filed where first-class
  ideas go.
- **Do the two tests pin behaviour or internals?** They construct a `HandlePool`
  by hand. A test that cannot survive the Koru surface being added is a test that
  will block the surface being added.
- **`EXPECT` is empty in both.** Check how they are actually asserting — via
  `expected.txt`, `post.sh`, or stdout comparison — and whether the assertion
  distinguishes "the handle was discharged" from "the program didn't crash."

## What "done" looks like

- The five claims, each marked backed / unbacked, with the test that decides it.
- Answers to the three enforcement questions, demonstrated by programs that ran.
- If handles can be forged: a red pin with a named diagnostic, and the fix if it
  is small.
- The tests that were missing, written — particularly `discharge_all` at session
  end and the negative case where session 2 never discharges.
- **One worked artifact** showing an obligation crossing a session boundary and
  being enforced, using only existing spellings.
- A short written account of what a Koru shell would need that does not exist —
  as questions for Lars, not as a design.

## Failure modes

- **Building a REPL.** Not the brief, and it needs rulings you do not have.
- **Taking the header's five claims as features.** Two tests, five claims.
- **Wandering into the 430 bug family.** Parked; that is challenge `014`.
- **Treating green as proof.** `440_002` passes. Whether it passes *for the right
  reason* is the actual question, and question 3 is how you find out.
