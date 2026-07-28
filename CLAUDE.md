# Koru

Koru is a compiler. The toolchain is the product.

**Start with the `koru-toolchain` skill** — how to compile, how to run the suite,
the four-stage metacircular pipeline, what bites you. `koruc <file> glance` gives
a declaration surface before reading a big file.

## Ground truth is the tests

What's legal and what's rejected lives in the suite, not in prose. A `MUST_ERROR`
test with its `expected_error` pins both the refused program and the diagnostic
refusing it. When this file and the compiler disagree, the compiler wins.

- **`koru-by-example.md`** — curated tour of real tests, verbatim source.
- **`tests/regression/`** — the full suite.

## Syntax is Lars's

Don't invent spellings — not a keyword, not an ambient name, not "just for now."
When work needs surface that doesn't exist, bring the question and the evidence.
Never synthesize Koru syntax from analogy; read a passing test or say it's a
guess.

This is about *spellings*. Everything else — what to build, what to fix, when to
push, what to publish — is ordinary work.

## The suite is expensive

~11 minutes for a full `--no-cache` board. While iterating, run the affected
tests plus controls:

    ./run_regression.sh <full_test_name> <full_test_name> ...

Filtered runs write no snapshot, so they can't clobber `latest.json`. The full
board is for publishing. Never `zig build` or edit `koru_std/` while a suite is
live.

## Test comments

Write what the test *pins* — the shape it guards. Not its red/green state, not
why it fails today; that's derivable and goes stale the moment it flips.
