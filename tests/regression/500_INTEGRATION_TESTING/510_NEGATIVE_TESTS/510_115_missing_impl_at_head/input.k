// CONTROL (green): KORU047 fires when an event with no implementation is invoked
// at a FLOW HEAD. This is the position where the wall works.
//
// This pin exists because KORU047 had NO test anywhere in the suite — not one,
// at any position — while its reach was being relied on. Per
// [[frag-the-minimal-test-of-a-wall-cannot-test-its-reach]] a wall whose only
// coverage is a one-line flow is unmeasured past position one; a wall with zero
// coverage is not even that. This file is the missing head pin.
//
// It must stay green through any fix to 510_116/510_117. If closing the reach
// reddens this, the wall moved rather than widened.
//
// Both spellings of the head fire today and both are worth holding: this file
// binds the result (`: clean`), and the unbound head form
// (`validate-response(response: "hi") |> ...`) was verified to fire identically
// on 2026-07-30. The bind is not what triggers the check at a head — which is
// exactly why its absence mid-chain is not the explanation either.
import std/io

tor validate-response { response: string } -> string

validate-response(response: "hi"): clean
|> std/io:print.ln("got {{clean:s}}")
