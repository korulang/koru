// TEST: `std/kernel:self` outside a `std/kernel:init` subtree must be REFUSED
// with a located koru-level diagnostic — never with a raw host panic. Pins the
// refusal contract, not the crash.
//
// FIXED 2026-08-06 — this was aspirational and RED; it is now green. What it used
// to get, verbatim from backend.err:
//
//   thread 215437003 panic: kernel.self: could not find invocation in AST
//
// What it gets now:
//
//   error[KORU170]: `std/kernel:self` outside a `std/kernel:init` subtree —
//                   a kernel op needs a kernel view to operate on
//     --> input.k:8:0
//     hint: wrap it, e.g. `std/kernel:init(bodies) | kernel k |> ...`
//
// THE FIX, and it is not the one the root-cause section below predicted. That
// section reads the failed pointer search as a bug to repair so the search would
// SUCCEED. It is not: a standalone `self`/`pairwise` only ever runs OUTSIDE a
// `kernel:init` subtree, because inside one `init` is `claims_descendants` and
// collects the ops itself. So the search failing is CORRECT — it is the ordinary
// user mistake of writing a kernel op with no kernel view — and the defect was
// only that an unconditional `@panic` reported it. `koru_std/kernel.kz` now emits
// KORU170 and exits, at both the `self` and `pairwise` sites.
//
// WHAT THIS LEAVES OPEN, and it is a design ruling rather than a bug: if the
// standalone path is always illegal, the several hundred lines of emit code below
// that refusal are unreachable — which is why `__koru_kernel_ptr_{}` still has no
// witness on the variant-coverage board. Either standalone kernel ops are meant to
// be supported (then the search must learn to find flow-root and nested sites, and
// the emit becomes reachable) or they are not (then the dead emit should go). The
// symbol is deliberately left UNCOVERED rather than exempted, so the wall keeps
// asking until that is decided.
//
// THE CONTRADICTED INTENT. 680_002_trellis_pairwise_outside_init pins the same
// shape guarded by a trellis, and its note states the design: the trellis check
// runs in Stage C BEFORE kernel transforms touch the tree, "so the user gets the
// trellis message — not a transform panic or generated-Zig wreckage". That is
// only true WITH a trellis defined. Without one — the common case, this file —
// the transform is reached and the panic is exactly what the user gets. The
// stated contract is not honoured on the unguarded path.
//
// SCOPE OF THE DEFECT. Probed 2026-08-06, all four placements, each its own
// clean directory compiled with `koruc input.k`:
//
//   top-level `std/kernel:self { ... }`                        → panic: kernel.self: ...
//   top-level `std/kernel:pairwise { ... }`                    → panic: kernel.pairwise: ...
//   `std/io:print(..) | kernel k |> std/kernel:self { ... }`   → panic: kernel.self: ...
//   `std/io:print(..) | kernel k |> std/kernel:pairwise {...}` → panic: kernel.pairwise: ...
//
// ALL FOUR panic. The standalone self/pairwise transforms have no reachable
// entry. Only the self shape is pinned here — one pin per defect, and pairwise
// dies by the identical mechanism.
//
// ROOT CAUSE (this is the part not to lose). It is pointer identity, not
// missing syntax:
//
//   1. `findInvocationRecursive` in both standalone transforms pointer-compares
//      the handler's `invocation` against CONTINUATION nodes only
//      (koru_std/kernel.kz:1527 for pairwise, :1841 for self). A flow's own
//      ROOT invocation is never inspected — so a top-level placement, like the
//      one below, can never match.
//   2. A NESTED (continuation) placement never sees its real pointer either.
//      src/transform_pass_runner.zig:1074-1078 hands the handler a `siteView`
//      when the site has no wrapper; `siteView` (same file, 180-196) builds
//      `ast.Flow{ .body = holding.* }` — a BY-VALUE copy — and `Flow.invMut`
//      (src/ast.zig:989) returns the address inside that copy.
//   3. `childPosition` (src/transform_pass_runner.zig:824, 833-837) gives a
//      non-null wrapper ONLY at a flow's root body, so every nested site takes
//      the copy path in (2) and every root site fails on (1).
//
// The `orelse @panic(...)` below that search is therefore unconditional.
//
// WHY THE FUSED PATH IS FINE. Inside a `std/kernel:init` subtree these
// transforms never run at all: `init` is `[comptime|transform|claims_descendants]`
// (kernel.kz:80) and collects the ops itself, emitting `__koru_fused_ptr`
// (kernel.kz:691). That is the path every green kernel test takes — 390_040,
// 390_003, 115_016 — which is why the defect has stayed invisible.
//
// BOARD NOTE. The dead standalone path is the only writer of
// `__koru_kernel_ptr_{}` (kernel.kz:1588, 1907), so the variant-coverage wall
// reports that symbol UNCOVERED. It is deliberately NOT exempted: a symbol
// invisible because its emitter CRASHES is broken surface, not accepted
// invisible surface. This pin is where that finding lives.
//
// A SECOND DEFECT SITS ON TOP OF THIS ONE, and it is not asserted here because
// it is not visible in `backend.err`. What the AUTHOR sees at the terminal is
// not the panic above — koruc's SIGABRT handler catches it and prints:
//
//   ✗ The backend (the compiled compiler pipeline) was killed by signal 6
//     (SIGABRT) ... This usually means the machine ran out of memory (the OS
//     kills the biggest process under pressure) ... The source program was
//     never judged — there is no compiler diagnostic to fix here.
//
// Every clause of that is wrong here: the program WAS judged and is genuinely
// bad, the machine is fine, and there is a diagnostic to write. So an ordinary
// mistake is reported as a hardware problem, which sends the author to check
// memory pressure instead of their program. That handler is right for a real
// OOM kill and cannot currently tell the two apart — an aborting compiler
// pipeline and an externally-killed one arrive as the same signal. Fixing THIS
// pin (refuse instead of abort) removes the misreport for this shape; the
// handler's inability to distinguish a self-inflicted abort from an external
// kill is a separate question and is not pinned anywhere.
//
// Deliberately NOT asserted: the text above is written by koruc to its own
// stdout, and this pin's EXPECT assertions are matched against `backend.err`
// (regression_lib.sh:1260-1281). A `NOT_CONTAINS` for it here would sit in a
// file the string never reaches, and an assertion that cannot fail is worse
// than no assertion — it reads as coverage while guarding nothing.

import std/kernel

std/kernel:shape(Body) {
    mass: f64,
}

// VIOLATION: `self` with no `std/kernel:init` anywhere. There is no kernel view,
// so there is nothing for `k` to name — and that is precisely what the compiler
// should say.
std/kernel:self { k.mass *= 2.0 }
