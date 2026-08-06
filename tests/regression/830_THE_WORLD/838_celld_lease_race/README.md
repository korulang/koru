# celld's lease, output gate and self-fence, as Koru obligations

Three slices of celld's decision core, eleven entries, one claim: **celld
enforces its central invariants with runtime discipline; Koru can make
violating them fail to compile.**

**Slice one — ownership.** *One writer per cell.*

| entry | marker | what it pins |
|---|---|---|
| `838_celld_lease_race` | `MUST_RUN` | a two-node CAS race; the winner writes, the loser gets no token, the takeover bumps the epoch, and the last release is *inserted by the compiler* |
| `839_celld_write_after_release` | `MUST_ERROR` | `KORU030` Use-after-discharge — the fenced node's write |
| `840_celld_forged_lease` | `MUST_ERROR` | `KORU030` no tracked phantom state — the losing node cannot conjure a lease |
| `841_celld_lease_with_no_way_back` | `MUST_ERROR` | `KORU030` obligation was not discharged — a lease with no consumer anywhere |

**Slice two — durability.** *Acknowledgement implies durability (RPO=0).*

| entry | marker | what it pins |
|---|---|---|
| `842_celld_durability_gate` | `MUST_RUN` | one write acked against a real proof, one write **failed** because the proof could not cover it |
| `843_celld_ack_without_proof` | `MUST_ERROR` | `KORU030` `'99'` holds no live `<durable!>` obligation — an ack cannot be invented |
| `844_celld_unanswered_request` | `MUST_ERROR` | `KORU030` was not discharged, *"Call one of: gate.ack, gate.fail"* — a request cannot be dropped |
| `845_celld_answered_twice` | `MUST_ERROR` | `KORU030` Use-after-discharge — one write, one outcome |

**Slice three — authority.** *No write is acknowledged after authority is lost.*

| entry | marker | what it pins |
|---|---|---|
| `846_celld_fence_forces_failure` | `MUST_RUN` | renewal *borrows* the lease so the ack is legal; the fence *consumes* it, and the pending response has exactly one way out left |
| `847_celld_ack_after_fence` | `MUST_ERROR` | `KORU030` Use-after-discharge — **a genuine durability proof is not enough** once authority is gone |
| `848_celld_lease_end_unstated` | `MUST_ERROR` | `KORU030` multiple discharge options — the cost of slice three, not a benefit (below) |

A Frontier fell out of slice two and is pinned separately at
`600_STDLIB/690_STORE/690_256_branch_payload_reads_a_store_column`: a store
column read in a branch-resolution payload is dropped at emission and surfaces
as a raw Zig `use of undeclared identifier`, while the identical read in the
subflow's guard threads fine. The port did not need that shape — celld's
`await_durable(cell, epoch, position)` takes the position as an argument, so
passing it as a tor input is the faithful spelling and it works.

## The arity of discharge is the whole design — and its own cost

One mechanism, opposite and correct behaviour in each slice, decided entirely by
*how many ways there are to discharge*:

- A lease in slice one has **one** consumer (`cas.release`). Auto-discharge
  inserts it at scope exit, so a lease cannot be leaked even by forgetting.
- A response has **two** (`gate.ack`, `gate.fail`). Auto-discharge refuses to
  choose, so every request's fate must be written down. celld reaches the same
  place by hand: its fence walks every gated write and completes it as *failed*
  (`logic/lib.rs:3838-3843`), because silently dropping and silently acking are
  both lies.

Neither behaviour was designed in; both fall out of counting the dischargers.

**Then slice three charged for it.** Adding `node.fence` gives `<!lease>` a
second consumer, which retires auto-discharge for leases *everywhere in that
program* — so `848` is an arm that used to be fine and now must state how
authority ended. This was not constructed to make the point; it was walked into
while writing `846`, one commit after
`concepts/frag-discharger-count-chooses-the-safe-default.md` predicted exactly
it: *"a second discharger is not merely a second API; it removes the safety of
forgetting."*

celld pays the same bill under a different name. Its shell has one function for
ending a node's authority and calls it `release_or_fence_node_lease` — the name
is the choice, made explicit because there is no longer a default.

## What slice three actually buys

celld's fence comment states the invariant plainly: *"Any write still waiting on
the output gate loses its cell here, so it must fail rather than be
acknowledged — the fence and the fail are atomic."* It holds because `fence()`
loops over `gated_writes` and fails each one, and because nothing else ever
builds an `Ok` response.

Here `gate.ack` borrows `<lease>` and `gate.fail` does not. Surrender the lease
and the ack is simply unreachable, so a pending response has one way out. The
fence and the fail are atomic because no other shape of program exists — not
because a loop was written correctly. `847` is the sharp end: the durability
proof is real, minted by `replica.sync`, covering the position — and the ack is
still refused.

## Where this came from

