const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Path to Koru project root (two directories up)
    const koru_root = "../..";

    // Create Errors module (needed by AST)
    const errors_module = b.createModule(.{
        .root_source_file = b.path(koru_root ++ "/src/errors.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create AST module
    const ast_module = b.createModule(.{
        .root_source_file = b.path(koru_root ++ "/src/ast.zig"),
        .target = target,
        .optimize = optimize,
    });
    ast_module.addImport("errors", errors_module);

    // Create AST Functional module
    const ast_functional_module = b.createModule(.{
        .root_source_file = b.path(koru_root ++ "/src/ast_functional.zig"),
        .target = target,
        .optimize = optimize,
    });
    ast_functional_module.addImport("ast", ast_module);

    // Create Emitter module
    const emitter_module = b.createModule(.{
        .root_source_file = b.path(koru_root ++ "/src/emitter.zig"),
        .target = target,
        .optimize = optimize,
    });
    emitter_module.addImport("ast", ast_module);

    // Create Fusion Detector module
    const fusion_detector_module = b.createModule(.{
        .root_source_file = b.path(koru_root ++ "/src/fusion_detector.zig"),
        .target = target,
        .optimize = optimize,
    });
    fusion_detector_module.addImport("ast", ast_module);

    // Create Fusion Optimizer module
    const fusion_optimizer_module = b.createModule(.{
        .root_source_file = b.path(koru_root ++ "/src/fusion_optimizer.zig"),
        .target = target,
        .optimize = optimize,
    });
    fusion_optimizer_module.addImport("ast", ast_module);
    fusion_optimizer_module.addImport("ast_functional", ast_functional_module);
    fusion_optimizer_module.addImport("fusion_detector.zig", fusion_detector_module);

    // Step 1: Compile backend.zig → backend executable
    const backend = b.addExecutable(.{
        .name = "backend",
        .root_module = b.createModule(.{
            .root_source_file = b.path("backend.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    backend.root_module.addImport("emitter", emitter_module);
    backend.root_module.addImport("ast", ast_module);
    backend.root_module.addImport("ast_functional", ast_functional_module);
    backend.root_module.addImport("fusion_optimizer.zig", fusion_optimizer_module);

    b.installArtifact(backend);

    // Step 2: Run backend to generate output_emitted.zig
    const run_backend = b.addRunArtifact(backend);
    run_backend.addArg("tcp-echo");

    // Step 3: Compile output_emitted.zig → tcp-echo executable
    const tcp_echo = b.addExecutable(.{
        .name = "tcp-echo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("output_emitted.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tcp_echo.step.dependOn(&run_backend.step);

    b.installArtifact(tcp_echo);

    // Default run step
    const run_cmd = b.addRunArtifact(tcp_echo);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the TCP echo server");
    run_step.dependOn(&run_cmd.step);
}
