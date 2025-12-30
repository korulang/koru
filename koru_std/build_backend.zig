const std = @import("std");

pub fn build(__koru_b: *std.Build) void {
    const __koru_target = __koru_b.standardTargetOptions(.{});
    const __koru_optimize = __koru_b.standardOptimizeOption(.{});

    const __koru_exe = __koru_b.addExecutable(.{
        .name = "app",
        .root_module = __koru_b.createModule(.{
            .root_source_file = __koru_b.path("backend_output_emitted.zig"),
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
    const REL_TO_ROOT = "..";

    // Errors module - error reporting
    const errors_module = b.createModule(.{
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/errors.zig"),
        .target = target,
        .optimize = optimize,
    });

    // AST module - core AST data structures
    const ast_module = b.createModule(.{
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/ast.zig"),
        .target = target,
        .optimize = optimize,
    });
    ast_module.addImport("errors", errors_module);

    // Lexer module - tokenization
    const lexer_module = b.createModule(.{
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/lexer.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Annotation parser - parses parametrized annotations
    const annotation_parser_module = b.createModule(.{
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/annotation_parser.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Type registry - type metadata tracking
    const type_registry_module = b.createModule(.{
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/type_registry.zig"),
        .target = target,
        .optimize = optimize,
    });
    type_registry_module.addImport("ast", ast_module);

    // Expression parser
    const expression_parser_module = b.createModule(.{
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/expression_parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    expression_parser_module.addImport("lexer", lexer_module);
    expression_parser_module.addImport("ast", ast_module);

    // Union collector
    const union_collector_module = b.createModule(.{
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/union_collector.zig"),
        .target = target,
        .optimize = optimize,
    });
    union_collector_module.addImport("ast", ast_module);

    // Parser module - source parsing
    const parser_module = b.createModule(.{
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/parser.zig"),
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
        .root_source_file = b.path(REL_TO_ROOT ++ "/koru_std/phantom_parser.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Type inference
    const type_inference_module = b.createModule(.{
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/type_inference.zig"),
        .target = target,
        .optimize = optimize,
    });
    type_inference_module.addImport("ast", ast_module);
    type_inference_module.addImport("errors", errors_module);

    // Branch checker - pure branch name validation
    const branch_checker_module = b.createModule(.{
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/branch_checker.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Shape checker - validates event/branch structures
    const shape_checker_module = b.createModule(.{
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/shape_checker.zig"),
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
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/flow_checker.zig"),
        .target = target,
        .optimize = optimize,
    });
    flow_checker_module.addImport("ast", ast_module);
    flow_checker_module.addImport("errors", errors_module);
    flow_checker_module.addImport("branch_checker", branch_checker_module);
    flow_checker_module.addImport("annotation_parser", annotation_parser_module);

    // AST functional utilities
    const ast_functional_module = b.createModule(.{
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/ast_functional.zig"),
        .target = target,
        .optimize = optimize,
    });
    ast_functional_module.addImport("ast", ast_module);

    // Compiler config
    const compiler_config_module = b.createModule(.{
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/compiler_config.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Emitter helpers - code generation utilities
    const emitter_helpers_module = b.createModule(.{
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/emitter_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    emitter_helpers_module.addImport("ast", ast_module);
    emitter_helpers_module.addImport("compiler_config", compiler_config_module);
    emitter_helpers_module.addImport("type_registry", type_registry_module);

    // Tap pattern matcher
    const tap_pattern_matcher_module = b.createModule(.{
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/tap_pattern_matcher.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tap registry - tap/observer system
    const tap_registry_module = b.createModule(.{
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/tap_registry.zig"),
        .target = target,
        .optimize = optimize,
    });
    tap_registry_module.addImport("ast", ast_module);
    tap_registry_module.addImport("errors", errors_module);
    tap_registry_module.addImport("tap_pattern_matcher", tap_pattern_matcher_module);

    // Tap transformer - inserts tap invocations into AST
    const tap_transformer_module = b.createModule(.{
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/tap_transformer.zig"),
        .target = target,
        .optimize = optimize,
    });
    tap_transformer_module.addImport("ast", ast_module);
    tap_transformer_module.addImport("tap_registry", tap_registry_module);
    tap_transformer_module.addImport("emitter_helpers", emitter_helpers_module);

    // Purity helpers
    const purity_helpers_module = b.createModule(.{
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/compiler_passes/purity_helpers.zig"),
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
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/visitor_emitter.zig"),
        .target = target,
        .optimize = optimize,
    });
    visitor_emitter_module.addImport("ast", ast_module);
    visitor_emitter_module.addImport("emitter_helpers", emitter_helpers_module);
    visitor_emitter_module.addImport("tap_registry", tap_registry_module);
    visitor_emitter_module.addImport("type_registry", type_registry_module);
    visitor_emitter_module.addImport("annotation_parser", annotation_parser_module);

    // Fusion detector and optimizer
    const fusion_detector_module = b.createModule(.{
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/fusion_detector.zig"),
        .target = target,
        .optimize = optimize,
    });
    fusion_detector_module.addImport("ast", ast_module);

    const fusion_optimizer_module = b.createModule(.{
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/fusion_optimizer.zig"),
        .target = target,
        .optimize = optimize,
    });
    fusion_optimizer_module.addImport("ast", ast_module);
    fusion_optimizer_module.addImport("ast_functional", ast_functional_module);
    fusion_optimizer_module.addImport("fusion_detector.zig", fusion_detector_module);

    // Build.zig emission
    const emit_build_zig_module = b.createModule(.{
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/emit_build_zig.zig"),
        .target = target,
        .optimize = optimize,
    });

    // AST serializer (for --ast-json and debugging)
    const ast_serializer_module = b.createModule(.{
        .root_source_file = b.path(REL_TO_ROOT ++ "/src/ast_serializer.zig"),
        .target = target,
        .optimize = optimize,
    });
    ast_serializer_module.addImport("ast", ast_module);

    // Add all imports to the backend executable
    exe.root_module.addImport("ast", ast_module);
    exe.root_module.addImport("ast_functional", ast_functional_module);
    exe.root_module.addImport("ast_serializer", ast_serializer_module);
    exe.root_module.addImport("emitter_helpers", emitter_helpers_module);
    exe.root_module.addImport("tap_registry", tap_registry_module);
    exe.root_module.addImport("tap_transformer", tap_transformer_module);
    exe.root_module.addImport("visitor_emitter", visitor_emitter_module);
    exe.root_module.addImport("parser", parser_module);
    exe.root_module.addImport("fusion_optimizer", fusion_optimizer_module);
    exe.root_module.addImport("emit_build_zig", emit_build_zig_module);
    exe.root_module.addImport("shape_checker", shape_checker_module);
    exe.root_module.addImport("flow_checker", flow_checker_module);
    exe.root_module.addImport("errors", errors_module);
    exe.root_module.addImport("type_registry", type_registry_module);
    exe.root_module.addImport("annotation_parser", annotation_parser_module);

        }
    }.call;
compiler_build_0(__koru_b, __koru_exe, __koru_target, __koru_optimize);

    __koru_b.installArtifact(__koru_exe);
}
