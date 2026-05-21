// Facade module for libkoru-srclib.a — the static library of compiler internals
// that gets linked into per-user `./backend` executables.
//
// Re-exports every src/*.zig module that the generated backend.zig and
// backend_output_emitted.zig collectively reference. Zig compiles the
// transitive closure into this library's object code; per-user builds
// then link against it instead of recompiling src/ from source.
//
// To use: a consumer addObjectFile(libkoru-srclib.a) and replaces its
// `@import("ast_functional")`-style calls with `extern fn` declarations
// for the specific symbols needed. The consumer compilation unit
// shrinks to just backend.zig + program_ast.zig + a few type modules.

pub const annotation_parser = @import("annotation_parser");
pub const ast = @import("ast");
pub const ast_functional = @import("ast_functional");
pub const ast_serializer = @import("ast_serializer");
pub const auto_discharge_inserter = @import("auto_discharge_inserter");
pub const codegen_utils = @import("codegen_utils");
pub const dead_strip = @import("dead_strip");
pub const emit_build_zig = @import("emit_build_zig");
pub const emitter_helpers = @import("emitter_helpers");
pub const errors = @import("errors");
pub const expression_parser = @import("expression_parser");
pub const flow_checker = @import("flow_checker");
pub const log = @import("log");
pub const parser = @import("parser");
pub const phantom_semantic_checker = @import("phantom_semantic_checker");
pub const purity_analyzer = @import("purity_analyzer");
pub const runtime_registry = @import("runtime_registry");
pub const shape_checker = @import("shape_checker");
pub const tap_registry = @import("tap_registry");
pub const tap_transformer = @import("tap_transformer");
pub const transform_pass_runner = @import("transform_pass_runner");
pub const type_registry = @import("type_registry");
pub const visitor_emitter = @import("visitor_emitter");
