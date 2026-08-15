---
type: belief
id: frag-a-stores-schema-survives-in-its-apply-event
provenance: session 2026-08-14 — store-backed kernels (kernel over std/store columns)
ts: 2026-08-14
tags: [koru, store, kernel, transform-order]
---

# A store's SoA schema survives the store transform only in its apply event (belief)

A kernel that iterates a `std/store:new` store needs the store's column schema,
but by the time the kernel's init transform runs, the `std/store:new` flow is
GONE — the store transform consumes its own declaration first (measured
2026-08-14: zero `new` flows remain in the program at kernel-init time). The
schema does not survive as a shape or host-type item either; the SoA cell is
raw Zig inside a synthesized proc.

What does survive is the per-store **apply event** the store transform
synthesizes (`__store_apply_<name>`), whose branches are exactly the typed
column list in declaration order (`x : f64` branch, `vx : f64` branch, …). A
consumer transform therefore reads the store's schema from the apply event —
the durable, parseable remnant of the store's declaration.

What would correct this belief: the store transform growing a durable schema
item (a host type with the column shape, or keeping the `new` flow's source
reachable), at which point the kernel should read THAT instead and the apply
event stops being the schema carrier.

Corollary that holds today: a kernel's `init` cannot take the store name and
find the columns by scanning for `std/store:new` — the scan must target what
the transform leaves behind, which is the contract that makes cross-transform
consumption order-independent.