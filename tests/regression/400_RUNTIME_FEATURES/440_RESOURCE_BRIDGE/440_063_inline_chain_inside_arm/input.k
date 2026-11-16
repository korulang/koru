// Pins: an inline `|>` inside an arm body chains after the arm's step,
// not on the head call — `| found u |> echo(u) |> echo("b")` is the
// canonical Koru shape (208_simple_server_flow) spelled on one wire
// line. The second echo must run inside the found arm; the missing arm
// stays a sibling. Before the fix the trailing `|>` detached to the
// head call and the turn refused as an ambiguous anonymous pipe.
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

std/runtime:register(scope: "binds") {
    echo(1)
    fetch(1)
}

// Turn 1: arm body chains two void steps inline; missing arm present.
tor turn1 { br: *std/bridge:Bridge<session> }
turn1 = std/bridge:run(br, source: "fetch(path: \"x\") | found u |> echo(text: u) |> echo(text: \"b\") | missing _ |> _")
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

// Turn 2: three-step chain inside the arm.
tor turn2 { br: *std/bridge:Bridge<session> }
turn2 = std/bridge:run(br, source: "fetch(path: \"x\") | found u |> echo(text: u) |> echo(text: \"b\") |> echo(text: \"c\") | missing _ |> _")
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

[with]std/bridge:create(id: "b1", scope: "binds"): br
|> turn1(br)
|> turn2(br)
