---
type: belief
id: frag-no-verdict-must-not-fold-into-verdict-was-no
provenance: the .kz→.k migration gate, 2026-08-09. It enumerated 38 candidates, handed only 33 to the runner because its filter was built from a leading `NNN_NNN` that five directory names do not have, and reported those five as "no marker — never ran". A two-state gate would have counted them as "stays .kz" and printed a smaller, healthier backlog
ts: 2026-08-09
---

# A backlog is only a backlog if the gate can say "I did not judge this"

A gate that classifies each candidate as pass-or-fail has two buckets and needs a
third. The missing one is **"produced no verdict"** — the candidate that was
enumerated, counted in the denominator, and then never actually run, because a
filter, a name pattern, or a skipped setup step dropped it on the way to the
oracle. With only two buckets it lands in whichever one is the absence of a
marker, and for a migration backlog that is *"correctly stays where it is"* — the
answer that makes the number go down.

**That is the direction the error always runs, and it is why this is worth a
fragment.** A dropped row does not produce a scary result; it produces a *better*
result. The backlog shrinks, the sweep looks more finished than it is, and the
next session reads "mined out" and stops looking. Nothing about the output
distinguishes a candidate that was tried and passed from one that was never tried
at all — unless the gate refuses to collapse them.

The concrete instance: the gate ran per-candidate by extracting a leading
`NNN_NNN` from each directory name, and five candidates are named with one number
rather than two. They were never handed to the runner. The gate said so, in its
own section, and exited non-zero — which is the only reason the miss was visible
at all, and the reason the earlier belief that this backlog was "mechanically
mined out" has to be qualified: part of that conclusion rested on candidates
nobody had tried.

Sibling to [[frag-a-check-that-cannot-match-reports-clean]], which is about a
check whose *pattern* cannot match and therefore reports nothing. This one is
about a check whose pattern is fine but whose *worklist* silently loses rows
between enumeration and judgment. Both report health; only one of them is
detectable by reading the predicate.

**What would correct this:** a case where the third bucket is noise — where
"never ran" is routine and expected, and forcing the gate to fail on it trains
everyone to ignore the exit code. Then the third state has become decoration and
the honest move is to fix the enumerator instead of reporting the gap.
