const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create shared modules
    const ast_module = b.createModule(.{
        .root_source_file = b.path("src/ast.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    const lexer_module = b.createModule(.{
        .root_source_file = b.path("src/lexer.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    const errors_module = b.createModule(.{
        .root_source_file = b.path("src/errors.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Config module for koru.json parsing
    const config_module = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Module resolver for import path resolution
    const module_resolver_module = b.createModule(.{
        .root_source_file = b.path("src/module_resolver.zig"),
        .target = target,
        .optimize = optimize,
    });
    module_resolver_module.addImport("config", config_module);

    // AST depends on errors for SourceLocation
    ast_module.addImport("errors", errors_module);

    // Type registry module (needed by parser and others)
    const type_registry_module = b.createModule(.{
        .root_source_file = b.path("src/type_registry.zig"),
        .target = target,
        .optimize = optimize,
    });
    type_registry_module.addImport("ast", ast_module);

    // Keyword registry module for [keyword] annotation resolution
    const keyword_registry_module = b.createModule(.{
        .root_source_file = b.path("src/keyword_registry.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Parser module with dependencies
    const parser_module = b.createModule(.{
        .root_source_file = b.path("src/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    parser_module.addImport("ast", ast_module);
    parser_module.addImport("lexer", lexer_module);
    parser_module.addImport("errors", errors_module);
    parser_module.addImport("type_registry", type_registry_module);
    parser_module.addImport("module_resolver", module_resolver_module);
    
    // Expression parser module
    const expression_parser_module = b.createModule(.{
        .root_source_file = b.path("src/expression_parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    expression_parser_module.addImport("lexer", lexer_module);
    expression_parser_module.addImport("ast", ast_module);
    
    // Expression code generator module
    const expression_codegen_module = b.createModule(.{
        .root_source_file = b.path("src/expression_codegen.zig"),
        .target = target,
        .optimize = optimize,
    });
    expression_codegen_module.addImport("ast", ast_module);
    
    // Union collector module for inline flows
    const union_collector_module = b.createModule(.{
        .root_source_file = b.path("src/union_collector.zig"),
        .target = target,
        .optimize = optimize,
    });
    union_collector_module.addImport("ast", ast_module);
    
    // Codegen utilities module (Zig keyword escaping, etc.)
    const codegen_utils_module = b.createModule(.{
        .root_source_file = b.path("src/codegen_utils.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Union codegen module for inline flows
    const union_codegen_module = b.createModule(.{
        .root_source_file = b.path("src/union_codegen.zig"),
        .target = target,
        .optimize = optimize,
    });
    union_codegen_module.addImport("ast", ast_module);
    union_codegen_module.addImport("expression_codegen", expression_codegen_module);
    union_codegen_module.addImport("codegen_utils", codegen_utils_module);
    
    // Add expression parser and union modules to parser module
    parser_module.addImport("expression_parser", expression_parser_module);
    parser_module.addImport("union_collector", union_collector_module);
    parser_module.addImport("union_codegen", union_codegen_module);
    
    // Phantom parser library module
    const phantom_parser_module = b.createModule(.{
        .root_source_file = b.path("koru_std/phantom_parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Branch checker module
    const branch_checker_module = b.createModule(.{
        .root_source_file = b.path("src/branch_checker.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Shape checker module with dependencies
    const shape_checker_module = b.createModule(.{
        .root_source_file = b.path("src/shape_checker.zig"),
        .target = target,
        .optimize = optimize,
    });
    shape_checker_module.addImport("ast", ast_module);
    shape_checker_module.addImport("errors", errors_module);
    shape_checker_module.addImport("phantom_parser", phantom_parser_module);
    shape_checker_module.addImport("branch_checker", branch_checker_module);

    // Flow checker module
    const flow_checker_module = b.createModule(.{
        .root_source_file = b.path("src/flow_checker.zig"),
        .target = target,
        .optimize = optimize,
    });
    flow_checker_module.addImport("ast", ast_module);
    flow_checker_module.addImport("errors", errors_module);
    flow_checker_module.addImport("branch_checker", branch_checker_module);

    // Phantom semantic checker module
    const phantom_semantic_checker_module = b.createModule(.{
        .root_source_file = b.path("src/phantom_semantic_checker.zig"),
        .target = target,
        .optimize = optimize,
    });
    phantom_semantic_checker_module.addImport("ast", ast_module);
    phantom_semantic_checker_module.addImport("errors", errors_module);
    phantom_semantic_checker_module.addImport("phantom_parser", phantom_parser_module);

    // Type context module (moved here to avoid duplicate definition)
    const type_context_module = b.createModule(.{
        .root_source_file = b.path("src/type_context.zig"),
        .target = target,
        .optimize = optimize,
    });
    type_context_module.addImport("ast", ast_module);
    type_context_module.addImport("type_registry", type_registry_module);
    
    // Type inference module with dependencies (defined first as it's used by others)
    const type_inference_module = b.createModule(.{
        .root_source_file = b.path("src/type_inference.zig"),
        .target = target,
        .optimize = optimize,
    });
    type_inference_module.addImport("ast", ast_module);
    type_inference_module.addImport("errors", errors_module);
    
    // Update shape checker to include type inference
    shape_checker_module.addImport("type_inference", type_inference_module);
    
    // Tap collector module for Event Taps
    const tap_collector_module = b.createModule(.{
        .root_source_file = b.path("src/tap_collector.zig"),
        .target = target,
        .optimize = optimize,
    });
    tap_collector_module.addImport("ast", ast_module);
    
    // Tap codegen module for Event Tap code generation
    const tap_codegen_module = b.createModule(.{
        .root_source_file = b.path("src/tap_codegen.zig"),
        .target = target,
        .optimize = optimize,
    });
    tap_codegen_module.addImport("ast", ast_module);

    // Compiler requires collector module for ~compiler:requires AST walking
    const compiler_requires_module = b.createModule(.{
        .root_source_file = b.path("src/compiler_requires.zig"),
        .target = target,
        .optimize = optimize,
    });
    compiler_requires_module.addImport("ast", ast_module);

    // Package requirements collector module for ~std.package:requires.* AST walking
    const package_requires_module = b.createModule(.{
        .root_source_file = b.path("src/package_requires.zig"),
        .target = target,
        .optimize = optimize,
    });
    package_requires_module.addImport("ast", ast_module);

    // Build.zig generation library for build_backend.zig
    const emit_build_zig_module = b.createModule(.{
        .root_source_file = b.path("src/emit_build_zig.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Package file generation library for package.json, Cargo.toml, etc.
    const emit_package_files_module = b.createModule(.{
        .root_source_file = b.path("src/emit_package_files.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Shape analyzer module with dependencies
    const shape_analyzer_module = b.createModule(.{
        .root_source_file = b.path("src/shape_analyzer.zig"),
        .target = target,
        .optimize = optimize,
    });
    shape_analyzer_module.addImport("ast", ast_module);
    shape_analyzer_module.addImport("errors", errors_module);
    shape_analyzer_module.addImport("type_inference", type_inference_module);
    shape_analyzer_module.addImport("type_registry", type_registry_module);
    shape_analyzer_module.addImport("type_context", type_context_module);
    
    // Note: Old emitter.zig removed - we use ast_serializer now for metacircular compilation
    
    // AST Transformation module (moved up for main exe)
    const ast_transform_module = b.createModule(.{
        .root_source_file = b.path("src/ast_transform.zig"),
        .target = target,
        .optimize = optimize,
    });
    ast_transform_module.addImport("ast", ast_module);
    
    // AST Visitor module (moved up for main exe)
    const ast_visitor_module = b.createModule(.{
        .root_source_file = b.path("src/ast_visitor.zig"),
        .target = target,
        .optimize = optimize,
    });
    ast_visitor_module.addImport("ast", ast_module);
    ast_visitor_module.addImport("ast_transform", ast_transform_module);
    
    // Inline transformation module (moved up for main exe)
    const inline_transform_module = b.createModule(.{
        .root_source_file = b.path("src/transforms/inline_small_events.zig"),
        .target = target,
        .optimize = optimize,
    });
    inline_transform_module.addImport("ast", ast_module);
    inline_transform_module.addImport("ast_transform", ast_transform_module);
    inline_transform_module.addImport("ast_visitor", ast_visitor_module);
    
    // AST Serializer module for Phase 2
    const ast_serializer_module = b.createModule(.{
        .root_source_file = b.path("src/ast_serializer.zig"),
        .target = target,
        .optimize = optimize,
    });
    ast_serializer_module.addImport("ast", ast_module);
    ast_serializer_module.addImport("parser", parser_module);

    // Compiler Config module - feature flags and configuration
    const compiler_config_module = b.createModule(.{
        .root_source_file = b.path("src/compiler_config.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Emitter Helpers module - extracted helper functions for visitor pattern
    const emitter_helpers_module = b.createModule(.{
        .root_source_file = b.path("src/emitter_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    emitter_helpers_module.addImport("ast", ast_module);
    emitter_helpers_module.addImport("compiler_config", compiler_config_module);
    emitter_helpers_module.addImport("type_registry", type_registry_module);

    // Old emitter.zig DELETED - using visitor_emitter now

    // Annotation Parser module - parses and queries parametrized annotations
    const annotation_parser_module = b.createModule(.{
        .root_source_file = b.path("src/annotation_parser.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Visitor Emitter module - visitor-based orchestration
    const visitor_emitter_module = b.createModule(.{
        .root_source_file = b.path("src/visitor_emitter.zig"),
        .target = target,
        .optimize = optimize,
    });
    visitor_emitter_module.addImport("ast", ast_module);
    visitor_emitter_module.addImport("emitter_helpers", emitter_helpers_module);
    visitor_emitter_module.addImport("ast_visitor", ast_visitor_module);
    visitor_emitter_module.addImport("type_registry", type_registry_module);
    visitor_emitter_module.addImport("annotation_parser", annotation_parser_module);

    // Tap Pattern Matcher module - pattern matching for tap registration
    const tap_pattern_matcher_module = b.createModule(.{
        .root_source_file = b.path("src/tap_pattern_matcher.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tap Registry module - backend pass for event tap collection
    const tap_registry_module = b.createModule(.{
        .root_source_file = b.path("src/tap_registry.zig"),
        .target = target,
        .optimize = optimize,
    });
    tap_registry_module.addImport("ast", ast_module);
    tap_registry_module.addImport("errors", errors_module);
    tap_registry_module.addImport("tap_pattern_matcher", tap_pattern_matcher_module);

    // Canonicalize Names module - Qualify all DottedPaths after import resolution
    const canonicalize_names_module = b.createModule(.{
        .root_source_file = b.path("src/canonicalize_names.zig"),
        .target = target,
        .optimize = optimize,
    });
    canonicalize_names_module.addImport("ast", ast_module);

    // Meta Events module - Inject koru:start and koru:end lifecycle events into AST
    const meta_events_module = b.createModule(.{
        .root_source_file = b.path("src/meta_events.zig"),
        .target = target,
        .optimize = optimize,
    });
    meta_events_module.addImport("ast", ast_module);
    meta_events_module.addImport("errors", errors_module);

    // Validate Abstract Implementation module
    const validate_abstract_impl_module = b.createModule(.{
        .root_source_file = b.path("src/validate_abstract_impl.zig"),
        .target = target,
        .optimize = optimize,
    });
    validate_abstract_impl_module.addImport("ast", ast_module);
    validate_abstract_impl_module.addImport("errors", errors_module);

    // Tap Transformer module - AST transformation pass for zero-cost taps
    const tap_transformer_module = b.createModule(.{
        .root_source_file = b.path("src/tap_transformer.zig"),
        .target = target,
        .optimize = optimize,
    });
    tap_transformer_module.addImport("ast", ast_module);
    tap_transformer_module.addImport("tap_registry", tap_registry_module);
    tap_transformer_module.addImport("emitter_helpers", emitter_helpers_module);
    // NOTE: purity_helpers dependency added later after module is defined

    // Now add tap_registry to modules that need it
    emitter_helpers_module.addImport("tap_registry", tap_registry_module);
    visitor_emitter_module.addImport("tap_registry", tap_registry_module);

    // Main compiler executable
    const exe = b.addExecutable(.{
        .name = "koruc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    
    // Add module imports to koruc
    exe.root_module.addImport("parser", parser_module);
    exe.root_module.addImport("shape_checker", shape_checker_module);
    exe.root_module.addImport("phantom_semantic_checker", phantom_semantic_checker_module);
    exe.root_module.addImport("tap_collector", tap_collector_module);
    exe.root_module.addImport("tap_codegen", tap_codegen_module);
    exe.root_module.addImport("compiler_requires", compiler_requires_module);
    exe.root_module.addImport("package_requires", package_requires_module);
    exe.root_module.addImport("emit_build_zig", emit_build_zig_module);
    exe.root_module.addImport("emit_package_files", emit_package_files_module);
    exe.root_module.addImport("config", config_module);
    exe.root_module.addImport("module_resolver", module_resolver_module);
    exe.root_module.addImport("annotation_parser", annotation_parser_module);
    // emitter module removed - using visitor_emitter
    exe.root_module.addImport("ast", ast_module);
    exe.root_module.addImport("errors", errors_module);
    exe.root_module.addImport("type_registry", type_registry_module);
    exe.root_module.addImport("keyword_registry", keyword_registry_module);
    exe.root_module.addImport("ast_serializer", ast_serializer_module);
    exe.root_module.addImport("ast_transform", ast_transform_module);
    exe.root_module.addImport("transforms/inline_small_events", inline_transform_module);

    // Add visitor emitter modules (needed for generateComptimeBackendEmitted)
    exe.root_module.addImport("compiler_config", compiler_config_module);
    exe.root_module.addImport("emitter_helpers", emitter_helpers_module);
    exe.root_module.addImport("visitor_emitter", visitor_emitter_module);
    exe.root_module.addImport("tap_registry", tap_registry_module);
    exe.root_module.addImport("tap_transformer", tap_transformer_module);
    exe.root_module.addImport("canonicalize_names", canonicalize_names_module);
    exe.root_module.addImport("meta_events", meta_events_module);
    exe.root_module.addImport("validate_abstract_impl", validate_abstract_impl_module);
    exe.root_module.addImport("flow_checker", flow_checker_module);
    exe.root_module.addImport("branch_checker", branch_checker_module);

    // Functional AST modules
    const ast_functional_module = b.createModule(.{
        .root_source_file = b.path("src/ast_functional.zig"),
        .target = target,
        .optimize = optimize,
    });
    ast_functional_module.addImport("ast", ast_module);

    const transform_functional_module = b.createModule(.{
        .root_source_file = b.path("src/transform_functional.zig"),
        .target = target,
        .optimize = optimize,
    });
    transform_functional_module.addImport("ast", ast_module);
    transform_functional_module.addImport("ast_functional", ast_functional_module);
    
    const inline_functional_module = b.createModule(.{
        .root_source_file = b.path("src/transforms/inline_small_events_functional.zig"),
        .target = target,
        .optimize = optimize,
    });
    inline_functional_module.addImport("ast", ast_module);
    inline_functional_module.addImport("ast_functional", ast_functional_module);
    inline_functional_module.addImport("transform_functional", transform_functional_module);
    
    exe.root_module.addImport("ast_functional", ast_functional_module);
    exe.root_module.addImport("transform_functional", transform_functional_module);
    exe.root_module.addImport("transforms/inline_small_events_functional", inline_functional_module);

    // Fusion Optimizer module (EXPERIMENTAL)
    const fusion_optimizer_module = b.createModule(.{
        .root_source_file = b.path("src/fusion_optimizer.zig"),
        .target = target,
        .optimize = optimize,
    });
    fusion_optimizer_module.addImport("ast", ast_module);
    fusion_optimizer_module.addImport("ast_functional", ast_functional_module);
    fusion_optimizer_module.addImport("fusion_detector.zig", b.createModule(.{
        .root_source_file = b.path("src/fusion_detector.zig"),
        .target = target,
        .optimize = optimize,
    }));
    exe.root_module.addImport("fusion_optimizer.zig", fusion_optimizer_module);

    // Transform Collector module for two-layer AST transformation
    const transform_collector_module = b.createModule(.{
        .root_source_file = b.path("src/transform_collector.zig"),
        .target = target,
        .optimize = optimize,
    });
    transform_collector_module.addImport("ast", ast_module);
    transform_collector_module.addImport("ast_functional", ast_functional_module);
    exe.root_module.addImport("transform_collector", transform_collector_module);

    // Compiler module for metacircular compilation
    const compiler_module = b.createModule(.{
        .root_source_file = b.path("src/compiler.zig"),
        .target = target,
        .optimize = optimize,
    });
    compiler_module.addImport("ast", ast_module);
    exe.root_module.addImport("compiler", compiler_module);

    b.installArtifact(exe);

    // Create a run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the compiler");
    run_step.dependOn(&run_cmd.step);
    
    // Tests - simpler approach
    
    // Compiler Coordinator module for multi-pass optimization
    const coordinator_module = b.createModule(.{
        .root_source_file = b.path("src/compiler_coordinator.zig"),
        .target = target,
        .optimize = optimize,
    });
    coordinator_module.addImport("ast", ast_module);
    coordinator_module.addImport("ast_transform", ast_transform_module);
    coordinator_module.addImport("ast_visitor", ast_visitor_module);
    coordinator_module.addImport("transforms/inline_small_events.zig", inline_transform_module);
    
    const parser_tests = b.addTest(.{
        .name = "parser_tests",
        .root_module = parser_module,
    });
    
    const ast_serializer_tests = b.addTest(.{
        .name = "ast_serializer_tests",
        .root_module = ast_serializer_module,
    });
    
    const lexer_tests = b.addTest(.{
        .name = "lexer_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lexer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    
    const shape_checker_tests = b.addTest(.{
        .name = "shape_checker_tests",
        .root_module = shape_checker_module,
    });
    
    const tap_collector_tests = b.addTest(.{
        .name = "tap_collector_tests",
        .root_module = tap_collector_module,
    });
    
    const tap_codegen_tests = b.addTest(.{
        .name = "tap_codegen_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/tap_codegen_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tap_codegen_tests.root_module.addImport("tap_codegen", tap_codegen_module);
    tap_codegen_tests.root_module.addImport("ast", ast_module);

    // Visitor Emitter tests - orchestration tests
    const visitor_emitter_tests = b.addTest(.{
        .name = "visitor_emitter_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/visitor_emitter_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    visitor_emitter_tests.root_module.addImport("ast", ast_module);
    visitor_emitter_tests.root_module.addImport("emitter_helpers", emitter_helpers_module);
    visitor_emitter_tests.root_module.addImport("visitor_emitter", visitor_emitter_module);
    visitor_emitter_tests.root_module.addImport("tap_registry", tap_registry_module);
    visitor_emitter_tests.root_module.addImport("type_registry", type_registry_module);

    const integration_tests = b.addTest(.{
        .name = "integration_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/parser_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    
    // Need to add dependencies for the integration test
    integration_tests.root_module.addImport("parser", parser_module);
    integration_tests.root_module.addImport("ast", ast_module);
    integration_tests.root_module.addImport("lexer", lexer_module);
    
    // Shape checker integration tests
    const shape_checker_integration_tests = b.addTest(.{
        .name = "shape_checker_integration_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/shape_checker_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    
    // Inline flow extraction tests
    const inline_flow_tests = b.addTest(.{
        .name = "inline_flow_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/inline_flow_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    inline_flow_tests.root_module.addImport("parser", parser_module);
    inline_flow_tests.root_module.addImport("ast", ast_module);
    const run_inline_flow_tests = b.addRunArtifact(inline_flow_tests);
    
    // Purity helpers module (shared)
    const purity_helpers_module = b.createModule(.{
        .root_source_file = b.path("src/compiler_passes/purity_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    purity_helpers_module.addImport("ast", ast_module);
    purity_helpers_module.addImport("lexer", lexer_module);

    // Now that purity_helpers is defined, add it to tap_transformer and emitter_helpers
    tap_transformer_module.addImport("compiler_passes/purity_helpers", purity_helpers_module);
    emitter_helpers_module.addImport("compiler_passes/purity_helpers", purity_helpers_module);

    // Compiler passes modules
    const purity_analyzer_module = b.createModule(.{
        .root_source_file = b.path("src/compiler_passes/purity_analyzer.zig"),
        .target = target,
        .optimize = optimize,
    });
    purity_analyzer_module.addImport("ast", ast_module);
    purity_analyzer_module.addImport("lexer", lexer_module);
    purity_analyzer_module.addImport("purity_helpers", purity_helpers_module);
    
    const effect_analyzer_module = b.createModule(.{
        .root_source_file = b.path("src/compiler_passes/effect_analyzer.zig"),
        .target = target,
        .optimize = optimize,
    });
    effect_analyzer_module.addImport("ast", ast_module);
    effect_analyzer_module.addImport("purity_helpers", purity_helpers_module);
    effect_analyzer_module.addImport("purity_analyzer", purity_analyzer_module);
    
    // Enhanced AST visitor module
    const ast_visitor_enhanced_module = b.createModule(.{
        .root_source_file = b.path("src/compiler_passes/ast_visitor_enhanced.zig"),
        .target = target,
        .optimize = optimize,
    });
    ast_visitor_enhanced_module.addImport("ast", ast_module);
    
    // Metadata aggregator module
    const metadata_aggregator_module = b.createModule(.{
        .root_source_file = b.path("src/compiler_passes/metadata_aggregator.zig"),
        .target = target,
        .optimize = optimize,
    });
    metadata_aggregator_module.addImport("ast", ast_module);
    metadata_aggregator_module.addImport("purity_analyzer", purity_analyzer_module);
    metadata_aggregator_module.addImport("effect_analyzer", effect_analyzer_module);
    
    // Purity analyzer tests
    const purity_analyzer_tests = b.addTest(.{
        .name = "purity_analyzer_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/purity_analyzer_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    purity_analyzer_tests.root_module.addImport("parser", parser_module);
    purity_analyzer_tests.root_module.addImport("ast", ast_module);
    purity_analyzer_tests.root_module.addImport("purity_analyzer", purity_analyzer_module);
    const run_purity_analyzer_tests = b.addRunArtifact(purity_analyzer_tests);
    
    // Compiler passes integration tests
    const compiler_passes_tests = b.addTest(.{
        .name = "compiler_passes_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/compiler_passes_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    compiler_passes_tests.root_module.addImport("parser", parser_module);
    compiler_passes_tests.root_module.addImport("ast", ast_module);
    compiler_passes_tests.root_module.addImport("purity_analyzer", purity_analyzer_module);
    compiler_passes_tests.root_module.addImport("effect_analyzer", effect_analyzer_module);
    const run_compiler_passes_tests = b.addRunArtifact(compiler_passes_tests);
    
    // Enhanced visitor tests
    const visitor_enhanced_tests = b.addTest(.{
        .name = "visitor_enhanced_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/visitor_enhanced_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    visitor_enhanced_tests.root_module.addImport("parser", parser_module);
    visitor_enhanced_tests.root_module.addImport("ast", ast_module);
    visitor_enhanced_tests.root_module.addImport("ast_visitor_enhanced", ast_visitor_enhanced_module);
    visitor_enhanced_tests.root_module.addImport("purity_analyzer", purity_analyzer_module);
    visitor_enhanced_tests.root_module.addImport("effect_analyzer", effect_analyzer_module);
    visitor_enhanced_tests.root_module.addImport("metadata_aggregator", metadata_aggregator_module);
    const run_visitor_enhanced_tests = b.addRunArtifact(visitor_enhanced_tests);
    
    shape_checker_integration_tests.root_module.addImport("parser", parser_module);
    shape_checker_integration_tests.root_module.addImport("shape_checker", shape_checker_module);
    shape_checker_integration_tests.root_module.addImport("ast", ast_module);
    
    // Full pipeline integration tests
    const full_pipeline_tests = b.addTest(.{
        .name = "full_pipeline_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/full_pipeline_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    
    full_pipeline_tests.root_module.addImport("parser", parser_module);
    full_pipeline_tests.root_module.addImport("shape_checker", shape_checker_module);
    full_pipeline_tests.root_module.addImport("ast_serializer", ast_serializer_module);
    
    const run_parser_tests = b.addRunArtifact(parser_tests);
    const run_ast_serializer_tests = b.addRunArtifact(ast_serializer_tests);
    const run_lexer_tests = b.addRunArtifact(lexer_tests);
    const run_shape_checker_tests = b.addRunArtifact(shape_checker_tests);
    const run_tap_collector_tests = b.addRunArtifact(tap_collector_tests);
    const run_tap_codegen_tests = b.addRunArtifact(tap_codegen_tests);
    const run_visitor_emitter_tests = b.addRunArtifact(visitor_emitter_tests);
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const run_shape_checker_integration_tests = b.addRunArtifact(shape_checker_integration_tests);
    const run_full_pipeline_tests = b.addRunArtifact(full_pipeline_tests);
    
    // Add immediate return tests
    const immediate_return_tests = b.addTest(.{
        .name = "immediate_return_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/immediate_return_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    immediate_return_tests.root_module.addImport("parser", parser_module);
    immediate_return_tests.root_module.addImport("ast", ast_module);
    immediate_return_tests.root_module.addImport("lexer", lexer_module);
    immediate_return_tests.root_module.addImport("errors", errors_module);
    immediate_return_tests.root_module.addImport("type_registry", type_registry_module);
    const run_immediate_return_tests = b.addRunArtifact(immediate_return_tests);
    
    // Add vertical POC tests
    const vertical_poc_tests = b.addTest(.{
        .name = "vertical_poc_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/vertical_poc_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    vertical_poc_tests.root_module.addImport("parser", parser_module);
    vertical_poc_tests.root_module.addImport("ast", ast_module);
    const run_vertical_poc_tests = b.addRunArtifact(vertical_poc_tests);
    
    // Add compile-time POC tests
    const comptime_poc_simple_tests = b.addTest(.{
        .name = "comptime_poc_simple_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/comptime_poc_simple.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_comptime_poc_simple_tests = b.addRunArtifact(comptime_poc_simple_tests);
    
    // Add coordinator tests
    const coordinator_tests = b.addTest(.{
        .name = "coordinator_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/coordinator_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    coordinator_tests.root_module.addImport("compiler_coordinator", coordinator_module);
    coordinator_tests.root_module.addImport("ast", ast_module);
    const run_coordinator_tests = b.addRunArtifact(coordinator_tests);
    
    // Add transform tests
    const transform_tests = b.addTest(.{
        .name = "transform_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/transform_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    transform_tests.root_module.addImport("ast", ast_module);
    transform_tests.root_module.addImport("ast_transform", ast_transform_module);
    transform_tests.root_module.addImport("ast_visitor", ast_visitor_module);
    transform_tests.root_module.addImport("transforms/inline_small_events.zig", inline_transform_module);
    const run_transform_tests = b.addRunArtifact(transform_tests);
    
    // Add file types tests
    const file_types_tests = b.addTest(.{
        .name = "file_types_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/file_types_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    file_types_tests.root_module.addImport("parser", parser_module);
    file_types_tests.root_module.addImport("ast_serializer", ast_serializer_module);
    const run_file_types_tests = b.addRunArtifact(file_types_tests);
    
    // Where clause tests
    const where_clause_tests = b.addTest(.{
        .name = "where_clause_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/where_clause_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    where_clause_tests.root_module.addImport("parser", parser_module);
    where_clause_tests.root_module.addImport("ast", ast_module);
    const run_where_clause_tests = b.addRunArtifact(where_clause_tests);
    
    // Expression parser tests
    const expression_parser_tests = b.addTest(.{
        .name = "expression_parser_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/expression_parser_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    expression_parser_tests.root_module.addImport("expression_parser", expression_parser_module);
    const run_expression_parser_tests = b.addRunArtifact(expression_parser_tests);
    
    // Expression purity tests
    const expression_purity_tests = b.addTest(.{
        .name = "expression_purity_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/expression_purity_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    expression_purity_tests.root_module.addImport("expression_parser", expression_parser_module);
    const run_expression_purity_tests = b.addRunArtifact(expression_purity_tests);
    
    // Expression codegen tests
    const expression_codegen_tests = b.addTest(.{
        .name = "expression_codegen_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/expression_codegen_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    expression_codegen_tests.root_module.addImport("ast", ast_module);
    expression_codegen_tests.root_module.addImport("expression_codegen", expression_codegen_module);
    const run_expression_codegen_tests = b.addRunArtifact(expression_codegen_tests);
    
    // Expression codegen compile tests (verifies generated code compiles)
    const expression_codegen_compile_tests = b.addTest(.{
        .name = "expression_codegen_compile_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/expression_codegen_compile_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    expression_codegen_compile_tests.root_module.addImport("ast", ast_module);
    expression_codegen_compile_tests.root_module.addImport("expression_codegen", expression_codegen_module);
    const run_expression_codegen_compile_tests = b.addRunArtifact(expression_codegen_compile_tests);
    
    // Where clause integration tests
    const where_clause_integration_tests = b.addTest(.{
        .name = "where_clause_integration_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/where_clause_integration_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    where_clause_integration_tests.root_module.addImport("parser", parser_module);
    where_clause_integration_tests.root_module.addImport("ast", ast_module);
    where_clause_integration_tests.root_module.addImport("expression_codegen", expression_codegen_module);
    const run_where_clause_integration_tests = b.addRunArtifact(where_clause_integration_tests);
    
    // Inline flow extraction tests
    const inline_flow_extraction_tests = b.addTest(.{
        .name = "inline_flow_extraction_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/inline_flow_extraction_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    inline_flow_extraction_tests.root_module.addImport("parser", parser_module);
    inline_flow_extraction_tests.root_module.addImport("ast", ast_module);
    const run_inline_flow_extraction_tests = b.addRunArtifact(inline_flow_extraction_tests);
    
    // Branch constructor expression tests
    const branch_constructor_expr_tests = b.addTest(.{
        .name = "branch_constructor_expr_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/branch_constructor_expr_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    branch_constructor_expr_tests.root_module.addImport("parser", parser_module);
    branch_constructor_expr_tests.root_module.addImport("ast", ast_module);
    const run_branch_constructor_expr_tests = b.addRunArtifact(branch_constructor_expr_tests);
    
    // Branch constructor edge case tests
    const branch_constructor_edge_tests = b.addTest(.{
        .name = "branch_constructor_edge_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/branch_constructor_edge_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    branch_constructor_edge_tests.root_module.addImport("parser", parser_module);
    branch_constructor_edge_tests.root_module.addImport("ast", ast_module);
    const run_branch_constructor_edge_tests = b.addRunArtifact(branch_constructor_edge_tests);
    
    // Bootstrap constraint tests
    const bootstrap_constraint_tests = b.addTest(.{
        .name = "bootstrap_constraint_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/bootstrap_constraint_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bootstrap_constraint_tests.root_module.addImport("parser", parser_module);
    bootstrap_constraint_tests.root_module.addImport("ast", ast_module);
    bootstrap_constraint_tests.root_module.addImport("lexer", b.createModule(.{
        .root_source_file = b.path("src/lexer.zig"),
        .target = target,
        .optimize = optimize,
    }));
    bootstrap_constraint_tests.root_module.addImport("errors", errors_module);
    bootstrap_constraint_tests.root_module.addImport("type_registry", type_registry_module);
    bootstrap_constraint_tests.root_module.addImport("expression_parser", expression_parser_module);
    bootstrap_constraint_tests.root_module.addImport("union_collector", union_collector_module);
    bootstrap_constraint_tests.root_module.addImport("union_codegen", union_codegen_module);
    bootstrap_constraint_tests.root_module.addImport("expression_codegen", expression_codegen_module);
    const run_bootstrap_constraint_tests = b.addRunArtifact(bootstrap_constraint_tests);
    
    // Purity checker tests
    const purity_checker_tests = b.addTest(.{
        .name = "purity_checker_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/purity_checker_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    purity_checker_tests.root_module.addImport("parser", parser_module);
    purity_checker_tests.root_module.addImport("ast", ast_module);
    const run_purity_checker_tests = b.addRunArtifact(purity_checker_tests);

    // Tap transformer tests - AST transformation for zero-cost taps
    const tap_transformer_tests = b.addTest(.{
        .name = "tap_transformer_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tap_transformer_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tap_transformer_tests.root_module.addImport("ast", ast_module);
    tap_transformer_tests.root_module.addImport("tap_transformer", tap_transformer_module);
    tap_transformer_tests.root_module.addImport("tap_registry", tap_registry_module);
    const run_tap_transformer_tests = b.addRunArtifact(tap_transformer_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lexer_tests.step);
    test_step.dependOn(&run_parser_tests.step);
    test_step.dependOn(&run_ast_serializer_tests.step);
    test_step.dependOn(&run_shape_checker_tests.step);
    test_step.dependOn(&run_tap_collector_tests.step);
    test_step.dependOn(&run_purity_checker_tests.step);
    test_step.dependOn(&run_tap_codegen_tests.step);
    test_step.dependOn(&run_tap_transformer_tests.step);
    test_step.dependOn(&run_visitor_emitter_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_shape_checker_integration_tests.step);
    test_step.dependOn(&run_inline_flow_tests.step);
    test_step.dependOn(&run_purity_analyzer_tests.step);
    test_step.dependOn(&run_compiler_passes_tests.step);
    test_step.dependOn(&run_visitor_enhanced_tests.step);
    test_step.dependOn(&run_full_pipeline_tests.step);
    test_step.dependOn(&run_immediate_return_tests.step);
    test_step.dependOn(&run_vertical_poc_tests.step);
    test_step.dependOn(&run_comptime_poc_simple_tests.step);
    test_step.dependOn(&run_coordinator_tests.step);
    test_step.dependOn(&run_transform_tests.step);
    test_step.dependOn(&run_file_types_tests.step);
    test_step.dependOn(&run_where_clause_tests.step);
    test_step.dependOn(&run_expression_parser_tests.step);
    test_step.dependOn(&run_expression_purity_tests.step);
    test_step.dependOn(&run_expression_codegen_tests.step);
    test_step.dependOn(&run_expression_codegen_compile_tests.step);
    test_step.dependOn(&run_where_clause_integration_tests.step);
    test_step.dependOn(&run_inline_flow_extraction_tests.step);
    test_step.dependOn(&run_branch_constructor_expr_tests.step);
    test_step.dependOn(&run_branch_constructor_edge_tests.step);
    test_step.dependOn(&run_bootstrap_constraint_tests.step);
    
    // End-to-end branch constructor test
    const end_to_end_branch_tests = b.addTest(.{
        .name = "end_to_end_branch_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/end_to_end_branch_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    end_to_end_branch_tests.root_module.addImport("parser", parser_module);
    end_to_end_branch_tests.root_module.addImport("ast", ast_module);
    end_to_end_branch_tests.root_module.addImport("union_codegen", union_codegen_module);
    end_to_end_branch_tests.root_module.addImport("ast_serializer", ast_serializer_module);
    const run_end_to_end_branch_tests = b.addRunArtifact(end_to_end_branch_tests);
    test_step.dependOn(&run_end_to_end_branch_tests.step);
}