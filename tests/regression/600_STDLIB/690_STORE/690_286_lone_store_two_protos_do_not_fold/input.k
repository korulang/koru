// Two protos in one store are two concepts. Foo and Bar both name a leaf
// `x`, same scalar, and the lone store still keeps two cells (`foo.x`,
// `bar.x`). Same bare name is not a fold here. Fold is only a store-set
// join on (path-from-store-root, type).
import std/io
import std/proto
import std/store

std/proto(Foo) {
    x: i64
}

std/proto(Bar) {
    x: i64
}

std/store:new(pair, capacity: 8) { foo: Foo, bar: Bar }

std/store:insert(pair) { foo.x: 3, bar.x: 7 }

std/store:query(pair)
! query e |> std/io:print.ln("foo {{ e.foo.x:d }}")

std/store:query(pair)
! query e |> std/io:print.ln("bar {{ e.bar.x:d }}")
