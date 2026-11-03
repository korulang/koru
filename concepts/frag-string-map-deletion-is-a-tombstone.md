---
type: belief
id: frag-string-map-deletion-is-a-tombstone
provenance: evolved 2026-11-03 (seat w1C:p5A, koru-stdlib-gap commission) —
  `del` landed on both hash maps; the in-band tombstone idiom this file
  documented is retired. Prior provenance: 820_006_kv_protocol's -1 DEL
  sentinel, first instance of the workaround.
ts: 2026-11-03
---

# Deletion in a std/string-map is `del` — the in-band tombstone is retired (belief)

`std/string-map` has a deletion verb: `std/string-map:del(m, k)` evicts the
key and answers `| value` the evicted payload on a hit, `| missing` on
absence — `get`'s shape, minus the read. `std/map:del` is the i64-keyed
sibling with the identical contract. A hit is real removal: Zig's
`fetchRemove` drops the slot, and string-map's proc frees the map-owned
duped key bytes at eviction rather than leaving them for `free` to sweep
(map's sibling frees nothing — i64 keys carry no ownership). Both land as
`~part del` sibling files because each primary sits at its line pin.

This file previously recorded the opposite: no `del` existed on the
2026-11-03 module surface (`new set get contains count each free`), so
820_006 spelled absence in band — a -1 tombstone every reader sign-checked
before dereferencing the row handle. That reading was correct when written;
the workaround it documented is now retired. New "delete from a map" proofs
write `del`; the -1 spelling in 820_006 is legacy, not convention. Note
`del` governs the index entry only — 820_006 still takes the kv store row
itself, which is `std/store`'s business, not the map's.

The shape `del` took mirrors `get` (`| value` / `| missing`) rather than
store's `take` (`| item` / `| empty`): the store owns rows and hands them
out; the map owns entries and hands back only the payload — the key stays
internal. Pinned at 660_036 (string-map) and 660_037 (map).
