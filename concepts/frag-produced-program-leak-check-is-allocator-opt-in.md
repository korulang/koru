---
type: belief
id: frag-produced-program-leak-check-is-allocator-opt-in
provenance: measured 2026-07-24 while asking whether the suite would catch a produced program that actually leaks; A/B run on one Koru source with two proc-body allocators
ts: 2026-07-24
---

# The produced-program leak check is real, and almost nothing in the corpus opts into it (belief)

The harness does check the final artifact, not just the compiler. Three phases
grep Zig's GPA wording (`memory address … leaked`) across `compile_kz.err`,
`compile_backend.err` and `backend.err` — frontend, backend-compile, backend-exec
— and a fourth check greps the produced program's own output for
`KORU LEAK CHECK FAILED`, with its own failure category that outranks the output
diff. The emitted `main()` carries a counting allocator (`__koru_leak_count`
over `koru_allocator()`) and exits 1 when the count is non-zero.

**All four are live. The fourth is opt-in by allocator choice, and the corpus
does not take it.** `__koru_leak_count` moves only for traffic through
`koru_allocator()`. A `|zig` proc body that reaches for `std.heap.page_allocator`,
`c_allocator` or its own arena — which is the ordinary way host wrappers are
written — allocates invisibly.

The A/B, one Koru source, two proc bodies differing only in the allocator:

- `page_allocator`, resource never freed → exit 0, no marker, suite green
- `koru_allocator()`, same resource never freed → exit 1, marker printed, caught

Measured population: 223 fixtures under `tests/regression` allocate through an
uninstrumented allocator; 3 use `koru_allocator`. 97 of the 223 are in
`330_PHANTOM_TYPES` — the cluster whose entire subject is resource discipline.

## Why this matters more than an ordinary coverage hole

The obligation system's compile-time wall and the produced program's runtime
counter are supposed to be independent layers over the same guarantee. For a
fixture on a raw allocator they are not independent — they are both blind. The
lantern shape that opened this
([[frag-obligation-enforcement-keys-off-return-binding]], third frontier) is
exactly that: the compile-time wall misses the undischarged obligation AND the
produced binary leaks the struct at exit 0. Two layers, one program, neither
fires. A green run on those 97 fixtures is not evidence that obligations are
enforced; it is evidence that nothing was watching.

## The fork, unruled

Making the counter unavoidable is the fix, and there are two shapes, which are
not equivalent:

- **A wall:** reject a `|zig` proc body that names a raw allocator, teaching
  `koru_allocator()` instead. Real enforcement, and it makes the guarantee
  structural — but it is a 223-fixture migration, and it presumes host code
  never legitimately wants its own arena.
- **Interposition:** make the emitted program's allocator the only one host code
  can reach, so the choice stops existing. No migration, but it reaches further
  into what a `|zig` body is allowed to be.

Unruled, and Lars's call — it is a language-surface question about what a proc
body may do, not a harness tweak. Related to the library-boundary Zig-leak work,
where hand-written `|zig` wrappers already drift from their Koru contract.
