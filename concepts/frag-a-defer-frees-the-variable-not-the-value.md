# frag-a-defer-frees-the-variable-not-the-value

`defer polyFree(alloc, b)` does not snapshot `b` at the defer statement —
it evaluates `b` when the scope exits and frees whatever slice the
variable holds *then*.

That is the intended semantics and it is load-bearing in loops that
rotate ownership (`a = b; b = dm.r`): one defer on the rotating variable
correctly frees the final value. The trap is mixing deferred and
explicit frees of the same variable:

```zig
var b = try polyClone(alloc, b_in);
defer polyFree(alloc, b);          // frees whatever b holds at exit
while (!polyIsZero(b)) {
    const dm = try polyDivMod(alloc, a, b);
    polyFree(alloc, dm.q);
    polyFree(alloc, a);
    a = b;
    b = dm.r;                      // b now holds a live allocation
}
polyFree(alloc, b);                // <- double free: this line and the
                                   //    defer both fire on the same dm.r
```

Found 2026-10-31 in `polyGcd` (sym.certcomp.kz): the explicit
`polyFree(alloc, b)` after the Euclid loop freed the last remainder, and
the defer freed it again — `sliceAsBytes` integer-overflow panic in the
leak-check build, not a quiet corruption.

Ruling: pick one owner of the free per variable — either defer-on-var
(preferred for rotating ownership) or explicit frees at each exit path —
never both. The mirror image of
frag-a-dummy-slot-reset-is-an-allocation-in-disguise (overwrite without
deinit leaks; deinit plus deferred deinit double-frees).
