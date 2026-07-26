import std/io
import std/store

std/store:new(c) { v: 0[i64] }

std/store:watch(c)
! v x |> std/io:print.ln("a")
    |> std/io:print.ln("b")
    |> std/io:print.ln("d")

pub tor run {}
run = std/store:stored { c.v: 1 }
