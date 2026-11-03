---
type: belief
id: frag-string-map-deletion-is-a-tombstone
provenance: 820_006_kv_protocol — a KV line-protocol proof needed `DEL` to
  drop an index entry; `std/string-map` has `new set get contains count
  each free` and no `del`, measured by reading the module 2026-11-03
ts: 2026-11-03
---

# Deletion in a std/string-map is a tombstone, not a removal (belief)

`std/string-map` cannot delete a key. There is no `del`/`remove` verb —
the map surface is `new set get contains count each free`, read on the
2026-11-03 tree. A program that must forget a key spells absence **in
band**: write a sentinel the value domain can distinguish (`-1`, since
row handles are 1-based brands), and every reader checks the sign before
acting on the payload.

This is safe to do against store-row payloads precisely because of the
handle contract: handles are generation-stable across another row's
swap-removing take (690_092), so a parked handle never names the wrong
row — and reads through a *stale* handle trap while `take` is the one
verb with a graceful `| empty` arm (690_070). The tombstone exists to
keep readers off the trap path, not to keep the index honest; the store
already keeps identity honest.

Why this is worth a belief rather than a comment: the sentinel spelling
is a workaround for a surface gap, and it is easy to mistake for design.
The natural pristine spelling — `std/string-map:del(m, k)` — does not
exist, so every "delete from a map" proof will independently reinvent
the sentinel. 820_006 is the first instance.

Open question: should `del` exist? The store already has `take` as its
deletion verb with a two-arm contract (`| item` / `| empty`); a map `del`
would presumably mirror `get`'s shape (`| value` the evicted payload /
`| missing`). Until it lands, the tombstone idiom is the only spelling —
call it out in writeups so it does not fossilize into convention by
accident.
