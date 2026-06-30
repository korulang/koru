// PINS A BUG (not yet fixed — see comment below): a bare, non-braced
// `const NAME: Type = value;` line in a pure-Koru `.k` file is neither
// accepted nor cleanly rejected. It SHOULD be rejected at the parser
// boundary: `.k` files have no host-Zig escape at all (`~`-prefixed lines
// are already rejected with PARSE003 — see 's parser.zig:677-696), and the
// only legal `const` shape in a `.k` file is the braced declaration form
// from koru_std/declarations.kz: `const { name: value, ... }`.
//
// Instead, `src/parser.zig` synthesizes a leading `~` for any non-`|`/`!`
// top-level `.k` line (parser.zig:719-727) and dispatches it through the
// general construct machinery. A bare `const NAME: Type = value;` line
// doesn't match the braced `const {}` keyword shape, so it falls through
// into the generic `name = call(...)` flow-implementation grammar instead,
// which mis-tokenizes it into a bogus flow item:
//   { "type": "flow", "invocation": { "event": ["500000;"] }, "impl_of": [" usize"] }
// (verified via `koruc --ast-json` on this exact file). That phantom
// "implements abstract event `usize`" item then poisons
// `validate_abstract_impl.zig`'s impl/abstract-event pairing, which is what
// actually fires below — `ImplTargetNotAbstract`, a raw Zig error with a
// non-deterministic address-laden stack trace, not a koru-level diagnostic
// naming the real offending line.
//
// Found 2026-06-30 while fixing the prime-sieve drag-race `faithful.k` entry
// (forcing a runtime-sized `std/field:new` allocation rather than a
// comptime-literal one). Lars: capture and pin now; root-cause + fix later.

import std/io

const SIEVE_BITS: usize = 500000;

std/io:print.ln("hi")
