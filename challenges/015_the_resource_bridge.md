---
challenge: resource-bridge
kind: frame
status: held
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

## ⛔ HELD (Lars, 2026-07-31) — do not commission this frame yet

*"Let's just WAIT with the bridge. Anything to get us closer to it."*

**Held, not parked.** The difference matters: work that moves toward it is
wanted, the frame itself is not to be fired. Two things already in flight move
toward it and should be understood as bridge work under another name:

- **`013` the store↔kernel seam** — the store is where a container owning
  obligations and discharging them by discovered type already works
  (`690_056`). The bridge is that, one lifetime domain up.
- **D7, "what names a row?"** — identical to the bridge's "what names a handle
  across turns." Finishing D7 hands the bridge its identity model rather than
  requiring a second one. Blocked on one spelling: how a key gets MARKED.

So the honest order is: **identity → real discharge → shell → wire**, and the
first two are reachable through the store without opening this frame at all.

⛔ Do not fire this as a commission. Do not design the shell. Do not touch
`std/bridge`. Two rulings are outstanding and both are Lars's — bridge-minted
versus type-minted hash, and whether the shell must be a *system* shell.

---

## ⭐ THE VISION, as Lars stated it 2026-07-31 — read this before the brief

The brief below was written thinking this was a session-storage feature. It is
not. **The point of the resource bridge is to kill the idea of an application.**

In the age of AI, an application — a bundle of UI, logic and resource lifetimes
shipped as one unit — has no reason to exist. What replaces it: **Koru as the
primary interface for driving system-level things, with the resources living on
a bridge**, picked up conversationally as the session moves on. Not
request/response. The reference model is **COM** — a uniform interface for
driving system objects — *except that COM's `AddRef`/`Release` was a discipline
you could violate, and `<!session>` is a refusal.* COM with the leak made
unspellable.

And because the resources sit on a bridge rather than inside a process, **Koru
can be passed over the wire from one instance to another carrying a reference to
the bridge** — which is how the work distributes. The resource never moves. The
code moves.

### The handle is a hashed capability, and it carries its own vocabulary

Lars's shape: `std/io:file.open` hands back a short hash — `542fab`. You pass
that on. **And you can ask it back what it affords** — `542fab`, "call
`std/io:file.read`".

Two things follow, and both matter:

- **A hash is unguessable, so possession of the name IS the authority.** That is
  what makes passing a bridge reference over a wire safe at all, and it is the
  same move as semi-stable node identity in the medium bed: replace a pointer
  with a name that survives transport. ⭐ It is also the answer to
  **D7 — "what names a row?"** The bridge's "what names a handle" and the store's
  "what names a row" are ONE question, and D7 is already half-ruled (declared
  keys, `pool[id: 7].hp`, *"the index it needs is a DECLARED cost"*). What is
  unruled there is how a key gets MARKED — a spelling, and Lars's.
- **The vocabulary is computable from the phantom state.** The tors that can act
  on `542fab` are exactly those accepting its current state; after `close` the
  vocabulary is empty. This is not new machinery — it is **discharger discovery**,
  which already works (`690_056` closes a still-live file at store teardown via a
  DISCOVERED discharger, resource-agnostic). It has simply never been exposed as
  a runtime question.

**The bridge is therefore the execution context**, not a store: it holds the
resources *and* the vocabulary, and the vocabulary narrows itself as obligations
discharge. A per-handle history falls out for free — the phantom transition log
IS the audit trail, which is what an agent resuming a session needs in order to
know what it already did.

### The runtime-typing tension, and why it does not force an interpreter

Lars: partial evaluation — the conversational part — *"literally NEEDS to store
the obligations and types fully at runtime."* True. But **typed at runtime is not
the same as interpreted**, and conflating them is what makes this look like it
costs systems-level speed.

- **The resource's state** — type, current phantom, outstanding obligations —
  must be live at runtime. Unavoidable.
- **The code acting on it** need not be. A fragment arriving at the bridge can be
  typechecked against a **manifest** and compiled to native.

That is a manifest, not an evaluator. Koru is well placed for it: the compiler is
metacircular, so it is already present wherever Koru is, and `--ccp` exists to
answer compiler questions to a non-human consumer.

And the cost lands correctly: **you pay per handle parked on the bridge, not per
value in the program.** Ten million values and three handles costs three — the
same "declared cost" bargain D7 already ruled, rather than an exception to it.

⚠️ Everything in this subsection past the `--ccp` check is design reasoning, not
measurement. No manifest exists and none has been built.

### ⛔ RULED 2026-07-31: metering is PARKED

Budget-metering was premature. **It only really makes sense on a public-facing
API, not on an internal resource bridge.** Park it.

This matters structurally, because metering was the one requirement that argued
for the interpreter as *architecture* rather than as fallback — you cannot cheaply
meter native code. With metering parked, the interpreter's honest remaining role
is the fallback for when there is no toolchain at the far end.

⛔ Do not design metering into this. Do not treat `410_BUDGETED_INTERPRETER` as
in scope.

### Open, and Lars's to rule

- Is the hash minted by the **bridge** (one namespace, easy revocation) or by the
  **resource's own type** (a name that means something without a bridge to ask —
  which matters the moment two bridges talk)?
- `shm` was floated for the co-located fast path. It solves *access*, not
  *permission* — the manifest is still what says a fragment may act. And for the
  remote case the resource should not move at all. So: is `shm` a same-machine
  optimisation, or load-bearing?
- **Does the shell need to be a *system* shell** — real processes, files,
  devices — or is a Koru-native shell over Koru-native resources enough to prove
  it? (Asked, not yet answered.)

### The test vehicle: a Koru-native shell

Lars's proposal, and it is on-thesis rather than merely convenient: **a shell is
already the thing everyone accepts is not an application.** It is the smallest
artifact with all three properties at once — persistent resources (cwd, env,
jobs, connections), turns, and a natural reason to act on something from three
turns ago.

⚖️ **It is a test only if it can fail in a way that teaches.** The failure it must
be able to produce on day one: *"I opened a file on turn 3, the session ended,
and nothing made me close it."* Today it would **pass while leaking** — see
`dischargeAll` below. The shell's first job is not to work; it is to make that
lie visible.

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

**`dischargeAll` is a stub, and it is the safety property.** `bridge.kz:51-60`:

```zig
// TODO: Call discharge events for all undischarged handles
std.debug.print("[BRIDGE] Auto-discharging handle: {s}\n", ...);
// Would call dispatcher here with discharge event
h.discharged = true;
```

It prints, sets a boolean, and **calls nothing**. The resource is never
released; the *counter* is satisfied. That is why `440_002` could report
handle counts going 1 → 0 while doing nothing at all. SCENE.md's promise is
*"obligations your compiler will not let you abandon"* — this is exactly the
line where that becomes false.

⭐ It has a working reference implementation one directory over: `690_056`,
where store teardown closes a still-live file via a **discovered** discharger,
resource-agnostic and honestly asserted. `dischargeAll` is that, unbuilt.

**`std/bridge` is imported by nothing.** Zero tests. The two `440` tests bypass
it entirely — they hand-roll `HandlePool.init` in raw Zig and never touch
`create` or `close`. So `*Bridge<session!>` — *"you cannot forget to hang up"*,
the most vision-load-bearing construct in the whole idea — **has never been
compiled.**

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
