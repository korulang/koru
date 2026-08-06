---
type: belief
id: frag-a-failure-that-looks-like-success-is-unfalsifiable
provenance: generalised 2026-07-31 after the same shape appeared four times in two sessions
ts: 2026-07-31
---

# The question to ask of any surface is "what observation would differ if this were broken" — and often the honest answer is none (belief)

Four separate defects across two sessions turned out to be one shape. In each,
the broken behaviour and the working behaviour produced **the same observation**,
so no amount of looking — by a person or by the suite — could have told them
apart.

- `koruc deps <module>` with the arguments swapped printed the toolchain's short
  green report and exited 0. `koruc deps` legitimately prints that report, so the
  version that discarded its argument looked identical to the version that had
  nothing to discard.
- `std/deps` seeded a hardcoded `zig` entry, so a collector returning zero
  results printed the same thing as a collector that worked
  ([[frag-a-hardcoded-value-disguises-a-collector-that-finds-nothing]]).
- `310_047` ran the command with `|| true` and echoed "Test passed". Green
  whether the command reported everything or nothing.
- `std/vendor` anchored on the wrong directory, and its unpinned-source test
  passed throughout — an unreachable lock path and a genuinely absent lock are
  the same observation
  ([[frag-a-transforms-filesystem-anchor-is-the-compilation-root]]).

The sharpest instance is the one found last, because there the surface does not
merely fail to reveal a problem — it **asserts the opposite**. `downloads.k` does
not compile; a plain build fails on KORU161 and produces nothing. Yet
`koruc downloads.k deps` printed `✓ Built executable: a.out` and exited 0. The
line was emitted whenever the backend exited cleanly, with no check that any
executable existed, so a command run — which legitimately never reaches Stage D —
reported a successful build of a broken program. Three untruths in one line: it
built nothing, the thing it named does not exist, and the program cannot build at
all.

## Why this is the useful frame

"Is it tested?" and "did I check it?" are both answerable yes while the property
is entirely unguarded. The sharper question is falsifiability:

> If this were broken, what would I see that I do not see now?

If the answer is "nothing", the thing is not verified, however green the board is
and however carefully the code was read. That question is cheap, it can be asked
of a test, a diagnostic, a probe, or a CLI surface, and it is the only one of
these that would have caught all four.

## It does not only hide bugs — it manufactures false beliefs

The harness printed `Running 0 tests... ✅ ALL TESTS PASSED` and exited 0 when a
filter matched nothing. Chasing that, I concluded the harness silently dropped
filtered runs of three or more tests, reported it as the highest-priority
toolchain defect, and repeated it across several messages.

It was not true. zsh does not word-split unquoted parameter expansions, so a list
in `$VAR` arrived as one filter matching nothing. The harness matched correctly.
The green verdict over zero tests was the only thing standing between me and that
explanation — had it said "no tests matched", the shell mistake would have been
obvious in seconds.

So the cost of an unfalsifiable success is not bounded by the bug it conceals. It
also produces confident wrong diagnoses in whoever reads it, which then get
reported, prioritised, and acted on. A surface that cannot look broken will
eventually make someone describe a defect that does not exist.

## Where the shape comes from

It is not carelessness — each individual decision was reasonable. It arises where
a surface has a **legitimate quiet state** that resembles its broken state:

- a report that is legitimately short
- a lookup whose "not found" is a real, handled condition
- a command that legitimately exits 0 having done little
- a default that is legitimately correct

Every one of those is a place where success and failure converge on the same
output. That convergence is what to design against — by making the quiet state
say *why* it is quiet ("no dependencies declared" rather than a bare list), and
by making tests assert content rather than exit status.

## The suite's own version of it

Noted the same week and unfixed: a filtered regression run naming three or more
tests silently matches zero and still prints `✅ ALL TESTS PASSED`. That is this
belief applied to the harness itself — the strongest possible instance, since it
makes every other check unfalsifiable at once. Worth treating as higher priority
than any single defect it might be hiding.

## The corpus's own version of it

Turned on this file's neighbours the question becomes an intake gate rather than a
design rule, and it catches a failure the membrane's other rules let straight
through. Intake bans *duplication* — a fragment restating code, a test, a count.
It says nothing about *platitude*, and a belief hedged until no observation could
contradict it satisfies every ban while carrying nothing.

So ask it of a fragment before writing one: what future observation would
`correct` this? No answer means it is not a belief, it is decoration. `correct` is
the verb this corpus exists for — the ledger of where code-as-spec was wrong — so a
fragment that can never be corrected is excluded from the corpus's own purpose
while passing every rule at the door.

The pressure runs one way, which is why this needs a gate and not merely a
mention. Hedging a claim makes it likelier to survive contact with the world, and
a claim that survives everything taught nothing by surviving. That is the trade
[[frag-a-red-pin-is-unfalsifiable-documentation]] names one level down: there an
explanation escapes checking because the test is red, here a belief escapes
checking because it asserts too little to ever be caught out. Both are prose in
something else's clothes, and the defence is procedural for the same reason — no
assertion can check whether a belief is capable of being wrong.

Surfaced 2026-08-04 from the opposite claim: a paper arguing the best hypothesis
is the *weakest* one consistent with the evidence. That is right for predicting
and inverted here, because a belief in this corpus is not kept in order to be
right. It is kept in order to be caught out.


## The nastiest instance yet: the artifact under test also SUPPLIES the assertions

