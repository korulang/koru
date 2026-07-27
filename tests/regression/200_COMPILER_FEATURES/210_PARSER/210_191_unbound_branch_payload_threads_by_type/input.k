// PINS: an UNBOUND branch payload threads into the next stage by TYPE.
//
// `| lo` carries an i64 and writes no binder. `tally` has `tag` written, so `n`
// is its only unfilled parameter and the arriving payload is an i64 — exactly
// one candidate, so it lands there. The branch is named `lo` and the parameter
// is named `n`: nothing puns, and nothing needs to. This is 210_176's rule
// ("the thread fills the unfilled parameter whose type it matches") reaching
// the branch-payload position, where a payload previously had to be named
// before it could move at all.
//
// The `| hi b` arm is the control, and the point of putting both in one
// program: a binder is how you get a NAME when you want one — for an
// interpolation, a second use, or an obligation you want visible at the call
// site — not a tax on the case where the payload goes straight into the next
// step. Both spellings stay legal.
//
// Sibling of 210_192, which is this same rule for an EFFECT payload (`! emit`).
// One check refuses both positions today, so they move together.
//
// pick(7) takes the `lo` arm carrying 7; tally(tag: "abc", n: 7) is 7 + 3.
import std/io

tor pick { n: i64 }
| lo i64
| hi i64
proc pick|zig {
    if (n < 10) return .{ .lo = n };
    return .{ .hi = n };
}

tor tally { tag: string, n: i64 } -> i64
proc tally|zig { return n + @as(i64, @intCast(tag.len)); }

pick(n: 7)
| lo |> tally(tag: "abc"): r |> std/io:print.ln("lo = {{ r:d }}")
| hi b |> std/io:print.ln("hi = {{ b:d }}")
