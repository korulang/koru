const std = @import("std");

pub fn build(__koru_b: *std.Build) void {
    const __koru_target = __koru_b.standardTargetOptions(.{});
    const __koru_optimize = __koru_b.standardOptimizeOption(.{});

    const __koru_exe = __koru_b.addExecutable(.{
        .name = "backend",
        .root_module = __koru_b.createModule(.{
            .root_source_file = __koru_b.path("backend.zig"),
            .target = __koru_target,
            .optimize = __koru_optimize,
        }),
    });
    // koru_allocator() backs onto std.heap.c_allocator (real libc malloc/free,
    // not a debug allocator that munmaps on every free) — needs libc linked.
    __koru_exe.linkLibC();

    // Module: compiler
    const compiler_build_0 = struct {
        fn call(b: *std.Build, exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
            _ = &b; _ = &exe; _ = &target; _ = &optimize; // Suppress unused warnings
// Calculate relative path from test directory to repo root
// This will be baked into the generated build.zig
const REL_TO_ROOT = "/Users/larsde/src/koru";

// Errors module - error reporting
const errors_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/errors.zig" },
    .target = target,
    .optimize = optimize,
});

// Log module - logging utilities
const log_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/log.zig" },
    .target = target,
    .optimize = optimize,
});

// AST module - core AST data structures
const ast_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/ast.zig" },
    .target = target,
    .optimize = optimize,
});
ast_module.addImport("errors", errors_module);

// AST ⇄ JSON reflective round-trip. The backend reads the per-user program AST
// from `program.ast.json` at runtime and deserializes it via this module — the
// AST is no longer compiled into the backend binary, so backend.zig stays
// byte-identical across user programs AND the built binary is reusable across
// any program with the same handler set.
const ast_json_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/ast_json.zig" },
    .target = target,
    .optimize = optimize,
});
ast_json_module.addImport("ast", ast_module);

// Compiler env module - per-user CompilerEnv struct (flags + env vars).
// Also split out for the same byte-identical-backend.zig reason.
const compiler_env_module = b.createModule(.{
    .root_source_file = b.path("compiler_env.zig"),
    .target = target,
    .optimize = optimize,
});

// Lexer module - tokenization
const lexer_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/lexer.zig" },
    .target = target,
    .optimize = optimize,
});

// Annotation parser - parses parametrized annotations
const annotation_parser_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/annotation_parser.zig" },
    .target = target,
    .optimize = optimize,
});

// Type registry - type metadata tracking
const type_registry_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/type_registry.zig" },
    .target = target,
    .optimize = optimize,
});
type_registry_module.addImport("ast", ast_module);
type_registry_module.addImport("log", log_module);

// Expression parser
const expression_parser_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/expression_parser.zig" },
    .target = target,
    .optimize = optimize,
});
expression_parser_module.addImport("lexer", lexer_module);
expression_parser_module.addImport("ast", ast_module);

// Union collector
const union_collector_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/union_collector.zig" },
    .target = target,
    .optimize = optimize,
});
union_collector_module.addImport("ast", ast_module);

// Config module - project configuration
const config_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/config.zig" },
    .target = target,
    .optimize = optimize,
});
config_module.addImport("log", log_module);

// File types module - canonical Koru extension list + helpers
const file_types_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/file_types.zig" },
    .target = target,
    .optimize = optimize,
});

// Module resolver - resolves import paths
const module_resolver_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/module_resolver.zig" },
    .target = target,
    .optimize = optimize,
});
module_resolver_module.addImport("config", config_module);
module_resolver_module.addImport("log", log_module);
module_resolver_module.addImport("file_types", file_types_module);

// Parse-time name normalizer (kebab -> snake). Shares ast_module for type identity.
const ast_mangle_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/ast_mangle.zig" },
    .target = target,
    .optimize = optimize,
});
ast_mangle_module.addImport("ast", ast_module);

// Parser module - source parsing
const parser_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/parser.zig" },
    .target = target,
    .optimize = optimize,
});
parser_module.addImport("ast", ast_module);
parser_module.addImport("ast_mangle", ast_mangle_module);
parser_module.addImport("lexer", lexer_module);
parser_module.addImport("errors", errors_module);
parser_module.addImport("log", log_module);
parser_module.addImport("type_registry", type_registry_module);
parser_module.addImport("expression_parser", expression_parser_module);
parser_module.addImport("union_collector", union_collector_module);
parser_module.addImport("module_resolver", module_resolver_module);
parser_module.addImport("file_types", file_types_module);

// Phantom parser
const phantom_parser_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/koru_std/phantom_parser.zig" },
    .target = target,
    .optimize = optimize,
});

// Type inference
const type_inference_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/type_inference.zig" },
    .target = target,
    .optimize = optimize,
});
type_inference_module.addImport("ast", ast_module);
type_inference_module.addImport("errors", errors_module);

