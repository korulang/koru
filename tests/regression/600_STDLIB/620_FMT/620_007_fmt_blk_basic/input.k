// PIN (2026-08-06): `std/fmt:fmt.blk` — the ALLOCATING sibling of 620_001's
// `ln` — is dead surface. It is declared, its comptime transform works, and no
// program can run it. This is that program, written the way the stdlib's own
// doc comment specifies (koru_std/fmt.kz:40-44):
//
//     fmt.blk { … } | formatted f |> … f.text …
//
// Three defects, all in koru_std/fmt.kz, all on the same value:
//
//  1. `fmt.blk.impl` (fmt.kz:62) declares neither branches nor a return type,
//     so flow_checker.zig:1551's "return_type != null → the `| label` is
//     binding sugar" escape does not apply, and tag coverage refuses the arm
//     the transform actually constructs:
//       error[KORU021]: event 'std.fmt:fmt.blk.impl' has no branch 'formatted'
//                       (available: (none))
//     `ln.impl` (fmt.kz:316) carries `-> string`, which is why 620_001 is green.
//
//  2. The emitted template breaks to `:__blk` (fmt.kz:226). Nothing in the
//     compiler ever writes a `__blk:` label — `writeInlineCodeWithLabel`
//     (emitter_helpers.zig:4555) labels a body only when it carries the
//     `__KORU_INLINE__` placeholder, which `ln` uses and `blk` does not. The
//     break is dangling at every depth and in every consumption form.
//
//  3. With no placeholder the body lands in statement position and takes a
//     trailing `;` (emitter_helpers.zig:4804), so the emitted program dies at
//     parse before Zig ever reaches the label:
//       output_emitted.zig: error: expected statement, found ';'
//
// Flips green when fmt.kz gives `fmt.blk.impl` the shape its value has and the
// template breaks to `__KORU_INLINE__`. Until then this is the only thing in
// the corpus that says fmt.blk exists — the comptime-mirror manifest records it
// as `no-green-usage` (115_COMPTIME_MIRROR/COVERAGE.md:29), and the four symbols
// the template writes (`__fmt_alloc`, `__fmt_text`, `__fmt_result`, `__blk`)
// are the variant-coverage wall's UNCOVERED lines for fmt.kz.
import std/fmt
import std/io

const {
    name: "World"
    count: 42
}

std/fmt:fmt.blk {
    Hello, {{ name:s }}! The answer is {{ count:d }}.
}
| formatted f |> std/io:print.ln(f.text)
