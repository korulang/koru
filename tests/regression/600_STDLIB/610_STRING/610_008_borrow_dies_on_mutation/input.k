// ASPIRATIONAL RED — the SECOND invalidator, and the one that decided 610_007.
//
// 610_007 pins `read` then `free` then use. This pins `read` then APPEND then use:
// NO free anywhere, the owner fully alive, and the borrow is still garbage.
//
//     borrow after append: [<garbage>]      exit 0, compiles clean
//
// Every String mutator reallocs (append/append-char/pop-char/clear —
// koru_std/string.kz), so `free` is only ONE of several ways a borrow dies. That
// is why it matters far beyond an extra test case:
//
// A LIVENESS-PROPAGATING PHANTOM CANNOT FIX THIS. The obvious repair for 610_007
// is to make `read`'s output inherit its input's liveness, so the existing
// use-after-discharge poison reaches it. That machinery already works three ways
// (a poisoned after take, owned poisoned after free, and a discharged record field
// read through `{{ }}` since 335_052). It would still admit THIS program, because
// `append` discharges nothing. Making it sound means freezing mutation while a
// borrow lives — a full borrow checker. So the taint fix is UNSOUND, not merely
// incomplete, and that is the whole argument for banning the returned borrow
// instead of annotating it.
//
// Rust catches both of these and they are its two canonical errors: E0505 on the
// free case, E0502 ("cannot borrow as mutable because it is also borrowed as
// immutable") on THIS one. Koru currently has Rust's ownership half — affine
// phantoms, consume-once, use-after-discharge — without the borrowing half, and
// `std/string:read` is the single place in the stdlib where that gap is reachable.
// It is the only stdlib tor returning a raw borrow of a parameter's buffer;
// `substring` allocates and `read.ln` dupes.
//
// expected.txt asserts the text the borrow SHOULD still read, so this flips green
//
// NO free anywhere. Owner fully alive. Just read, then append, then use.
import std/io
import std/string
std/string:from-page(text: "hello world")
| ok a |> std/string:take(s: a): owned
    |> std/string:read(s: owned): t
    |> std/string:append(s: owned, text: "! and more text to force a realloc")
        | ok |> std/io:print.ln("borrow after append: [{{ t:s }}]")
        | err _ |> _
| err _ |> _
