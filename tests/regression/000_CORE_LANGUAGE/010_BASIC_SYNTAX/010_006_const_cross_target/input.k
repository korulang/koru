// Cross-target `const {}`: a Koru-native const block must declare module-scope
// names that a sibling `print.blk` interpolation can reference on BOTH targets.
// This is 010_000 with the host-const companions replaced by a Koru `const {}`
// block — so it exercises the const KEYWORD, not host `const` lines.
//
// Zig splices the decls into the main_module struct (see 010_004). JS must hoist
// them to module top-level (before `const main_module`). Before the
// `[declaration]` hoist in js_emitter.zig, the JS const landed inside flow0()'s
// function body — invisible to the print.blk flow — so the JS run failed
// (ReferenceError: name is not defined) while Zig passed.
import std/io

const {
    name: "World"
    count: 42
}

std/io:print.blk {
    Hello, {{ name:s }}!
    The answer is {{ count:d }}.
}
