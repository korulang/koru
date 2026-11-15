// Pins: a collected `*T` tor mints an opaque resource token — the wire
// never sees a pointer, only "h:Res:xxxxxx". The suffix is seeded hex,
// not a sequence (Lars ruling 2026-09-07/08, carried to the pool
// 2026-10-20): `h:Res:1` used to resolve because a counter was
// predictable — under the ruling it is a fabrication like any other.
// Binding is the only legal access: the `rN` name the report bound
// resolves across turns, literal token spellings refuse, and a
// discharged token refuses as spent.
//
// Output is kept deterministic: minted hex is never printed — only
// handle counts, the proc's own `used v=42`, and refusal text that
// quotes tokens spelled literally in this file.
import std/io
import std/bridge
import std/runtime
import reslib/res

std/runtime:register(scope: "res") {
    reslib.res:mint -> mint(1)
    reslib.res:grab -> grab(1)
    reslib.res:release -> release(1)
}

tor step { br: *std/bridge:Bridge<session>, source: string<*>, tag: string }
step = std/bridge:run(br, source)
| result r |> std/io:print.ln("{{ tag:s }}: ok (holds {{ r.handles:d }})")
| unhandled-branch ub |> std/io:print.ln("{{ tag:s }} FAIL unhandled {{ ub.branch:s }}")
| defined d |> std/io:print.ln("{{ tag:s }} FAIL defined {{ d:s }}")
| error runerr |> std/bridge:error-decode(e: runerr)
    | dispatch-error e |> std/io:print.ln("{{ tag:s }} refused: {{ e.message:s }}")
    | event-denied ev |> std/io:print.ln("{{ tag:s }} FAIL denied {{ ev:s }}")
    | parse-error p |> std/io:print.ln("{{ tag:s }} FAIL parse {{ p.message:s }}")
    | validation-error v |> std/io:print.ln("{{ tag:s }} FAIL invalid {{ v:s }}")
    | shape-error sh |> std/io:print.ln("{{ tag:s }} FAIL shape {{ sh.message:s }}")
    | exhausted _ |> std/io:print.ln("{{ tag:s }} FAIL exhausted")
    | scope-not-found s2 |> std/io:print.ln("{{ tag:s }} FAIL noscope {{ s2:s }}")
| residue _ |> std/io:print.ln("{{ tag:s }} FAIL residue outcome")
| partial p |> std/io:print.ln("{{ tag:s }} FAIL unexpected partial")

// Same, but prints no report/message — for steps whose text would carry
// the minted (random) token.
tor step-quiet { br: *std/bridge:Bridge<session>, source: string<*>, tag: string }
step-quiet = std/bridge:run(br, source)
| result r |> std/io:print.ln("{{ tag:s }}: ok (holds {{ r.handles:d }})")
| unhandled-branch ub |> std/io:print.ln("{{ tag:s }} FAIL unhandled {{ ub.branch:s }}")
| defined d |> std/io:print.ln("{{ tag:s }} FAIL defined {{ d:s }}")
| error runerr |> std/bridge:error-decode(e: runerr)
    | dispatch-error e |> std/io:print.ln("{{ tag:s }} refused — {{ e.event_name:s }} did not run")
    | event-denied ev |> std/io:print.ln("{{ tag:s }} FAIL denied {{ ev:s }}")
    | parse-error p |> std/io:print.ln("{{ tag:s }} FAIL parse {{ p.message:s }}")
    | validation-error v |> std/io:print.ln("{{ tag:s }} FAIL invalid {{ v:s }}")
    | shape-error sh |> std/io:print.ln("{{ tag:s }} FAIL shape {{ sh.message:s }}")
    | exhausted _ |> std/io:print.ln("{{ tag:s }} FAIL exhausted")
    | scope-not-found s2 |> std/io:print.ln("{{ tag:s }} FAIL noscope {{ s2:s }}")
| residue _ |> std/io:print.ln("{{ tag:s }} FAIL residue outcome")
| partial p |> std/io:print.ln("{{ tag:s }} FAIL unexpected partial")

[with]std/bridge:create(id: "tok", scope: "res"): br
|> step(br, source: "mint() | ok h |>", tag: "mint")
|> step(br, source: "grab(r: r1)", tag: "bound-grab")
|> step(br, source: "grab(r: \"h:Res:1\")", tag: "seq-guess")
|> step(br, source: "grab(r: \"h:Res:ffffff\")", tag: "hex-guess")
|> step(br, source: "release(r: r1)", tag: "release")
|> step-quiet(br, source: "grab(r: r1)", tag: "spent-grab")
