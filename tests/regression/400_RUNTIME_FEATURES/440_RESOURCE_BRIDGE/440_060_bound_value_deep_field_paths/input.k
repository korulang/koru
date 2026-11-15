// Pins: a dotted path on a bound value resolves segment by segment, at
// any depth — `{{ u.user.first_name }}` and a bare arg
// `u.user.first_name` both reach the leaf. A bound payload's first
// level is declared fields; below that, a composite field carries JSON
// object text (the only composite FieldValue) and the descent continues
// inside that text — compiled Koru resolves the same paths at compile
// time.
//
// Shape guarded: a nested-object field in an arm-bound payload is
// addressable by path. Refusals name the failing prefix and segment —
// `'<path>' — '<prefix>' carries no field '<seg>'` for a missing key,
// `'<prefix>' is a scalar, not a record` for a leaf mid-path. One-level
// `name.field` keeps today's behavior exactly.
import std/io
import std/bridge
import std/runtime

tor probe { path: string }
| found { id: string, user: string, membership: string }
| absent string
proc probe|zig {
    _ = path;
    return .{ .found = .{ .id = "u7", .user = "{\"first_name\":\"Zo\\u00eb\",\"last_name\":\"Li\",\"greeting\":\"line1\\nline2\"}", .membership = "gold" } };
}

tor echo { text: string }
proc echo|zig {
    @import("std").debug.print("echo: {s}\n", .{text});
}

std/runtime:register(scope: "binds") {
    probe(1)
    echo(1)
}

// Turn 1: two-level+ interpolation — u.user is a field carrying JSON object
// text, and `.first_name` descends inside it.
tor turn1 { br: *std/bridge:Bridge<session> }
turn1 = std/bridge:run(br, source: "probe(path: \"x\") | found u |> echo(text: \"{{ u.user.first_name }}\")")
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

// Turn 2: the same path as a bare arg value.
tor turn2 { br: *std/bridge:Bridge<session> }
turn2 = std/bridge:run(br, source: "probe(path: \"x\") | found u |> echo(text: u.user.first_name)")
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

// Turn 3: a missing key mid-path names the failing prefix and the keys
// that level actually has.
tor turn3 { br: *std/bridge:Bridge<session> }
turn3 = std/bridge:run(br, source: "probe(path: \"x\") | found u |> echo(text: \"{{ u.user.bogus.x }}\")")
| result r |> std/io:print.ln("FAIL t3 result")
| error runerr |> std/bridge:error-decode(e: runerr)
    | validation-error v |> std/io:print.ln("FAIL t3 invalid {{ v:s }}")
    | event-denied ev |> std/io:print.ln("FAIL t3 denied {{ ev:s }}")
    | parse-error p |> std/io:print.ln("FAIL t3 parse {{ p.message:s }}")
    | shape-error sh |> std/io:print.ln("FAIL t3 shape {{ sh.message:s }}")
    | dispatch-error e |> std/io:print.ln("t3 refused {{ e.message:s }}")
    | exhausted _ |> std/io:print.ln("FAIL t3 exhausted")
    | scope-not-found s2 |> std/io:print.ln("FAIL t3 noscope {{ s2:s }}")
| residue _ |> std/io:print.ln("FAIL: residue outcome")
| unhandled-branch ub |> std/io:print.ln("FAIL t3 unhandled {{ ub.branch:s }}")
| defined d |> std/io:print.ln("FAIL t3 defined {{ d:s }}")
| partial p |> std/io:print.ln("FAIL t3 partial {{ p.report:s }}")

// Turn 4: a scalar mid-path is not a record — the refusal names what
// can't be read.
tor turn4 { br: *std/bridge:Bridge<session> }
turn4 = std/bridge:run(br, source: "probe(path: \"x\") | found u |> echo(text: \"{{ u.id.x }}\")")
| result r |> std/io:print.ln("FAIL t4 result")
| error runerr |> std/bridge:error-decode(e: runerr)
    | validation-error v |> std/io:print.ln("FAIL t4 invalid {{ v:s }}")
    | event-denied ev |> std/io:print.ln("FAIL t4 denied {{ ev:s }}")
    | parse-error p |> std/io:print.ln("FAIL t4 parse {{ p.message:s }}")
    | shape-error sh |> std/io:print.ln("FAIL t4 shape {{ sh.message:s }}")
    | dispatch-error e |> std/io:print.ln("t4 refused {{ e.message:s }}")
    | exhausted _ |> std/io:print.ln("FAIL t4 exhausted")
    | scope-not-found s2 |> std/io:print.ln("FAIL t4 noscope {{ s2:s }}")
| residue _ |> std/io:print.ln("FAIL: residue outcome")
| unhandled-branch ub |> std/io:print.ln("FAIL t4 unhandled {{ ub.branch:s }}")
| defined d |> std/io:print.ln("FAIL t4 defined {{ d:s }}")
| partial p |> std/io:print.ln("FAIL t4 partial {{ p.report:s }}")

// Turn 5 (control): one-level paths render exactly as before — a leaf
// string, and a whole nested object as JSON text.
tor turn5 { br: *std/bridge:Bridge<session> }
turn5 = std/bridge:run(br, source: "probe(path: \"x\") | found u |> echo(text: \"{{ u.id }}|{{ u.user }}\")")
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


// Turn 6: JSON escapes inside a nested value decode at the leaf —
// `Zo\u00eb` renders `Zoë`, `line1\nline2` renders the newline.
tor turn6 { br: *std/bridge:Bridge<session> }
turn6 = std/bridge:run(br, source: "probe(path: \"x\") | found u |> echo(text: \"{{ u.user.first_name }}|{{ u.user.greeting }}\")")
| result r |> std/io:print.ln("t6 result")
| error runerr |> std/bridge:error-decode(e: runerr)
    | validation-error v |> std/io:print.ln("FAIL t6 invalid {{ v:s }}")
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

[with]std/bridge:create(id: "b1", scope: "binds"): br
|> turn1(br)
|> turn2(br)
|> turn3(br)
|> turn4(br)
|> turn5(br)
|> turn6(br)
