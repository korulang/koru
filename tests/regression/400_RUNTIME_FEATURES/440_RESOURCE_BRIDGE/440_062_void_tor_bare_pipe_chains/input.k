// Pins: bare `|>` is sequencing, not an arm — the backbone of the
// language. On a void tor `verb() |> next()` runs next in order; a
// trailing `|>` accepts the prefix as a partial program. On an
// outcome-bearing tor the empty-branch arm never matches, so the
// outcome reports unhandled-branch — same as an unarmed call.
import std/io
import std/bridge
import std/runtime

tor echo { text: string }
proc echo|zig {
    @import("std").debug.print("echo: {s}\n", .{text});
}

tor fetch { path: string }
| found string
| missing string
proc fetch|zig {
    return .{ .found = "payload-9" };
}

tor probe {} -> string
proc probe|zig {
    const std = @import("std");
    var buf: [64]u8 = undefined;
    return std.fmt.bufPrint(&buf, "payload-9", .{}) catch unreachable;
}

std/runtime:register(scope: "binds") {
    echo(1)
    fetch(1)
    probe(1)
}

// Turn 1: two-step void chain runs in order.
tor turn1 { br: *std/bridge:Bridge<session> }
turn1 = std/bridge:run(br, source: "echo(text: \"a\") |> echo(text: \"b\")")
| result r |> std/io:print.ln("t1 result")
| error runerr |> std/bridge:error-decode(e: runerr)
    | validation-error v |> std/io:print.ln("FAIL t1 invalid {{ v:s }}")
    | event-denied ev |> std/io:print.ln("FAIL t1 denied {{ ev:s }}")
    | parse-error p |> std/io:print.ln("FAIL t1 parse {{ p.message:s }}")
    | shape-error sh |> std/io:print.ln("FAIL t1 shape {{ sh.message:s }}")
    | dispatch-error e |> std/io:print.ln("FAIL t1 dispatch {{ e.message:s }}")
    | exhausted _ |> std/io:print.ln("FAIL t1 exhausted")
    | scope-not-found s2 |> std/io:print.ln("FAIL t1 noscope {{ s2:s }}")
| residue _ |> std/io:print.ln("FAIL: residue outcome")
| unhandled-branch ub |> std/io:print.ln("FAIL t1 unhandled {{ ub.branch:s }}")
| defined d |> std/io:print.ln("FAIL t1 defined {{ d:s }}")
| partial p |> std/io:print.ln("FAIL t1 partial {{ p.report:s }}")

// Turn 2: three-step chain.
tor turn2 { br: *std/bridge:Bridge<session> }
turn2 = std/bridge:run(br, source: "echo(text: \"a\") |> echo(text: \"b\") |> echo(text: \"c\")")
| result r |> std/io:print.ln("t2 result")
| error runerr |> std/bridge:error-decode(e: runerr)
    | validation-error v |> std/io:print.ln("FAIL t2 invalid {{ v:s }}")
    | event-denied ev |> std/io:print.ln("FAIL t2 denied {{ ev:s }}")
    | parse-error p |> std/io:print.ln("FAIL t2 parse {{ p.message:s }}")
    | shape-error sh |> std/io:print.ln("FAIL t2 shape {{ sh.message:s }}")
    | dispatch-error e |> std/io:print.ln("FAIL t2 dispatch {{ e.message:s }}")
    | exhausted _ |> std/io:print.ln("FAIL t2 exhausted")
    | scope-not-found s2 |> std/io:print.ln("FAIL t2 noscope {{ s2:s }}")
| residue _ |> std/io:print.ln("FAIL: residue outcome")
| unhandled-branch ub |> std/io:print.ln("FAIL t2 unhandled {{ ub.branch:s }}")
| defined d |> std/io:print.ln("FAIL t2 defined {{ d:s }}")
| partial p |> std/io:print.ln("FAIL t2 partial {{ p.report:s }}")

// Turn 3: trailing `|>` — the say runs, the turn succeeds.
tor turn3 { br: *std/bridge:Bridge<session> }
turn3 = std/bridge:run(br, source: "echo(text: \"Hello\") |>")
| result r |> std/io:print.ln("t3 result")
| error runerr |> std/bridge:error-decode(e: runerr)
    | validation-error v |> std/io:print.ln("FAIL t3 invalid {{ v:s }}")
    | event-denied ev |> std/io:print.ln("FAIL t3 denied {{ ev:s }}")
    | parse-error p |> std/io:print.ln("FAIL t3 parse {{ p.message:s }}")
    | shape-error sh |> std/io:print.ln("FAIL t3 shape {{ sh.message:s }}")
    | dispatch-error e |> std/io:print.ln("FAIL t3 dispatch {{ e.message:s }}")
    | exhausted _ |> std/io:print.ln("FAIL t3 exhausted")
    | scope-not-found s2 |> std/io:print.ln("FAIL t3 noscope {{ s2:s }}")
