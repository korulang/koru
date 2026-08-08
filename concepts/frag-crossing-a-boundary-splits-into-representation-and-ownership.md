---
type: belief
id: frag-crossing-a-boundary-splits-into-representation-and-ownership
provenance: 140_018 — "text is hard across a C ABI" turned out to be one easy question and one honest refusal
ts: 2026-08-08
---

# Crossing a boundary splits into representation and ownership, and only one of them is hard (belief)

"Text is hard across an ABI" is the received wisdom and it blocked the C-ABI
story for months. Taken apart, it is two questions that happen to share a
sentence:

**Representation** — what shape does the value take on the other side? For text
going IN this is not hard at all. A Koru `string` is a pointer and a length, C
has passed exactly that pair for decades, and one Koru parameter becomes two C
parameters. No invention, no negotiation; the caller already knows the
convention because it is not ours.

**Ownership** — who allocated it, who frees it, and how long does it live? This
is the genuinely hard half, and it is the whole reason the received wisdom
exists. It is also entirely absent from the inbound direction: the caller owns
the bytes and outlives the call, so there is nothing to decide.

Returning text is where both questions arrive at once, and the second has no
answer C can express: one return slot cannot carry a pointer and a length, and
any protocol that works — an out-parameter, a caller-supplied buffer, a freeing
function — is a convention every caller must learn from OUR source rather than
from C. So it is refused by name. **Refusing one direction is what let the other
ship**; treating them as one problem is what kept both blocked.

The two rejected spellings are worth keeping because each fails on a different
half. `[*:0]const u8` fails on REPRESENTATION — it demands a NUL that a slice
never promises, so it corrupts on the first string without one, silently. A
struct-by-value fails on CONVENTION — it works, but it is an ABI of our own
invention, and a caller who cannot write the header by hand has not really been
given a C interface.

The general move: **when a boundary problem feels hard, check whether it is one
problem or two wearing one name.** Here, splitting it turned a months-old
blocker into a feature plus a documented no.

Related: [[frag-a-partial-success-is-a-better-disguise-than-a-total-failure]] —
also a case where one name hid two mechanisms.
