// Test 430_010: AST Dump at Multiple Pipeline Stages
//
// Override frontend and analysis to dump AST at each stage.
// Demonstrates introspection into the compiler pipeline.
//
// Expected output (to stdout during compilation):
//   === AST DUMP: post-elaborate ===
//   { ... JSON AST ... }
//   === AST DUMP: post-analysis ===
//   { ... JSON AST ... }

import std/compiler
import std/io

// ============================================================================
// DUMP AST AFTER FRONTEND
// ============================================================================

std/compiler:elaborate = std/compiler:elaborate.default(ctx): c |> std/compiler:ast-dump(ctx: c, flag: "post-elaborate") -> c

// ============================================================================
// DUMP AST AFTER ANALYSIS
// ============================================================================

std/compiler:analysis = std/compiler:analysis.default(ctx)
| ctx c |> std/compiler:ast-dump(ctx: c, flag: "post-analysis") => ctx c
| failed f => failed { f.ctx, f.message }

// ============================================================================
// THE PROGRAM
// ============================================================================

std/io:print.ln("AST was dumped at 2 stages!")
