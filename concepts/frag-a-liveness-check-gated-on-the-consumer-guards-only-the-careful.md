---
type: belief
id: frag-a-liveness-check-gated-on-the-consumer-guards-only-the-careful
provenance: Lars writing taint code by hand in koru-examples/human-doodle/doodle.k, 2026-07-30 — the doodle compiled and printed the tainted payload; pinned red as 335_047/335_048
ts: 2026-07-30
---

# A liveness check gated on what the consumer wants guards only the consumers that already care (belief)

Whether a binding is still alive is a fact about the **binding**. Whether a
callee wants a phantom state is a fact about the **callee**. Koru's
use-after-discharge check asks the second question first, and returns clean when
the answer is no — so a discharged value is rejected at a phantom-aware consumer
and waved through at every ordinary one.

`validateArgument` resolves the callee's expected phantom for the argument
position, and where there is none it returns `true` — "no phantom state expected
for this field" — some fifty lines before it reaches the `isDisposed` test that
raises the diagnostic. Both halves are correct in isolation. The gate is simply
attached to the wrong subject.

The consequence lands precisely where it hurts most. A sanitizer accepting
`<!tainted>` is phantom-aware, so calling it twice on the same binding IS caught.
`std/io:print.ln` takes a plain string, so printing the tainted original after
sanitizing is NOT — and printing is the sink the whole taint apparatus exists to
guard. The check is strongest against the shapes that were already careful and
absent against the shape a person actually writes.

## This is the same error as the leak-side root, one subject over

[[frag-obligation-enforcement-keys-off-return-binding]] is this belief's twin:
enforcement there minted an obligation only when the invocation carried a
`return_binding`, so a transform that dropped the bind silently dropped the
guarantee. Same shape here — enforcement keyed to an incidental property of the
call site rather than to the obligation's subject. That one was found because
seven `MUST_FAIL` tests flipped green at once. This one had no such alarm,
because no test had ever been written in the shape it fails on.

Two entries in the family, from the same cause, argue the rule generalizes: an
obligation's enforcement must be keyed to the resource, and any condition drawn
from the surrounding syntax is a candidate hole until something proves otherwise.

## Why it survived a suite that was watching for exactly this

The taint story looked covered from every angle a test author would think to
check. `330_068`/`330_069` pin sanitize-then-use and skip-the-sanitize.
`335_044`/`335_045` pin taint crossing a plain-typed parameter and a plain-typed
echo gateway, both deliberately written as laundering probes, both green. Not one
of them covers the sanitizer being **called** and the tainted original being read
**anyway** — the case where the developer does the right thing and then also does
the wrong thing beside it.

[[frag-a-check-that-cannot-match-reports-clean]] and
[[frag-a-watcher-off-the-normal-path-is-not-a-wall]] both describe guards whose
silence was believed. This is the third cause with the same signature: a guard on
the right path, with a correct pattern, running at the right moment, and scoped by
a predicate that has nothing to do with what it guards. Reading the check does not
reveal it. Reading the check's *guard* does.

## The masking that kept it quiet locally

There is an accident worth naming, because it will distort any measurement of a
fix. Bind the sanitizer's result and never read it, and `KORU100: unused binding`
fires — for reasons entirely unrelated to taint. The naive spelling of the mistake
therefore *does* get rejected, by the wrong diagnostic, which reads as the taint
system working. Read the clean binding anywhere at all and the tainted print goes
through. `335_048` is written to defeat exactly this masking; `335_047` is Lars's
original doodle. A fix measured only against `047` proves nothing.

## Open

Whether hoisting the disposal test above the phantom gate is sufficient, or
whether interpolation slots need separate handling. `{{response:s}}` is a binding
read inside a string-literal argument, and it is already visible to at least one
analysis — `KORU100` correctly counts `{{clean:s}}` as a use — so the read is seen
somewhere. Whether it reaches `validateArgument` as an argument is unestablished.
Bare-positional `print.ln(response)` leaks too, and that form the hoist alone
would catch.

Also open, and the reason this is a pin rather than a fix: the disposal test has
been unreachable for every plain-typed consumer in the language for its whole
life. Making it reachable wakes it everywhere at once. What the full board says
then is not predictable from here, and each red it produces wants reading rather
than greening — the check may be correct and the test may have been relying on
the hole.
