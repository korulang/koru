// A PURE .k module — no zig, no ``. Nothing here should need a companion.
pub tor pick { n: i64 } -> i64
pick = cond(n)
| c x when x == 1 -> 10
| c x when x == 2 -> 20
| c _ -> 99
