// Pins the claims registry's key-crash wall: two claims that land on ONE key
// are reported, and the export is refused.
//
// Both entries name the rule `no-alloc` about the same subject, with different
// stamps. That is a contradiction an author cannot resolve by reading — the
// declaration is either measured or aspirational about that rule, never both —
// and it is exactly what a registry sees that no single reader does.

[
- measured no-alloc
- aspirational no-alloc
  Two stamps, one rule, one subject. Whichever is true, the other is a lie, and
  an external judgment handed this export could not say which claim it judged.
]tor sort { items: []i32 } -> []i32

proc sort|zig {
    return items;
}