// Branch checker - pure branch name validation
const branch_checker_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/branch_checker.zig" },
    .target = target,
    .optimize = optimize,
});

// Shape checker - validates event/branch structures
const shape_checker_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/shape_checker.zig" },
    .target = target,
    .optimize = optimize,
});
shape_checker_module.addImport("ast", ast_module);
shape_checker_module.addImport("errors", errors_module);
shape_checker_module.addImport("log", log_module);
shape_checker_module.addImport("phantom_parser", phantom_parser_module);
shape_checker_module.addImport("type_inference", type_inference_module);
shape_checker_module.addImport("branch_checker", branch_checker_module);

// Flow checker - validates control flow
const flow_checker_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/flow_checker.zig" },
    .target = target,
    .optimize = optimize,
});
flow_checker_module.addImport("ast", ast_module);
flow_checker_module.addImport("errors", errors_module);
flow_checker_module.addImport("log", log_module);
flow_checker_module.addImport("branch_checker", branch_checker_module);
flow_checker_module.addImport("annotation_parser", annotation_parser_module);

// Phantom semantic checker - validates phantom type states
const phantom_semantic_checker_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/phantom_semantic_checker.zig" },
    .target = target,
    .optimize = optimize,
});
phantom_semantic_checker_module.addImport("ast", ast_module);
phantom_semantic_checker_module.addImport("errors", errors_module);
phantom_semantic_checker_module.addImport("log", log_module);
phantom_semantic_checker_module.addImport("phantom_parser", phantom_parser_module);

// Purity analyzer - tracks [pure] annotations
const purity_analyzer_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/compiler_passes/purity_analyzer.zig" },
    .target = target,
    .optimize = optimize,
});
purity_analyzer_module.addImport("ast", ast_module);

// AST functional utilities
const ast_functional_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/ast_functional.zig" },
    .target = target,
    .optimize = optimize,
});
ast_functional_module.addImport("ast", ast_module);

// Auto-discharge inserter - inserts disposal calls before terminators
const auto_discharge_inserter_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/auto_discharge_inserter.zig" },
    .target = target,
    .optimize = optimize,
});
auto_discharge_inserter_module.addImport("ast", ast_module);
auto_discharge_inserter_module.addImport("ast_functional", ast_functional_module);
auto_discharge_inserter_module.addImport("errors", errors_module);
auto_discharge_inserter_module.addImport("log", log_module);
auto_discharge_inserter_module.addImport("phantom_parser", phantom_parser_module);

// Dead strip pass - removes unreachable events/procs from AST
const dead_strip_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/dead_strip.zig" },
    .target = target,
    .optimize = optimize,
});
dead_strip_module.addImport("ast", ast_module);
dead_strip_module.addImport("log", log_module);

// Codegen utilities - keyword escaping, identifier helpers
const codegen_utils_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/codegen_utils.zig" },
    .target = target,
    .optimize = optimize,
});

// Continuation codegen - reusable code generation for transforms
const continuation_codegen_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/continuation_codegen.zig" },
    .target = target,
    .optimize = optimize,
});
continuation_codegen_module.addImport("ast", ast_module);
continuation_codegen_module.addImport("codegen_utils", codegen_utils_module);

// Template utils - template lookup and interpolation for metaprogramming
const template_utils_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/template_utils.zig" },
    .target = target,
    .optimize = optimize,
});
template_utils_module.addImport("ast", ast_module);

// Liquid template engine - runtime Liquid-style templating
const liquid_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/liquid.zig" },
    .target = target,
    .optimize = optimize,
});

// Struct-literal projector - parses Koru `{ name: expr }` into ordered field
// pairs / a liquid record. Used by the ~capture transform to interpret the
// opaque `captured({...})` payload (docs/PARSER_PALETTE.md).
const struct_literal_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/struct_literal.zig" },
    .target = target,
    .optimize = optimize,
});
struct_literal_module.addImport("liquid", liquid_module);

// Compiler config
const compiler_config_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/compiler_config.zig" },
    .target = target,
    .optimize = optimize,
});

// Emitter helpers - code generation utilities
const emitter_helpers_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/emitter_helpers.zig" },
    .target = target,
    .optimize = optimize,
});
emitter_helpers_module.addImport("ast", ast_module);
emitter_helpers_module.addImport("errors", errors_module);
emitter_helpers_module.addImport("log", log_module);
emitter_helpers_module.addImport("compiler_config", compiler_config_module);
emitter_helpers_module.addImport("type_registry", type_registry_module);
emitter_helpers_module.addImport("codegen_utils", codegen_utils_module);
emitter_helpers_module.addImport("annotation_parser", annotation_parser_module);

// Tap pattern matcher
const glob_pattern_matcher_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/glob_pattern_matcher.zig" },
    .target = target,
    .optimize = optimize,
});

