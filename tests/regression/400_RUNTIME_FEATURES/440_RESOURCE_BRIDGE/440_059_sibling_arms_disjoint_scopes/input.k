// Pins: arm bindings are scoped to the arm's own path, not its siblings.
// `| found p |> ... | absent p |> ...` — two sibling arms binding `p` —
// is legal: the arms are disjoint scopes and only one ever fires
// (compiled Koru agrees — an arm body is a block). The check that fires
// is the ANCESTOR rule: an arm re-binding a name an enclosing arm on its
// own path already bound is shadowing, and Koru has no shadowing.
//
// Shape guarded: same-name siblings (flat `|` lines and inline arms) run
// with their own payload; an indented arm that re-binds an enclosing
// arm's name refuses as validation-error, and turn-bound name reuse —
// an arm name a previous item or turn already used — stays legal.
import std/io
import std/bridge
import std/runtime

tor probe { path: string }
| found string
| absent string
proc probe|zig {
    if (@import("std").mem.eql(u8, path, "hit")) {
        return .{ .found = "hit" };
    }
    return .{ .absent = "miss" };
}

tor echo { text: string }
proc echo|zig {
    @import("std").debug.print("echo: {s}\n", .{text});
}

std/runtime:register(scope: "binds") {
    probe(1)
    echo(1)
}

// Turn 1: same-name sibling arms across lines — `found p` and `absent p`
// are disjoint scopes; the fired arm binds its own payload.
tor turn1 { br: *std/bridge:Bridge<session> }
turn1 = std/bridge:run(br, source: "probe(path: \"hit\")\n| found p |> echo(text: \"f {{ p }}\")\n| absent p |> echo(text: \"a {{ p }}\")")
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

// Turn 2: same-name siblings inline on one line — the flat-segment
// spelling is the same construct.
tor turn2 { br: *std/bridge:Bridge<session> }
turn2 = std/bridge:run(br, source: "probe(path: \"hit\") | found p |> echo(text: \"f {{ p }}\") | absent p |> echo(text: \"a {{ p }}\")")
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

// Turn 3: the ANCESTOR refusal — an arm indented under `found u` re-binds
// `u` while the enclosing arm already holds it.
tor turn3 { br: *std/bridge:Bridge<session> }
turn3 = std/bridge:run(br, source: "probe(path: \"hit\")\n| found u |> probe(path: \"miss\")\n    | found u |> echo(text: \"inner\")")
| result r |> std/io:print.ln("FAIL t3 result")
| error runerr |> std/bridge:error-decode(e: runerr)
    | validation-error v |> std/io:print.ln("t3 refused {{ v:s }}")
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

// Turn 4 (control): a nested arm binding a NEW name under `found u` —
// the legal deep binding the refusal is not about.
tor turn4 { br: *std/bridge:Bridge<session> }
turn4 = std/bridge:run(br, source: "probe(path: \"hit\")\n| found u |> probe(path: \"miss\")\n    | found v |> echo(text: \"{{ u }} {{ v }}\")\n    | absent v |> echo(text: \"{{ u }} {{ v }}\")")
| result r |> std/io:print.ln("t4 result")
| error runerr |> std/bridge:error-decode(e: runerr)
    | validation-error v |> std/io:print.ln("FAIL t4 invalid {{ v:s }}")
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

// Turn 5 (control): `u` again — an arm name a previous turn already
// bound is fresh scope, not a shadow.
tor turn5 { br: *std/bridge:Bridge<session> }
turn5 = std/bridge:run(br, source: "probe(path: \"hit\") | found u |> echo(text: \"again {{ u }}\")")
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
