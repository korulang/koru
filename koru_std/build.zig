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

    // Module: compiler
    const compiler_build_0 = struct {
        fn call(b: *std.Build, exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
            _ = &b; _ = &exe; _ = &target; _ = &optimize; // Suppress unused warnings
// Calculate relative path from test directory to repo root
// This will be baked into the generated build.zig
const REL_TO_ROOT = "/usr/local/lib/koru";

// Errors module - error reporting
const errors_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/errors.zig" },
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

// Parser module - source parsing
const parser_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/parser.zig" },
    .target = target,
    .optimize = optimize,
});
parser_module.addImport("ast", ast_module);
parser_module.addImport("lexer", lexer_module);
parser_module.addImport("errors", errors_module);
parser_module.addImport("type_registry", type_registry_module);
parser_module.addImport("expression_parser", expression_parser_module);
parser_module.addImport("union_collector", union_collector_module);

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

// Auto-dispose inserter - inserts disposal calls before terminators
const auto_dispose_inserter_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/auto_dispose_inserter.zig" },
    .target = target,
    .optimize = optimize,
});
auto_dispose_inserter_module.addImport("ast", ast_module);
auto_dispose_inserter_module.addImport("ast_functional", ast_functional_module);
auto_dispose_inserter_module.addImport("errors", errors_module);
auto_dispose_inserter_module.addImport("phantom_parser", phantom_parser_module);

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
emitter_helpers_module.addImport("compiler_config", compiler_config_module);
emitter_helpers_module.addImport("type_registry", type_registry_module);
emitter_helpers_module.addImport("codegen_utils", codegen_utils_module);

// Tap pattern matcher
const tap_pattern_matcher_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/tap_pattern_matcher.zig" },
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
tap_registry_module.addImport("tap_pattern_matcher", tap_pattern_matcher_module);

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
tap_transformer_module.addImport("tap_registry", tap_registry_module);
tap_transformer_module.addImport("emitter_helpers", emitter_helpers_module);

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
visitor_emitter_module.addImport("emitter_helpers", emitter_helpers_module);
visitor_emitter_module.addImport("tap_registry", tap_registry_module);
visitor_emitter_module.addImport("type_registry", type_registry_module);
visitor_emitter_module.addImport("annotation_parser", annotation_parser_module);
visitor_emitter_module.addImport("codegen_utils", codegen_utils_module);

// Fusion detector and optimizer
const fusion_detector_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/fusion_detector.zig" },
    .target = target,
    .optimize = optimize,
});
fusion_detector_module.addImport("ast", ast_module);

const fusion_optimizer_module = b.createModule(.{
    .root_source_file = .{ .cwd_relative = REL_TO_ROOT ++ "/src/fusion_optimizer.zig" },
    .target = target,
    .optimize = optimize,
});
fusion_optimizer_module.addImport("ast", ast_module);
fusion_optimizer_module.addImport("ast_functional", ast_functional_module);
fusion_optimizer_module.addImport("fusion_detector.zig", fusion_detector_module);

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
transform_pass_runner_module.addImport("annotation_parser", annotation_parser_module);
transform_pass_runner_module.addImport("template_utils", template_utils_module);
transform_pass_runner_module.addImport("ast_functional", ast_functional_module);
transform_pass_runner_module.addImport("liquid", liquid_module);

// Add all imports to the backend executable
exe.root_module.addImport("ast", ast_module);
exe.root_module.addImport("ast_functional", ast_functional_module);
exe.root_module.addImport("ast_serializer", ast_serializer_module);
exe.root_module.addImport("emitter_helpers", emitter_helpers_module);
exe.root_module.addImport("tap_registry", tap_registry_module);
exe.root_module.addImport("runtime_registry", runtime_registry_module);
exe.root_module.addImport("tap_transformer", tap_transformer_module);
exe.root_module.addImport("visitor_emitter", visitor_emitter_module);
exe.root_module.addImport("parser", parser_module);
exe.root_module.addImport("fusion_optimizer", fusion_optimizer_module);
exe.root_module.addImport("emit_build_zig", emit_build_zig_module);
exe.root_module.addImport("shape_checker", shape_checker_module);
exe.root_module.addImport("flow_checker", flow_checker_module);
exe.root_module.addImport("phantom_semantic_checker", phantom_semantic_checker_module);
exe.root_module.addImport("auto_dispose_inserter", auto_dispose_inserter_module);
exe.root_module.addImport("purity_analyzer", purity_analyzer_module);
exe.root_module.addImport("errors", errors_module);
exe.root_module.addImport("type_registry", type_registry_module);
exe.root_module.addImport("annotation_parser", annotation_parser_module);
exe.root_module.addImport("transform_pass_runner", transform_pass_runner_module);
exe.root_module.addImport("codegen_utils", codegen_utils_module);
exe.root_module.addImport("continuation_codegen", continuation_codegen_module);
exe.root_module.addImport("template_utils", template_utils_module);
exe.root_module.addImport("liquid", liquid_module);

        }
    }.call;
compiler_build_0(__koru_b, __koru_exe, __koru_target, __koru_optimize);

    __koru_b.installArtifact(__koru_exe);
}
