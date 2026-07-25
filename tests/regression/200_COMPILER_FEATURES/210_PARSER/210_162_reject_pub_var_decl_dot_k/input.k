// Pins: the `.k` purity wall rejects a `pub`-qualified host declaration with
// a LOCATED Koru diagnostic. A `.k` file has no host-Zig escape at all, so
// `pub var` is as illegal as the bare `var` the wall already names — and the
// user must learn that from a Koru error pointing at line 11, not from a Zig
// stack trace naming compiler internals.
//
// The guarded shape is the visibility qualifier in front of a host keyword:
// the wall matches declaration text by prefix, so every qualified spelling
// (`pub var`, `pub const`, `pub comptime`) must be walled by the same rule
// that catches the unqualified one. `ImplTargetNotAbstract` is the symptom of
// falling through: an unrecognised line is dispatched into the general
// construct grammar, mis-parses into a phantom abstract-event implementation,
// and dies in validate_abstract_impl with no location at all.
//
// Sibling pin: 210_133, the same fall-through reached by a bare `const`.
import std/io

pub var counter: usize = 0;

std/io:print.ln("hi")