Every case above has a fixed checker reading a variable subject. There is a worse
arrangement, found 2026-08-06 in the mock-testing corpus: the thing being tested
is the thing that *generates the assertions*, so a total failure of the subject
produces a checker with nothing to check — and a checker with nothing to check
reports success.

`395_002_mock_multiple_branches` and `395_009_cross_module_mock` each declare
several `assert(...)` calls inside `test(...)` bodies, and each validates by
running `zig test` over the emitted program. Both printed *"All 3 tests
passed"* for months. The blocks being passed were:

    test "Withdrawal succeeds when mocked" {
    }

Empty, both of them, in both tests — and the emitted artifacts contain **zero**
`assert` calls. The bodies were lost because a `test(...)` body is re-parsed
under a synthetic `.kz` filename where constructs need a `~`, and these are `.k`
files without one, so every line parsed as a host line and nothing was collected.

Note how completely the surface lied. The test COUNT was right. The test NAMES
were right, quoted from the source. The exit status was right. `zig test` was
telling the exact truth: it ran the tests it was given and none of them failed.
Every signal available to the harness was green, and the one thing that was wrong
— the bodies — is the one thing none of those signals mentions.

**The rule the earlier sections already imply, sharpened into something
checkable:** "assert content rather than exit status" is not enough when the
content is generated. Where a test's assertions are produced by the machinery
under test, the harness must also assert that assertions EXIST. Count them. An
emitted test block with an empty body is not a passing test, it is an absent one,
and the two are distinguishable by exactly one cheap grep that nobody was
running.

**Generalisation worth carrying, because this arrangement is more common than it
looks:** any generator whose output is then validated by a generic runner has
this hole — codegen validated by compiling the result, a migration validated by
running the schema, a config synthesiser validated by booting the service. In
every case "the runner was happy" is compatible with "the generator emitted
nothing". The invariant to add is always a floor on the output, never a check on
the runner's verdict: N blocks, N non-empty, M assertions present.

Both tests are now parked with `TODO` markers rather than fixed, because which
spelling is wrong — the tests' or the parser's dialect inheritance — is an
unmade ruling. The vacuous green is gone either way, which was the part that
could not be allowed to stand while the question waits.

## Porting a language target manufactures this shape wholesale

Every instance above is a surface that could have been built to complain and
wasn't. A second emitter for an existing language is worse than that: it has
**no site at which to complain about a construct it does not know exists.**

The JS emitter refuses loudly when it recognises something it cannot lower —
`NoJsProcBody`, `UnsupportedConstruct`, a panic with a line number. Those
gaps were found in minutes. Two others were found in an hour of blaming the
fixtures, because they were not refusals at all:

- Bind-position destructure (`~locate(): { pos: { x, y }, label } |> …`) was
  a field the emitter never read. It emitted the temp the parser had bound,
  then emitted a body referencing `x`, `y`, `label` — well-formed JavaScript
  that throws ReferenceError at run time, pointing at the fixture.
- An effect producer's terminal arm (`| done |> print.ln("done")`) was
  dropped by an inlining fast path that spliced the producer's `return`
  across a function boundary. That one did not even throw. The program ran,
  exited 0, and was simply missing a line of its own output.

The second is the sharper one, and it is not a bug in inlining. **A construct
the new emitter has no case for is not a construct it can reject** — an
unread AST field and an absent one are the same observation, and a `switch`
with an `else` that quietly does nothing is indistinguishable from correct
lowering right up until output goes missing. The refusals are the constructs
someone already thought about. The dangerous set is its complement, and it is
invisible by construction.

**The check this implies, for any second implementation of an existing
interface:** do not ask which constructs the new one rejects — that list is
self-reporting and therefore already handled. Ask which fields of the shared
IR the new one never reads. `grep` the new emitter for each field name the
old one consumes; every field with no hit is a silent gap with a fixture
waiting to be blamed for it. That is one cheap mechanical sweep, it is
available on day one, and it would have found both of these before a single
fixture was written.

The corollary for the humans in the loop is the expensive part. When a port
is in progress, a plausible-looking failure in NEW work is evidence about the
PORT at least as often as about the work — and the incentive runs the wrong
way, because rewriting your own fixture is the cheaper hypothesis to test.
Six agents were told to contort around a stale constraint in the same wave
(see
[[frag-a-kjs-facet-carries-host-lines-not-only-proc-bodies]]); the common
root is that the young side of a port is assumed correct because it is the
side nobody wants to be wrong.

**And the sweep above is not sufficient, which is the part worth carrying.**
It searches the new EMITTER, and the leak does not have to originate there.
A comptime transform that rewrites the AST before emission is host-blind
unless someone made it otherwise: `[expand]` splices a `~std/template:define`
body into the call site, and the registry is keyed by template NAME with no
host dimension at all. So a `.kz` template's Zig text lands inside an emitted
`.js` program, and no amount of auditing the JS emitter finds it — by the
time the emitter runs, the Zig is already AST and indistinguishable from
anything else it was handed.

The general form: **a stage that runs before target selection cannot be
audited by reading the target's backend.** Ask of every pre-emission
transform whether it carries host text, and if it does, whether its registry
has a host key. A mechanism keyed by name alone is not neutral across
targets; it is silently committed to whichever host wrote it first, and it
will report that commitment as a syntax error in the other target's output,
at a line number belonging to a file nobody edited.