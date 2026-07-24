// Pins: `|?` catch-all expands remaining optional arms when the consumer
// is an event body (subflow), same as top-level (355_002 / 355_005).
// Gallery on-q wants: text pages absorb `q`; `|? |> quit()` for the rest.
import std/io

event page-route { page: i64 }
| ?catalog
| ?text-input
| ?style

page-route = if(page == 0)
| then => catalog
| else |> if(page == 1)
    | then => text-input
    | else => style

event on-q { page: i64 }
on-q = page-route(page)
| text-input |> std/io:print.ln("keep")
|? |> std/io:print.ln("quit")

on-q(page: 0)
on-q(page: 1)
on-q(page: 2)
