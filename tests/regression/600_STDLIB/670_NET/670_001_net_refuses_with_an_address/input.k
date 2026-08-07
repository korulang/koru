// Reaching for `std/net` refuses, and the refusal names where the real surface
// lives.
//
// `std/net` declares a socket vocabulary that koru_std does not implement. The
// shape this pins is that an unimplemented surface fails LOUDLY and carries an
// address — not that it is absent. A program asking for `tcp.listen` is told to
// use Orisha for a server and `koru/curl` for a client.
//
// The refusal is on USE, not on import: a program may import the module and
// still build, so the module can carry its declarations and its teaching.
// 670_002 pins that half.

import std/io
import std/net

std/net:tcp.listen(port: 8080)
| listening l |> std/io:print.ln("listening")
| error e |> std/io:print.ln("error")
