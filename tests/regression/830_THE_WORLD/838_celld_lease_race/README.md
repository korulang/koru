# celld's ownership lease, as a Koru obligation

Four entries, one claim: **celld enforces one-writer-per-cell with a runtime
fence; Koru can make the unowned write path fail to compile.**

| entry | marker | what it pins |
|---|---|---|
| `838_celld_lease_race` | `MUST_RUN` | a two-node CAS race; the winner writes, the loser gets no token, the takeover bumps the epoch, and the last release is *inserted by the compiler* |
| `839_celld_write_after_release` | `MUST_ERROR` | `KORU030` Use-after-discharge — the fenced node's write |
| `840_celld_forged_lease` | `MUST_ERROR` | `KORU030` no tracked phantom state — the losing node cannot conjure a lease |
| `841_celld_lease_with_no_way_back` | `MUST_ERROR` | `KORU030` obligation was not discharged — a lease with no consumer anywhere |

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
- **No durability gate.** celld's RPO=0 comes from refusing to release a
  response until the replica proves `durable >= position`
  (`logic/lib.rs:3711`). That is the obvious next slice and is not modelled here.

## Reproducing

```sh
./run_regression.sh celld     # all four
```

celld facts above are cited against commit `553ae73f` (2026-08-05). Its
`celld.dev` headline figures — 4 MB per resident cell, ~4 ms wake, ~90 ms
durable write — are **not** constants in that source; they are measured
marketing. The code-truth per-cell cost is one V8 isolate (128 MiB heap cap,
`js.rs:2015`) plus one dedicated OS thread (`runtime.rs:560`) plus one SQLite
connection.
