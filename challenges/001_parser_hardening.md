# Challenge 001 — Parser / frontend hardening

> Find inputs where koru's **reality diverges from intent**: a program wrongly accepted,
> wrongly rejected, or handled correctly but with a bad error message. Each real divergence
> the arbiters confirm becomes a regression test (hardening the suite) and/or a toolchain fix
> (hardening the parser). Run it repeatedly — it is a flywheel.

This is a standing **generative frame**, not a backlog. There is no list of pending probes to
work down; each run re-derives fresh probes from the live parser and the language's stated
rules. The valuable *outputs* (tests, fixes) persist in the suite and the source — not a to-do.

---

## The faucet — how contestants generate signal

Three faucets, all draining into the same arbiter judgment. Prefer the first; it is the
generative engine.

1. **Adversarial prediction (primary).** Write a small Koru program you *believe* should
   either compile cleanly or be rejected with a *specific* diagnostic. State the prediction
   and the **WHY**, grounded in a stated rule (CLAUDE.md / AGENTS.md / docs / a *passing*
   regression test — cite file:line). Then run `./zig-out/bin/koruc` on it. The signal is the
   **divergence**: koruc accepted what you predicted it would reject, rejected what you
   predicted it would accept, or produced a different/worse error than predicted. A probe that
   matches your prediction is not a finding — it is a (useful) confirmation; report it briefly
   and move on.

2. **Failing/broken-test triage (secondary).** Walk existing failing or `BROKEN` regression
   tests and surface the divergence each encodes. Reactive, not generative — use it to seed
   predictions, not as the main engine.

3. **Error-message quality (always on).** Even when accept/reject is *correct*, the diagnostic
   can be bad: unlocated, vague, blaming the wrong span, missing the fix hint, or emitting a
   generic code where a specific one exists. A correct rejection with a useless message is a
   real finding (and often a registry-coherence cousin — see `scripts/registry_check.zig`).

---

## ⚖️ THE HARD STANCE — make a qualified guess, never a verdict (binding on EVERYONE)

When a probe diverges, there are **always at least two readings**, and they are **not yours to
choose between**:

- **(A) the toolchain is wrong** — the parser is too permissive, too strict, or emits a bad
  message. A real compiler bug.
- **(B) your expectation is wrong** — the language genuinely allows (or forbids) this, and the
  *prediction* misread the spec. The "test" is the thing in error, not the compiler.

This is the **asymmetric truth hierarchy** (`ARBITER_DRIVEN_DEVELOPMENT.md`), and it binds in
**both** directions:

- A **passing** test / worked example is strong evidence a shape is **intended-legal**. You may
  NOT propose "koru should reject X" when a passing example shows X is legal — that is
  **fabrication**. If you can't find a passing example of the shape, that absence is a *red
  flag to surface*, never a green light to invent the rule.
- A **diverging** result tells you **nothing about which side is wrong.** Silently "correcting"
  the expectation to match the compiler is **conformance fraud**; silently "fixing" the
  compiler to match your prediction is its mirror. Both are forbidden.

**Therefore: make a QUALIFIED GUESS, but never a verdict.** A 50/50 shrug is forbidden — it is
just permission to stop digging. You MUST lean — **A** (toolchain-wrong), **B** (expectation-wrong),
or **unsettled** — with a stated confidence, and you must **ground the lean in PRIOR ADJACENT ART**:
hunt the regression suite for `SUCCESS`-marked tests of this exact shape *or an adjacent one*. A
passing test of the shape is strong evidence it is intended-legal (→ lean **B**, your prediction
misread the spec). Finding **no** adjacent passing art is itself a prize finding — the behavior is
*unpinned*: say "unsettled — no prior art found" and flag the gap. Do **not** invent a coin-flip
where you simply didn't look.

The guess is **asymmetric**: commit it where a passing example grounds it; stay at *unsettled*
where none exists. And it is **a hypothesis handed to the arbiter — never a decision, never a
licence to act**:

- You still write **both** readings in full. `reading_B` stays complete **even when you lean A** —
  skimping the side you guessed against is the exact failure this stance exists to prevent.
- You still **never** edit a test, **never** "fix" the compiler. The arbiters rule which side
  moves, on the walk; your qualified guess is *evidence handed up*, weighted by the prior art you
  cite — not the ruling.
