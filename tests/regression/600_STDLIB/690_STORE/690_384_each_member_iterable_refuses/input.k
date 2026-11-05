// An `! each` over a member-expression iterable (`for(bag.items)` — not a
// range, not an `&[_]T{…}` literal, not a bare `for(name)`) has no element
// type the sweep boundary can name. The refusal names the iterable and the
// teaching: lift the value through a typed binding first.
import std/io
import std/store

std/store:new(spec, capacity: 8) { d: i64 }
std/store:insert(spec) { d: 10 }

pub tor run { bag: { items: [_]i64 } }
run = std/store:query(spec)
    ! query s
        |> for(bag.items)
            ! each i |> std/store:query(spec)
                ! query p when p.d == i
                    |> std/io:print.ln("hit")
