---
type: belief
id: frag-a-distributed-protocol-is-a-pure-decision-core
provenance: reading denoland/celld (self-hosted Durable Objects) at 553ae73f while asking what Koru could take from it; the finding was in a Cargo.toml comment, not in any of the 4,116 lines it guards
ts: 2026-08-06
---

# A distributed protocol is a pure decision core; the sockets are the boring half — so Koru is not blocked from distributed systems (belief)

The standing assumption, never written down but acted on constantly, is that
distributed-systems work is **gated on runtime capability**. Koru has no working
threads (`420_010` fails), no sockets (`koru_std/net.kz` prints "would listen"),
no file writes, no clock. So that whole class of program reads as out of reach
until those land, and the roadmap question is "when do we get sockets."

celld is the counter-evidence. It runs Cloudflare Durable Objects on your own
machines — leases, fencing, replication, failover — and it keeps the entire
distributed protocol in one crate whose `Cargo.toml` says:

```
# Pure decision core: no async, I/O, clocks, randomness, locks, or dependencies.
```

4,116 lines, zero dependencies, no V8 anywhere in it. The lease state machine,
the epoch fence, the durability gate, and the node self-fence are all a
deterministic function from event to effects. Everything Koru lacks is in the
*shell* that feeds that function. Nothing Koru lacks is in the function.

**The durable claim: the hard, interesting, correctness-bearing half of a
distributed system is exactly the half that needs no I/O — so an I/O-poor
language is not disqualified from it, it is disqualified only from the
deployment.** The gating question is not when sockets arrive. It is which
decision core we choose to compile.

## Why this is worth more than the one port it came from

Two things compound, and neither is about celld.

The first is that a pure decision core is **deterministically testable**, which
is why celld tests theirs under fault injection rather than against a cluster.
That is the same property the regression harness already requires of every test
here. A protocol core is therefore not merely expressible in Koru — it is
expressible in the shape this repo already knows how to hold.

The second is that the pure core is where a type system can still reach. Once
the protocol is a function, its invariants are *arguments and return types*, not
runtime state spread across sockets — and that is the seam where an obligation
can replace a runtime check. See `838_celld_lease_race` and its three negative
twins for the worked instance: celld fences a stale owner by making its writes
land under a dead object prefix, and the same invariant becomes a phantom borrow
that refuses to compile.

## Where the claim is weak, stated plainly

- **It rests on one system read closely, not a survey.** celld may be unusually
  disciplined; the split may be a house style rather than a property of the
  domain. What would widen it is finding the same core/shell seam in systems
  that did not advertise it.
- **The seam may not hold for the next slice.** celld's RPO=0 comes from an
  output gate that withholds a response until a replica proves durability. That
  is still pure — it is a comparison against a position — but the *timer* paths
  around it (10s lease TTL, renewal at ttl/3, a fence at ttl+1ms) are not
  obviously expressible without a clock. If the timers turn out to be load-bearing
  *inside* the core rather than events fed to it, this belief is too strong and
  wants correcting.
- **It says nothing about deployment.** A protocol core that cannot be run
  against a real bucket is a proof, not a product. Conflating the two would be
  the obvious way to misuse this.

## What it changes about what we attempt

Distributed-systems ports stop being blocked work and become **available** work,
today, at the same maturity as everything else in the corpus. The unblocking was
never a runtime feature; it was noticing which half we needed.
