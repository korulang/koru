// The `cond`-arm twin of 510_119: a branch constructor in a `cond` arm must
// name a branch the IMPLEMENTED tor declares.
//
// Why a second pin rather than one: 320_137 is the green pin for "cond arms
// construct named branches", and every target in it is a BARE name
// (`=> catalog`, `=> progress`, `=> other`). 240_subflow_defines_semantics is
// the same — `=> stopped`, `=> iterated`, all bare. So the corpus proved that
// cond arms can construct a branch and said nothing about whether a WRONG one
// is refused there. Measured 2026-08-04: across 1577 regression inputs, 98 use
// a `=>` arm target and ZERO pinned a refusal of a bad name in that position.
//
// The constructed name resolves against the tor being IMPLEMENTED (`divide`),
// not the tor being invoked (`cond`) — the two branch sets are different, and
// using the invoked one is the obvious wrong implementation of this check.
//
// Belief: concepts/frag-a-fix-lands-in-one-lowering-path.md
import std/io

pub tor divide { a: i64, b: i64 }
| ok i64
| divzero

divide = cond(b)
| c z when z == 0 => divzero
| c _ => nosuchbranch 7

divide(a: 84, b: 2)
| ok q |> std/io:print.ln("q={{ q:d }}")
| divzero |> std/io:print.ln("divzero")
