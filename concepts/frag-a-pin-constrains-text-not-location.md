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

A widened assertion with no users is indistinguishable from the gap it closed.
`ERROR_AT` shipped and then sat at zero consumers, and for that stretch the suite
was exactly as blind as before — the capability existed, the coverage did not.
An instrument change is only half a fix; the other half is pins that spend it.
The first ones are `210_160`, `210_161`, `510_106`, `210_162` and `210_163`.

Spending it immediately paid a dividend that argues for the whole approach: two
findings the replay had counted as independent — a caret on the wrong line, and a
caret at line 0 rendering compiler-injected source — turn out to be one
off-by-one seen at two file lengths, and one fix retires both. An axis nobody can
assert is also an axis nobody can *count* correctly; the instrument was inflating
the bug list as well as hiding it.

A location pin can also be hollowed out by its own fixture. `210_161`'s first
draft explained the defect in a comment that happened to contain the exact text
the assertion forbade, which suppressed the very output being asserted and left
the pin green-ish for a reason having nothing to do with the compiler. A pin that
constrains rendered output is coupled to its own file's content in a way a
text-substring pin never was — verify a location pin fails for its stated reason,
not merely that it fails.

Open: location is assertable and now defended in a handful of places, but still
not *required*. Nothing forces a new diagnostic pin to constrain where its caret
lands. Whether to make it mandatory — or to lint for carets falling outside their
own file, which would catch the whole family without waiting for a pin author to
think of it — is unsettled.

Pinned by: `ERROR_AT` in `scripts/regression_lib.sh`.
