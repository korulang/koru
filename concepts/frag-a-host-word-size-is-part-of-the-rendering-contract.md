---
type: belief
id: frag-a-host-word-size-is-part-of-the-rendering-contract
provenance: regex JS port — the Pike VM's [4]u64 class mask cannot be transliterated to JavaScript, whose bitwise operators are 32-bit
ts: 2026-08-06
---

# A second rendering is bounded by the host's word size, not only by its syntax

`fmt:ln` taught that a second rendering is not a translation of the first,
because the two emitters accept different **shapes** of product — statements
where the other took an expression. The regex port found the same belief in a
second organ, and this one is narrower and easier to miss: the two hosts differ
in the **width of the machine they compute on**.

The Pike VM emitter packs class membership as `[4]u64` and tests a byte with a
64-bit shift. Every token in that expression has a JavaScript spelling, so it
transliterates cleanly and reads correct. It is not. JavaScript's bitwise
operators coerce their operands to 32 bits, so the top half of every mask word
is discarded — and the failure is **silent and partial**: bytes 0–31 of each
word still match, so simple patterns keep passing while anything reaching a high
bit quietly stops matching. A test suite of ASCII fixtures would have called it
green.

The JS rendering therefore packs the same 256 bits as `[8]u32` and indexes with
`c >> 5` / `c & 31`. Same information, a word size the host can actually test.

The general belief: **when porting an emitter, the target's primitive widths and
numeric semantics are part of the contract being ported, not incidental spelling.**
Ask what machine the emitted code computes on before asking what its syntax looks
like. The tell is any emitted expression carrying a shift, a mask, an overflow, or
a division — those are the places where two hosts agree on the text and disagree
on the answer.

The corollary is about how you find it: a shape assertion cannot catch this, and
neither can a fixture corpus that never leaves ASCII. It was caught by running the
emitted JavaScript against the Zig engine as oracle on inputs chosen to reach the
high words — and the first run of that probe did not reach the VM path at all,
because every capture fixture was one-pass. Verifying the risky path required
constructing input that forces it; measuring the easy path and generalising would
have shipped the defect. See the `emit js:` tests in `src/regex_engine.zig`.
