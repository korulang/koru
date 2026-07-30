// PIN (diagnostic quality, human-reported): this program is CORRECTLY rejected,
// with a good diagnostic, and the author is then shown a crash report.
//
// Observed 2026-07-30, in order, for this one mistake:
//
//   1. error[KORU030]: Resource 'response' obligation <tainted!> was not
//      discharged. Call: validate-response
//        --> doodle.k:10:0  + caret
//                                        ← CORRECT. Names the resource, the
//                                          obligation, the fix, the line.
//   2. ❌ Compiler coordination error: Auto-discharge failed (multiple disposal
//      options or no disposal event)
//                                        ← vaguer, no location, and it
//                                          CONTRADICTS (1): KORU030 names
//                                          exactly one disposer
//   3. error: CompilerCoordinationFailed
//      backend.zig:97:13 in emit (backend)
//      backend.zig:204:28 in main (backend)
//                                        ← a Zig error-return trace through
//                                          GENERATED files
//   4. ──── diagnostics (1) ──── re-print of (1), location stripped
//
// Four renderings of one mistake; one of them is the diagnostic.
//
// THE MECHANISM (src/main.zig:930-938 emits this into backend.zig):
//
//     if (result.is_error) {
//         __koru_std.debug.print("❌ Compiler coordination error: {s}\n", .{e});
//         return error.CompilerCoordinationFailed;
//     }
//
// and the generated main does `try RuntimeEmitter.emit(...)`, so the error
// escapes main and Zig's runtime prints (3). The diagnostic was ALREADY delivered
// by then — `reporter.printErrors` runs back in compiler.kz:2864. So (3) is not a
// fallback for a missing message. It is the control flow becoming visible:
// REJECTING A PROGRAM AND CRASHING SHARE ONE EXIT PATH, and Zig's default
// rendering of an error escaping main is a crash report.
//
// This pin asserts exactly that separation and nothing more: the good diagnostic
// must be present, and no crash-shaped exit may accompany it. It does NOT pin the
// removal of (2) or (4) — see the concept's Open section; those are wording and
// double-report questions with their own answers.
//
// Cost of closing, measured 2026-07-30: nothing depends on the leak. Zero tests
// assert on `CompilerCoordinationFailed`. The category tokens in EXPECT
// (BACKEND_RUNTIME_ERROR etc., 36 tests) are skipped as informational by
// regression_lib.sh:191 — the assertions are MUST_ERROR + CONTAINS/NOT_CONTAINS.
// The one test naming the summary line, 430_001_user_coordinator, asserts a
// USER-SUPPLIED coordinator message ("Compiler coordination error: Testing!") and
// stays green as long as the print in (2) survives and only the exit path changes.
import std/io

tor get-from-network {} -> string<tainted!>
get-from-network -> "Hello, World!"

tor validate-response { response: string<!tainted> } -> string
validate-response -> response

get-from-network(): response
|> std/io:print.ln("From network: {{response:s}}")
