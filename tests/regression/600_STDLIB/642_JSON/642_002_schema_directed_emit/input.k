// Pins std/json:emit — schema-directed compile-time JSON emission. The
// record literal at `value:` is the output schema: keys are the JSON key
// names, each value's type resolves at compile time from the bindings in
// scope — a destructure field, a literal string/number/bool/null, a
// `binding.field` path into a record payload, a nested `{...}` record
// literal, `?T` (null or inner), `[]T` elementwise. The `: body` return
// bind carries string<emitted!>, discharged only by `std/json:emit.free` —
// the same contract yyjson's render/render.free draws.

import std/io
import std/json

// literals of every shape + nested object + explicit null
std/json:emit(value: { service: "orisha", port: 8080, tls: true, meta: { tier: "bench", weight: 1.5 }, note: null }): body
    |> std/io:print.ln("{{ body:s }}") |> std/json:emit.free(text: body)

// bindings resolved from an upstream parse destructure — including a
// `binding.field` path, a `?string` (null-or-inner), and a `[]string`.
std/json:parse(input: "{\"name\":\"ada\",\"age\":36,\"addr\":{\"city\":\"paris\"},\"nick\":null,\"tags\":[\"a\",\"b\"]}")
| malformed { message, offset } |> std/io:print.ln("BAD {{ offset:d }}: {{ message:s }}")
| ok _:{ name: string, age: i64, addr: { city: string }, nick: ?string, tags: []string } |> std/json:emit(value: { who: name, years: age, town: city, alias: nick, seen: tags, active: true }): out
    |> std/io:print.ln("{{ out:s }}") |> std/json:emit.free(text: out)

// same, with the optional field present
std/json:parse(input: "{\"name\":\"cid\",\"age\":9,\"addr\":{\"city\":\"oslo\"},\"nick\":\"ciddy\",\"tags\":[]}")
| malformed { message, offset } |> std/io:print.ln("BAD2 {{ offset:d }}: {{ message:s }}")
| ok _:{ name: string, age: i64, addr: { city: string }, nick: ?string, tags: []string } |> std/json:emit(value: { who: name, years: age, town: city, alias: nick, seen: tags }): out
    |> std/io:print.ln("{{ out:s }}") |> std/json:emit.free(text: out)

// escapes: quote, backslash, newline, tab, 0x01 — each inside its own
// 8-byte scan word, with >8-byte clean runs on both sides
std/json:emit(value: { esc: "0123456789\"\\\n\t\x01abcdefghij" }): ebody
    |> std/io:print.ln("{{ ebody:s }}") |> std/json:emit.free(text: ebody)