| residue _ |> std/io:print.ln("FAIL: residue outcome")
| unhandled-branch ub |> std/io:print.ln("FAIL t3 unhandled {{ ub.branch:s }}")
| defined d |> std/io:print.ln("FAIL t3 defined {{ d:s }}")
| partial p |> std/io:print.ln("FAIL t3 partial {{ p.report:s }}")

// Turn 4: bare `|>` after an outcome-bearing tor — koruc refuses the
// spelling itself (anonymous `|>` is ambiguous across two outcomes).
tor turn4 { br: *std/bridge:Bridge<session> }
turn4 = std/bridge:run(br, source: "fetch(path: \"x\") |> echo(text: \"y\")")
| result r |> std/io:print.ln("t4 result")
| error runerr |> std/bridge:error-decode(e: runerr)
    | validation-error v |> std/io:print.ln("t4 invalid {{ v:s }}")
    | event-denied ev |> std/io:print.ln("FAIL t4 denied {{ ev:s }}")
    | parse-error p |> std/io:print.ln("FAIL t4 parse {{ p.message:s }}")
    | shape-error sh |> std/io:print.ln("FAIL t4 shape {{ sh.message:s }}")
    | dispatch-error e |> std/io:print.ln("FAIL t4 dispatch {{ e.message:s }}")
    | exhausted _ |> std/io:print.ln("FAIL t4 exhausted")
    | scope-not-found s2 |> std/io:print.ln("FAIL t4 noscope {{ s2:s }}")
| residue _ |> std/io:print.ln("FAIL: residue outcome")
| unhandled-branch ub |> std/io:print.ln("FAIL t4 unhandled {{ ub.branch:s }}")
| defined d |> std/io:print.ln("FAIL t4 defined {{ d:s }}")
| partial p |> std/io:print.ln("FAIL t4 partial {{ p.report:s }}")

// Turn 5 (was): indented continuation after a void step — kept below.
// Turn 6: bare `|>` after a `-> T` tor — the produced value has nowhere
// to land (koruc KORU092); the wire arm must name the outcome.
tor turn6 { br: *std/bridge:Bridge<session> }
turn6 = std/bridge:run(br, source: "probe() |> echo(text: \"y\")")
| result r |> std/io:print.ln("FAIL t6 result")
| error runerr |> std/bridge:error-decode(e: runerr)
    | validation-error v |> std/io:print.ln("t6 invalid {{ v:s }}")
    | event-denied ev |> std/io:print.ln("FAIL t6 denied {{ ev:s }}")
    | parse-error p |> std/io:print.ln("FAIL t6 parse {{ p.message:s }}")
    | shape-error sh |> std/io:print.ln("FAIL t6 shape {{ sh.message:s }}")
    | dispatch-error e |> std/io:print.ln("FAIL t6 dispatch {{ e.message:s }}")
    | exhausted _ |> std/io:print.ln("FAIL t6 exhausted")
    | scope-not-found s2 |> std/io:print.ln("FAIL t6 noscope {{ s2:s }}")
| residue _ |> std/io:print.ln("FAIL: residue outcome")
| unhandled-branch ub |> std/io:print.ln("FAIL t6 unhandled {{ ub.branch:s }}")
| defined d |> std/io:print.ln("FAIL t6 defined {{ d:s }}")
| partial p |> std/io:print.ln("FAIL t6 partial {{ p.report:s }}")

// Turn 5: an indented continuation after a void step.
tor turn5 { br: *std/bridge:Bridge<session> }
turn5 = std/bridge:run(br, source: "echo(text: \"a\")\n    |> echo(text: \"b\")")
| result r |> std/io:print.ln("t5 result")
| error runerr |> std/bridge:error-decode(e: runerr)
    | validation-error v |> std/io:print.ln("FAIL t5 invalid {{ v:s }}")
    | event-denied ev |> std/io:print.ln("FAIL t5 denied {{ ev:s }}")
    | parse-error p |> std/io:print.ln("FAIL t5 parse {{ p.message:s }}")
    | shape-error sh |> std/io:print.ln("FAIL t5 shape {{ sh.message:s }}")
    | dispatch-error e |> std/io:print.ln("FAIL t5 dispatch {{ e.message:s }}")
    | exhausted _ |> std/io:print.ln("FAIL t5 exhausted")
    | scope-not-found s2 |> std/io:print.ln("FAIL t5 noscope {{ s2:s }}")
| residue _ |> std/io:print.ln("FAIL: residue outcome")
| unhandled-branch ub |> std/io:print.ln("FAIL t5 unhandled {{ ub.branch:s }}")
| defined d |> std/io:print.ln("FAIL t5 defined {{ d:s }}")
| partial p |> std/io:print.ln("FAIL t5 partial {{ p.report:s }}")

[with]std/bridge:create(id: "b1", scope: "binds"): br
|> turn1(br)
|> turn2(br)
|> turn3(br)
|> turn4(br)
|> turn5(br)
|> turn6(br)