[celld](https://github.com/denoland/celld) is Deno's self-hosted implementation
of Cloudflare Durable Objects: Rust, V8, SQLite, and an S3 bucket that is the
*only* coordinator — no consensus, no membership protocol, no failure detector.

The reason it is worth reading is not the Durable Objects compatibility. It is
that celld's entire distributed protocol — 4,116 lines covering the lease, the
fence, the durability gate, and the node self-fence — lives in one crate whose
`Cargo.toml` declares:

```toml
# Pure decision core: no async, I/O, clocks, randomness, locks, or dependencies.
```

Zero dependencies, and no V8 anywhere in it. That list is the exact complement
of what Koru cannot do today: Koru has no working threads, no sockets, no file
writes, no clock. Every one of those absences lives in celld's *shell*. None of
them live in its decision core. So the interesting half of a real distributed
system turns out to be a half Koru can already write, and these four entries
write a slice of it.

## The mapping

| celld | Koru |
|---|---|
| `cas_owner(cell, guard, epoch)` → `Applied` (`ownership_store.rs:293`) | `cas.claim` resolving `\| applied string<lease!>` |
| `CasGuard::Absent` / `Match(etag)`, i.e. If-None-Match / If-Match (`bucket.rs:205`) | the `if(guard == own.etag)` subflow that selects the branch |
| takeover claims at `record.epoch + 1` (`logic/lib.rs:2812`) | the `std/store:stored` write inside the winning arm |
| epoch-in-prefix data-path fence (`replication.rs:6`) | `cell.write { lease: string<lease> }` — a borrow, so the call cannot be made without the token |
| `release_owner` (`ownership_store.rs:278`) | `cas.release { lease: string<!lease> }` — a consume |
| 10s node lease + renew at ttl/3 + self-fence `Halt{code:3}` (`logic/lib.rs:1838-1888`) | auto-discharge inserting the release at scope exit |

## What actually changes

celld's fence is made of **consequence**. A node that lost the CAS still runs,
still calls its write path, and is merely writing under an `e<epoch>` prefix
nobody will read. The program never learns it lost. Correctness is a property of
where the bytes landed, established after the fact.

Koru's is made of **admission**. `cas.claim` is the only minter of `<lease!>`,
`cell.write` borrows it, and there is no spelling of the forgery that
type-checks — `840` is the proof. The losing node does not write a dead prefix.
It does not build.

The same inversion shows up in the release. celld spends a lease TTL, a renewal
timer, a fence timer, and a process-halting self-fence answering "what if the
owner never gives the lease back?" In `838` the answer is one line that isn't
there: node-b's takeover writes no release, and the compiler inserts it. In
`841`, a program that mints a lease and declares no consumer for it is refused
outright.

## What this does NOT prove

Being precise, because the difference is the whole boundary:

- **Koru's guarantee is intra-program; celld's must survive partition and
  process death.** The phantom checker reasons about one compilation unit. It
  cannot know that a *different* node, in a different process, on a different
  machine, also thinks it holds the lease. Only the bucket CAS decides that.
- **So the two compose rather than compete.** The CAS remains the sole authority
  over who may hold a token. What the type system adds is everything downstream
  of the mint: given a lease, you cannot forge one, reuse a retired one, or
  drop one on the floor.
- **The bucket here is a `std/store` row, not S3.** Deliberately — it keeps the
  test deterministic and needs no I/O, which is the same posture celld's own
  decision core takes. It is not a client.
- **The type system proves you HELD a proof, not that the proof was SUFFICIENT.**
  This is the sharpest limit and it is worth stating exactly. celld's check is
  `durable >= gate.position` — a numeric comparison between two positions. A
  phantom cannot compare numbers, so `<durable>` says "a proof exists and you
  have it," never "it covers position N." `842` still gets that right, but at
  *runtime*, in `replica.sync`'s guard, exactly where celld does it. What moved
  to compile time is the discipline of gating at all — that a response cannot
  escape without going through the gate. What stays at runtime is whether the
  gate should open.
- **Same split, both slices.** The CAS decides who may hold a lease; the
  comparison decides whether a proof suffices. Types enforce everything
  downstream of those two decisions and nothing upstream of them. That is the
  honest shape of the result, and it is the same shape in each slice — which is
  mild evidence it is the general one rather than a lucky fit.

## Reproducing

```sh
./run_regression.sh celld     # all eight
./run_regression.sh 690_256   # the Frontier this turned up
```

celld facts above are cited against commit `553ae73f` (2026-08-05). Its
`celld.dev` headline figures — 4 MB per resident cell, ~4 ms wake, ~90 ms
durable write — are **not** constants in that source; they are measured
marketing. The code-truth per-cell cost is one V8 isolate (128 MiB heap cap,
`js.rs:2015`) plus one dedicated OS thread (`runtime.rs:560`) plus one SQLite
connection.