- The two frauds stay forbidden: editing a test to match the compiler (**conformance fraud**);
  proposing a rejection a passing test shows legal (**fabrication**).

---

## For contestants (the brief, sealed)

You are dropped into `/Users/larsde/src/koru`. **Read the repo-root standards first** —
`CLAUDE.md` and `AGENTS.md` — before anything else; they are the language's stated rules. Build
koru once (`zig build`) so `./zig-out/bin/koruc` is fresh.

Produce 4–8 **probes**. For each, return:

- `input` — the exact `.kz` source (small, one idea).
- `prediction` — `pass` or `fail`; if fail, the *specific* expected diagnostic (code and/or message).
- `why` — the stated rule or passing example that grounds the prediction (file:line).
- `actual` — what koruc actually did (exit, stderr, the diagnostic or its absence).
- `divergence` — none / accepted-should-reject / rejected-should-accept / wrong-or-bad-message.
- `reading_A_toolchain_wrong` — the concrete evidence the *compiler* is at fault.
- `reading_B_expectation_wrong` — the concrete evidence your *prediction* is at fault. **Hunt the
  `SUCCESS`-marked regression tests** for this shape or an adjacent one; cite the test path. A
  passing example is the strongest form of this evidence. If, after looking, you find none, say
  "no prior art found" — that absence is signal, not an excuse to skip the hunt.
- `qualified_guess` — your `lean` (`A` / `B` / `unsettled`) plus a `confidence` **defined by
  evidence, not a vibe** (a self-assigned percentage is theater — an LLM isn't calibrated, and a
  number just pressures manufactured certainty): `grounded` = you cite a `SUCCESS` test of this or
  an adjacent shape (verifiable; the **only** level at which a hard A/B lean is allowed);
  `inferred` = spec/code reasoning but no passing test found (weak lean, flagged as such);
  `unsettled` = no prior art (a frontier finding, not a guess). Plus `prior_art` — the cited
  `SUCCESS` test path, or "none found". A shrug with no dig is malformed; this is a hypothesis
  handed to the arbiters, never a verdict.
- `proposed_pin` — IF the arbiter later rules it real, the regression test that would capture it
  (`input.kz`, `MUST_FAIL` + `EXPECT=FRONTEND_COMPILE_ERROR` + `expected_error`, or a positive
  `MUST_RUN` + `expected`). Proposed, not applied.
- `severity` — low / med / high.

Everything you report is a **hypothesis**. Ground every claim in something you ran or read. Do
NOT edit tracked files, do NOT add tests, do NOT "fix" the compiler. Propose only.

---

## For arbiters (Lars + judge agent)

The contest returns divergences with both readings. On the walk, for each one:

1. **Decide which side moves** — and own that it is a *design* call, not a mechanical one. A
   newer compiler commit is not evidence; "the compiler is what runs" is not evidence. Weigh the
   stated rules against the passing examples.
   - **Toolchain wrong** → fix the parser/diagnostic, then **pin** a regression test.
   - **Expectation wrong** → discard, or pin a *positive* test that locks in the now-confirmed
     legality (so the next run can't re-probe it).
   - **Message-only** → improve the diagnostic (location, span, hint, specific code), then pin.
2. **Encode the valuable ones into the suite.** That is the flywheel turning: divergence →
   ruling → regression test / fix. The suite grows; the parser tightens; the next run probes the
   new frontier.
3. **Verify before merging.** Every contestant claim is hypothesis — re-run koruc on the input,
   read the diff, confirm the divergence is real and the reading is right.

**Never:** treat a red/divergent result as automatically the test's fault (or the compiler's);
edit expectations to match the compiler to make red go away (conformance fraud); commission a
"make koruc accept X" fix where X is forbidden by the rules (the valid form is "make it *reject*
X clearly"); let a sealed contestant settle which side is wrong.

---

## Pass / value contract

A run has earned its keep when it produces **≥1 confirmed divergence** the arbiters rule real and
pin into the suite — a new parser fix *or* a new regression test *or* a sharpened diagnostic.
Probes that merely confirm predictions are healthy ballast, not the deliverable. Zero confirmed
divergences across a full run is itself a signal (the probed frontier is solid — move the probes).
