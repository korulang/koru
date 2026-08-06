---
type: belief
id: frag-a-handle-count-is-not-a-capability-check
provenance: probing 440_RESOURCE_BRIDGE 2026-08-06 — `close(handle: "file_99")` against a pool holding only "file_1" ran the real close() proc and the run reported success; the pool count stayed correct throughout
ts: 2026-08-06
---

# A ledger of obligations is not a check on who may discharge them (belief)

The interpreter's handle pool was built to answer *how many resources are still
held*, and it answers that honestly. We then read the honest answer as if it were
an enforcement, and it never was one.

Measured: a run naming a handle the pool had never issued dispatched the discharge
event, the real proc executed, and the run returned `result`. The count did not
move — correctly, since nothing on the pool matched — so every observable the
system offered said "no obligation was discharged" while the resource had in fact
been released. The ledger and the act had come apart, and the ledger was the only
thing anyone was reading.

## Why the shape is worth keeping, not just the instance

The pool was placed *after* the dispatcher. That ordering is what makes the
failure invisible: bookkeeping downstream of the irreversible act can only ever
*describe* what already happened. A check belongs upstream of the act it guards,
and the tell that it isn't is precisely this — the numbers stay right while the
world goes wrong.

There is a stronger version of the same mistake available, and it is the one to
watch for: **a count is the cheapest thing to make correct, so it is the first
thing to be correct, and being correct it gets trusted.** Nothing about a
faithful counter implies anything guarded it.

## What this cost the design

The resource bridge's whole pitch is COM with the leak made unspellable — a handle
you can pass over a wire, where *possession of the name is the authority*. That
sentence has two halves and both were missing at once: the names were `"file_1"`,
guessable by anyone; and possession was not checked, so guessing was not even
required. The compile-time story (`<!session>`, KORU030) was real the whole time
and is what the language actually sells. The runtime story underneath it was a
tally.

## The rule

Before citing a resource system's numbers as a safety property, find the line
where the refusal happens. If every branch leads to the act and the pool is only
consulted afterwards to update a total, there is no refusal — there is
accounting. Accounting is worth having; it is not the guarantee, and the two are
easy to confuse because a system with no enforcement at all still reports
plausible totals.

Related: [[frag-a-misnamed-assertion-is-silently-no-assertion]] — the same seam
one layer up. There a green board reported a claim nothing checked; here a handle
count reported a guarantee nothing enforced. In both cases the artifact of
diligence was present and the diligence was not.
