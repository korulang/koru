---
type: belief
id: frag-a-pin-constrains-text-not-location
provenance: introduced during a Challenge 001 replay — three contestants hit wrong-location diagnostics on unrelated code paths
ts: 2026-07-24
---

# A pin constrains a diagnostic's text, never its location (belief)

We believed that a `MUST_FAIL` test carrying an `expected_error` pinned the
diagnostic it named. It pinned only the *message text*. Matching was substring-only
end to end, so nothing in the suite could express **where** a caret lands — and a
constraint the instrument cannot express is a constraint nobody is keeping.

The consequence is not hypothetical and not local. A diagnostic could point at a
blank line, past the end of its own file, or at source the compiler injected and the
programmer never wrote, and every relevant test stayed green. Because green looked
like coverage, the gap read as *absence of bugs* rather than *absence of vision*.

The deeper lesson is about instruments rather than parsers. When several unrelated
findings rhyme, the shared cause is usually not in the code under test but in the
thing doing the testing: an axis the harness cannot assert becomes an axis nobody
defends, and defects accumulate there silently and for free. So when a class of bug
turns up repeatedly across unrelated subsystems, suspect the instrument before
suspecting a coincidence — and prefer widening what a pin can *say* over fixing the
instances one at a time, because the widened assertion also guards the instances
nobody has probed.

This is why the fix landed in the harness before any of the individual diagnostics
it exposed. Fixing a location bug without first being able to pin a location would
have produced tests that pass for the wrong reason — the same failure mode, one
level up.

Open: location is now assertable but not *required*. Nothing forces a new pin to
constrain where its diagnostic lands, so the axis is defensible rather than
defended. Whether to make it mandatory for new diagnostic pins — or to lint for
carets that fall outside their own file — is unsettled.

Pinned by: `ERROR_AT` in `scripts/regression_lib.sh`.
