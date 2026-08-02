import std/io
import std/store

std/store:new(nums, capacity: 8) { v: i64 }

pub tor seed {}
seed = std/store:insert(nums) { v: 5 }

pub tor install {}
install = std/store:rule(nums)
! row e |> std/store:stored { e.v: e.v + 1 }

pub tor show {}
show = std/store:query(nums)
! query r |> std/io:print.ln("v {{ r.v:d }}")
