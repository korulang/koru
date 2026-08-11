// Pins that a claim's key carries the proc VARIANT, and that the prose written
// beside a claim reaches the tool that reports it.
//
// Two implementations of one contract make the same claim about themselves.
// They are distinct claims because they are distinct implementations — the
// shape 370_VARIANTS/8201_variants_basic declares (three procs, one event name,
// different targets). A key without the variant collapses them, and the
// collapse is silent: an external judgment of one could not say which it judged.

[
- measured sorted-output
  The contract is what callers may assume. Which implementation delivers it is
  the variants' business, not this declaration's.
]tor sort { items: []i32 } -> []i32

[
- proven sorted-output
  Bubble sort: obviously correct by inspection, quadratic by construction.
]proc sort|zig(reference) {
    var result = items;
    for (0..result.len) |i| {
        for (i + 1..result.len) |j| {
            if (result[j] < result[i]) {
                const tmp = result[i];
                result[i] = result[j];
                result[j] = tmp;
            }
        }
    }
    return result;
}

[
- measured sorted-output
  Introsort: fast, subtle, and only as trustworthy as the property test that
  compares it against the reference variant.
]proc sort|zig(optimized) {
    var result = items;
    std.mem.sort(i32, result, {}, std.sort.asc(i32));
    return result;
}

[
- aspirational bounded-memory
  A per-line streaming surface backed by a whole-file slurp. The honest fix is
  true line-by-line streaming; marked so the gap is greppable, not hidden.
]tor read-lines {}
