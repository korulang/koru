// Pins: an arm on a void tor is a shape bug. `echo` declares no outcomes
// and no return — it issues nothing, so `| ok x |>` has nothing to arm
// and is refused pre-dispatch like any undeclared arm word. A `-> T`
// bare-return tor is different: it issues the anonymous `ok` outcome, so
// `probe() | ok h |>` stays legal and binds the returned value.
import std/io
import std/bridge
import std/runtime

tor probe {} -> string
proc probe|zig {
    var buf: [64]u8 = undefined;
    return @import("std").fmt.bufPrint(&buf, "payload-{d}", .{9}) catch unreachable;
}

tor echo { text: string }
proc echo|zig {
    @import("std").debug.print("echo: {s}\n", .{text});
}

std/runtime:register(scope: "binds") {
    probe(1)
    echo(1)
}

// Turn 1: `| ok x |>` on a void tor — nothing to arm, refused by name.
tor turn1 { br: *std/bridge:Bridge<session> }
turn1 = std/bridge:run(br, source: "echo(text: \"a\") | ok x |> echo(text: \"{{ x }}\")")
| result r |> std/io:print.ln("FAIL t1 result")
| error runerr |> std/bridge:error-decode(e: runerr)
    | validation-error v |> std/io:print.ln("t1 refused {{ v:s }}")
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

// Turn 2: a non-`ok` arm word on a void tor is refused the same way.
tor turn2 { br: *std/bridge:Bridge<session> }
turn2 = std/bridge:run(br, source: "echo(text: \"a\") | done x |> echo(text: \"{{ x }}\")")
| result r |> std/io:print.ln("FAIL t2 result")
| error runerr |> std/bridge:error-decode(e: runerr)
    | validation-error v |> std/io:print.ln("t2 refused {{ v:s }}")
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

// Turn 3 (control): `-> string` issues the anonymous `ok` — `| ok h |>`
// binds the returned value and runs.
tor turn3 { br: *std/bridge:Bridge<session> }
turn3 = std/bridge:run(br, source: "probe() | ok h |> echo(text: \"{{ h }}\")")
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


// Turn 4: an unbound `| ok |>` on a void tor refuses the same way —
// an arm word has nothing to arm on a tor that issues no outcome.
tor turn4 { br: *std/bridge:Bridge<session> }
turn4 = std/bridge:run(br, source: "echo(text: \"a\") | ok |> echo(text: \"b\")")
| result r |> std/io:print.ln("FAIL t4 result")
| error runerr |> std/bridge:error-decode(e: runerr)
    | validation-error v |> std/io:print.ln("t4 refused {{ v:s }}")
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

[with]std/bridge:create(id: "b1", scope: "binds"): br
|> turn1(br)
|> turn2(br)
|> turn3(br)
|> turn4(br)
