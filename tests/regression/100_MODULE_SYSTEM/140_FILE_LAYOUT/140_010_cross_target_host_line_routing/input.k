// Cross-target host-line routing + multi-kind effect dispatch.
// Contract: events + flow. Module state (the counter) is a host line, so it
// lives in the per-host impl facets (input.kz / input.kjs), not here.
pub tor run { n: u64 }
! key u64
! tick u64

pub tor bumpKey { v: u64 }
pub tor bumpTick { v: u64 }
pub tor report {}

run(n: 6)
! key k |> bumpKey(v: k)
! tick t |> bumpTick(v: t)
report()
