// Pins: the test block std/compiler's own test lowering generates must reach
// the emitted program.
//
// processTestFlow (koru_std/compiler.kz:1423) parses a test body, substitutes
// each mocked event by writing `const __mock_result_N = <mocked branch>` plus
// the binding extraction for the branch the mock forces
// (compiler.kz:1722-1773), and hands the finished `test "..." { ... }` back as
// an inline_code item that replaces the test flow.
//
// That pass only ever sees a live test flow when the coordinator puts
// test-generation ahead of elaborate: std/testing's test transform
// (koru_std/testing.kz:225) runs inside elaborate's run-pre-transforms
// (compiler.kz:1249) and consumes every test invocation, so under the default
// order (compiler.kz:757) test-generation finds nothing to do. The coordinator
// override below is the shape 430_COORDINATION/8401_custom_coordinator_bug and
// 430_008_pipeline_profiling already pin.
//
// post.sh reads output_emitted.zig with the variant-coverage checker's own
// bare-token predicate and requires a __mock_result_N token in bare code.
// See BUG.md.

import std/compiler
import std/optimizer
import std/testing
import std/io

std/compiler:coordinate = std/compiler:context-create(program_ast, allocator): c0 |> std/compiler:test-generation(ctx: c0): c1 |> std/compiler:elaborate(ctx: c1): c2 |> std/compiler:transform-taps(ctx: c2): c3 |> std/compiler:analysis(ctx: c3)
| ctx c4 |> std/optimizer:optimize(ctx: c4): c5 |> std/compiler:emission(ctx: c5): c6 => coordinated {
    c6.ctx.ast,
    c6.code,
    metrics: "test-generation ran before elaborate"
  }
| failed f => error f.message

tor withdraw { amount: u32 }
| success u32
| insufficient-funds

test(mock substitution binds the mocked branch) {
    withdraw => success 50
    withdraw(amount: 100)
    | success s |> _
}

std/io:print.ln("test-generation pass ran")