// Tap registry - tap/observer system
const tap_registry_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/tap_registry.zig" },
    .target = target,
    .optimize = optimize,
});
tap_registry_module.addImport("ast", ast_module);
tap_registry_module.addImport("errors", errors_module);
tap_registry_module.addImport("log", log_module);
tap_registry_module.addImport("glob_pattern_matcher", glob_pattern_matcher_module);

// Runtime registry - runtime scope collection
const runtime_registry_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/runtime_registry.zig" },
    .target = target,
    .optimize = optimize,
});

// Tap transformer - inserts tap invocations into AST
const tap_transformer_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/tap_transformer.zig" },
    .target = target,
    .optimize = optimize,
});
tap_transformer_module.addImport("ast", ast_module);
tap_transformer_module.addImport("log", log_module);
tap_transformer_module.addImport("tap_registry", tap_registry_module);
tap_transformer_module.addImport("emitter_helpers", emitter_helpers_module);

// Template processor - renders proc bodies tagged `|template|...`
// through Liquid, then strips the `template` tag from the variant chain.
const template_processor_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/template_processor.zig" },
    .target = target,
    .optimize = optimize,
});
template_processor_module.addImport("ast", ast_module);
template_processor_module.addImport("liquid", liquid_module);
template_processor_module.addImport("log", log_module);
template_processor_module.addImport("errors", errors_module);
template_processor_module.addImport("annotation_parser", annotation_parser_module);
template_processor_module.addImport("struct_literal", struct_literal_module);

// Purity helpers
const purity_helpers_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/compiler_passes/purity_helpers.zig" },
    .target = target,
    .optimize = optimize,
});
purity_helpers_module.addImport("ast", ast_module);
purity_helpers_module.addImport("lexer", lexer_module);
tap_transformer_module.addImport("compiler_passes/purity_helpers", purity_helpers_module);
emitter_helpers_module.addImport("tap_registry", tap_registry_module);
emitter_helpers_module.addImport("compiler_passes/purity_helpers", purity_helpers_module);

// Visitor emitter - code generation visitor pattern
const visitor_emitter_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/visitor_emitter.zig" },
    .target = target,
    .optimize = optimize,
});
visitor_emitter_module.addImport("ast", ast_module);
visitor_emitter_module.addImport("log", log_module);
visitor_emitter_module.addImport("emitter_helpers", emitter_helpers_module);
visitor_emitter_module.addImport("tap_registry", tap_registry_module);
visitor_emitter_module.addImport("type_registry", type_registry_module);
visitor_emitter_module.addImport("annotation_parser", annotation_parser_module);
visitor_emitter_module.addImport("codegen_utils", codegen_utils_module);
visitor_emitter_module.addImport("file_types", file_types_module);

// JS-target emitter (spike): minimal AST→JS for pump.kz. Gated behind
// --lang=js in emit-zig; the default Zig path never references it.
const js_emitter_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/js_emitter.zig" },
    .target = target,
    .optimize = optimize,
});
js_emitter_module.addImport("ast", ast_module);
js_emitter_module.addImport("log", log_module);
js_emitter_module.addImport("file_types", file_types_module);
js_emitter_module.addImport("annotation_parser", annotation_parser_module);

// Build.zig emission
const emit_build_zig_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/emit_build_zig.zig" },
    .target = target,
    .optimize = optimize,
});

// AST serializer (for --ast-json and debugging)
const ast_serializer_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/ast_serializer.zig" },
    .target = target,
    .optimize = optimize,
});
ast_serializer_module.addImport("ast", ast_module);

// Transform pass runner - recursive AST walker for transform handlers
// Also handles [expand] events via template lookup and interpolation
const transform_pass_runner_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/transform_pass_runner.zig" },
    .target = target,
    .optimize = optimize,
});
transform_pass_runner_module.addImport("ast", ast_module);
transform_pass_runner_module.addImport("log", log_module);
transform_pass_runner_module.addImport("annotation_parser", annotation_parser_module);
transform_pass_runner_module.addImport("template_utils", template_utils_module);
transform_pass_runner_module.addImport("ast_functional", ast_functional_module);
transform_pass_runner_module.addImport("liquid", liquid_module);

// Add all imports to the backend executable
// Backend_output_emitted as its own compilation unit, linked via addObject.
// This is the slice-B move: backend.zig no longer @import-s this file, so
// it doesn't get fused into backend.zig's compilation unit.
// Regex engine (std/regex) — compile-time NFA/DFA matcher generator used by
// the `match` transform. Pure std, no deps.
const regex_engine_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/regex_engine.zig" },
    .target = target,
    .optimize = optimize,
});

const backend_output_module = b.createModule(.{
    .root_source_file = b.path("backend_output_emitted.zig"),
    .target = target,
    .optimize = optimize,
});
backend_output_module.addImport("ast", ast_module);
backend_output_module.addImport("regex_engine", regex_engine_module);
backend_output_module.addImport("log", log_module);
backend_output_module.addImport("emitter_helpers", emitter_helpers_module);
backend_output_module.addImport("compiler_env", compiler_env_module);
backend_output_module.addImport("tap_registry", tap_registry_module);
backend_output_module.addImport("annotation_parser", annotation_parser_module);
backend_output_module.addImport("type_registry", type_registry_module);
backend_output_module.addImport("codegen_utils", codegen_utils_module);
backend_output_module.addImport("transform_pass_runner", transform_pass_runner_module);
backend_output_module.addImport("parser", parser_module);
backend_output_module.addImport("ast_functional", ast_functional_module);
backend_output_module.addImport("flow_checker", flow_checker_module);
backend_output_module.addImport("shape_checker", shape_checker_module);
backend_output_module.addImport("phantom_semantic_checker", phantom_semantic_checker_module);
backend_output_module.addImport("auto_discharge_inserter", auto_discharge_inserter_module);
backend_output_module.addImport("dead_strip", dead_strip_module);
backend_output_module.addImport("purity_analyzer", purity_analyzer_module);
backend_output_module.addImport("visitor_emitter", visitor_emitter_module);
backend_output_module.addImport("js_emitter", js_emitter_module);
backend_output_module.addImport("emit_build_zig", emit_build_zig_module);
backend_output_module.addImport("ast_serializer", ast_serializer_module);
backend_output_module.addImport("runtime_registry", runtime_registry_module);
backend_output_module.addImport("tap_transformer", tap_transformer_module);
backend_output_module.addImport("template_processor", template_processor_module);
backend_output_module.addImport("expression_parser", expression_parser_module);
backend_output_module.addImport("errors", errors_module);
backend_output_module.addImport("continuation_codegen", continuation_codegen_module);
backend_output_module.addImport("template_utils", template_utils_module);
backend_output_module.addImport("liquid", liquid_module);
backend_output_module.addImport("struct_literal", struct_literal_module);

// backend_output_emitted as a MODULE of the exe (single compilation unit =
// single std). Previously a separate `b.addObject` + `exe.addObject`, which
// gave backend_output its OWN std — so `std.os.environ` (and every std global)
// was duplicated: `start` set the exe's environ, but the emitted pipeline's
// getenv read the object's uninitialized copy → 0xAA → segfault on Linux
// (no-libc reads the global directly; macOS hid it by routing getenv via libc).
// One compilation = one std = one environ.
exe.root_module.addImport("backend_output", backend_output_module);

exe.root_module.addImport("ast", ast_module);
exe.root_module.addImport("ast_json", ast_json_module);
exe.root_module.addImport("compiler_env", compiler_env_module);
exe.root_module.addImport("ast_functional", ast_functional_module);
exe.root_module.addImport("ast_serializer", ast_serializer_module);
exe.root_module.addImport("log", log_module);
exe.root_module.addImport("emitter_helpers", emitter_helpers_module);
exe.root_module.addImport("tap_registry", tap_registry_module);
exe.root_module.addImport("runtime_registry", runtime_registry_module);
exe.root_module.addImport("tap_transformer", tap_transformer_module);
exe.root_module.addImport("template_processor", template_processor_module);
exe.root_module.addImport("visitor_emitter", visitor_emitter_module);
exe.root_module.addImport("parser", parser_module);
exe.root_module.addImport("expression_parser", expression_parser_module);
exe.root_module.addImport("emit_build_zig", emit_build_zig_module);
exe.root_module.addImport("shape_checker", shape_checker_module);
exe.root_module.addImport("flow_checker", flow_checker_module);
exe.root_module.addImport("phantom_semantic_checker", phantom_semantic_checker_module);
exe.root_module.addImport("auto_discharge_inserter", auto_discharge_inserter_module);
exe.root_module.addImport("dead_strip", dead_strip_module);
exe.root_module.addImport("purity_analyzer", purity_analyzer_module);
exe.root_module.addImport("errors", errors_module);
exe.root_module.addImport("type_registry", type_registry_module);
exe.root_module.addImport("annotation_parser", annotation_parser_module);
exe.root_module.addImport("transform_pass_runner", transform_pass_runner_module);
exe.root_module.addImport("codegen_utils", codegen_utils_module);
exe.root_module.addImport("continuation_codegen", continuation_codegen_module);
exe.root_module.addImport("template_utils", template_utils_module);
exe.root_module.addImport("liquid", liquid_module);
exe.root_module.addImport("struct_literal", struct_literal_module);

        }
    }.call;
compiler_build_0(__koru_b, __koru_exe, __koru_target, __koru_optimize);

    __koru_b.installArtifact(__koru_exe);
}
