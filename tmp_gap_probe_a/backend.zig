// Koru Backend (Pass 2) — thin driver; PROGRAM_AST lives in program_ast.zig
// This file IS the compiler backend - it generates final code at compile-time

const Program = @import("ast").Program;
const ast_json_mod = @import("ast_json");
fn maybeDeinitAst(_: *const Program) void {}

const emitter_helpers = @import("emitter_helpers");
const __koru_std = @import("std");
const log = @import("log");

// Compiler environment lives in compiler_env.zig — re-exported here so
// `@import("root").CompilerEnv` keeps working for existing consumers.
pub const CompilerEnv = @import("compiler_env").CompilerEnv;

// Metacircular Code Generator

const __koru_ast = @import("ast");
comptime { _ = @import("backend_output"); }

const KoruCoordinateResult = extern struct {
    is_error: bool,
    code_ptr: [*]const u8,
    code_len: usize,
    metrics_ptr: [*]const u8,
    metrics_len: usize,
    error_ptr: [*]const u8,
    error_len: usize,
};
extern fn koru_coordinate(
    program_ast: *const __koru_ast.Program,
    allocator: *const __koru_std.mem.Allocator,
) KoruCoordinateResult;

extern fn koru_command_dispatch(
    name: *const anyopaque, // *const []const u8
    program: *const __koru_ast.Program,
    allocator: *const __koru_std.mem.Allocator,
    argv: *const anyopaque, // *const []const []const u8 (Zig slice; cast on the other side)
) void;

extern fn koru_run_pass(
    annotation: *const anyopaque, // *const []const u8
    program: *const __koru_ast.Program,
    allocator: *const __koru_std.mem.Allocator,
    out_program: *?*const __koru_ast.Program,
) bool;

// Re-export transform dispatcher — Zig-side shim around the extern wrapper
// so existing callers in src/ see an unchanged calling convention.
pub fn process_all_transforms(
    annotation: []const u8,
    program: *const __koru_ast.Program,
    allocator: __koru_std.mem.Allocator,
) !*const __koru_ast.Program {
    var out_program: ?*const __koru_ast.Program = null;
    const ok = koru_run_pass(@ptrCast(&annotation), program, &allocator, &out_program);
    if (!ok) return error.TransformFailed;
    return out_program orelse return error.TransformFailed;
}

// Helper: Join path segments with dots
const joinPath = struct {
    fn call(path: []const []const u8) []const u8 {
        if (path.len == 0) return "";
        if (path.len == 1) return path[0];
        var total_len: usize = path[0].len;
        var i: usize = 1;
        while (i < path.len) : (i += 1) {
            total_len += 1 + path[i].len;
        }
        var result: [256]u8 = undefined;
        var pos: usize = 0;
        @memcpy(result[pos..pos + path[0].len], path[0]);
        pos += path[0].len;
        i = 1;
        while (i < path.len) : (i += 1) {
            result[pos] = '.';
            pos += 1;
            @memcpy(result[pos..pos + path[i].len], path[i]);
            pos += path[i].len;
        }
        return result[0..pos];
    }
}.call;

// Runtime emitter - calls the coordinate event from compiler.kz
// The visitor emitter handles abstract/impl resolution automatically
const RuntimeEmitter = struct {
    pub fn emit(allocator: __koru_std.mem.Allocator, source_ast: *const Program) ![]const u8 {
        const result = koru_coordinate(source_ast, &allocator);
        if (result.is_error) {
            const e = result.error_ptr[0..result.error_len];
            __koru_std.debug.print("❌ Compiler coordination error: {s}\n", .{e});
            return error.CompilerCoordinationFailed;
        }
        const metrics = result.metrics_ptr[0..result.metrics_len];
        const code = result.code_ptr[0..result.code_len];
        __koru_std.debug.print("🎯 Compiler coordination: {s}\n", .{metrics});
        return code;
    }
};
// AST Dump Helper - observability for compiler pipeline debugging
// Note: This version doesn't serialize to JSON (ast_serializer not available in backend.zig)
// Full JSON dumps are available in backend_output_emitted.zig (dump points 3-7)
fn dumpAST(program_ast: *const Program, stage: []const u8, allocator: __koru_std.mem.Allocator) void {
    // Check if AST dumping is enabled via environment variable
    const dump_enabled: ?[]const u8 = __koru_std.process.getEnvVarOwned(allocator, "KORU_DUMP_AST") catch |err| blk: {
        if (err == error.EnvironmentVariableNotFound) break :blk null;
        break :blk null;
    };
    defer if (dump_enabled) |val| allocator.free(val);

    if (dump_enabled == null) return;  // Not enabled

    __koru_std.debug.print("\n============================================================\n", .{});
    __koru_std.debug.print("AST DUMP: {s}\n", .{stage});
    __koru_std.debug.print("============================================================\n", .{});
    __koru_std.debug.print("Items: {d}\n", .{program_ast.items.len});
    __koru_std.debug.print("Module: {s}\n", .{program_ast.main_module_name});
    __koru_std.debug.print("============================================================\n\n", .{});
}
// === KORU BACKEND CODE GENERATOR ===
// This outputs the final Zig code generated by compiler.emit.zig

pub fn main() !void {
    var gpa = __koru_std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leak_status = gpa.deinit();
        if (leak_status == .leak) {
            __koru_std.debug.print("Memory leak detected\n", .{});
        }
    }
    const allocator = gpa.allocator();

    // Arena allocator for compilation phase - all compiler passes, code generation, etc.
    var compile_arena = __koru_std.heap.ArenaAllocator.init(allocator);
    defer compile_arena.deinit();
    const compile_allocator = compile_arena.allocator();

    // Get the output filename from argv (passed from koruc)
    const args = try __koru_std.process.argsAlloc(allocator);
    defer __koru_std.process.argsFree(allocator, args);

    // Default output names.
    // JS-target spike: --lang=js writes output_emitted.js instead of .zig.
    // CompilerEnv.lang is baked per-invocation in compiler_env.zig and
    // re-exported as `pub const CompilerEnv` at the top of this backend.
    const emitted_file = if (__koru_std.mem.eql(u8, CompilerEnv.lang, "js"))
        "output_emitted.js"
    else
        "output_emitted.zig";
    const seed_ast: *Program = blk: {
        const ast_file = __koru_std.fs.cwd().openFile("program.ast.json", .{}) catch |err| {
            __koru_std.debug.print("❌ Backend: cannot open program.ast.json: {s}\n", .{@errorName(err)});
            return err;
        };
        defer ast_file.close();
        const ast_json_bytes = try ast_file.readToEndAlloc(compile_allocator, 256 * 1024 * 1024);
        const p = try compile_allocator.create(Program);
        p.* = try ast_json_mod.deserialize(compile_allocator, ast_json_bytes);
        break :blk p;
    };
    // Check for CLI commands in argv
    // Note: backend_output is already imported at file scope
    if (args.len > 1) {
        if (__koru_std.mem.eql(u8, args[1], "deps")) {
            __koru_std.debug.print("🔧 Running command: deps\n", .{});
            const cmd_name: []const u8 = "deps";
            const argv_slice: []const []const u8 = args[2..];
            koru_command_dispatch(@ptrCast(&cmd_name), seed_ast, &allocator, @ptrCast(&argv_slice));
            return;
        }
    }
    // NOTE: args[1] is the output exe name when called from frontend,
    // but when running backend directly, args[1] might be the input Koru source file.
    // Detect this case and default to "a.out" instead of overwriting the source!
    const output_exe = if (args.len > 1 and
        !__koru_std.mem.endsWith(u8, args[1], ".kgpu") and
        !__koru_std.mem.endsWith(u8, args[1], ".kjs") and
        !__koru_std.mem.endsWith(u8, args[1], ".kz") and
        !__koru_std.mem.endsWith(u8, args[1], ".kc") and
        !__koru_std.mem.endsWith(u8, args[1], ".k")) args[1] else "a.out";

    // Apply compiler passes
    // Each pass takes PROGRAM_AST pointer and current AST pointer
    // Returns same pointer if no changes, or new heap-allocated AST if optimized
    const current_ast: *const Program = seed_ast;

    // DUMP POINT 1: Original AST at backend entry
    dumpAST(seed_ast, "1-backend-start", compile_allocator);

    // More passes can go here...

    const final_ast = current_ast;
    defer maybeDeinitAst(final_ast);

    // DUMP POINT 2: Final AST before emission (after all backend transforms)
    dumpAST(final_ast, "2-pre-emit", compile_allocator);

    // Generate code from AST (possibly fused)
    const generated_code = try RuntimeEmitter.emit(compile_allocator, final_ast);

    // DEBUG: Check generated_code before file write
    log.debug("\n[MAIN DEBUG] Before file write:\n", .{});
    log.debug("[MAIN DEBUG]   generated_code.len = {d}\n", .{generated_code.len});
    log.debug("[MAIN DEBUG]   generated_code.ptr = {*}\n", .{generated_code.ptr});
    log.debug("[MAIN DEBUG]   emitted_file = {s}\n", .{emitted_file});
    log.debug("[MAIN DEBUG]   emitted_file.ptr = {*}\n", .{emitted_file.ptr});
    log.debug("[MAIN DEBUG]   First 50 bytes: ", .{});
    for (generated_code[0..@min(50, generated_code.len)]) |byte| {
        if (byte >= 32 and byte < 127) {
            log.debug("{c}", .{byte});
        } else {
            log.debug("[{d}]", .{byte});
        }
    }
    log.debug("\n\n", .{});

    // Write the generated code to a file
    const file = try __koru_std.fs.cwd().createFile(emitted_file, .{});
    defer file.close();
    try file.writeAll(generated_code);

    // Report what we generated
    const stdout = __koru_std.fs.File.stdout();
    var buf: [512]u8 = undefined;
    const msg = try __koru_std.fmt.bufPrint(&buf, "✓ Generated {s} ({d} bytes)\n", .{emitted_file, generated_code.len});
    try stdout.writeAll(msg);

    // JS-target spike: the JS path stops here. node runs output_emitted.js
    // directly — there is no Stage D (`zig build` of the emitted output) and
    // no a.out. Gated on CompilerEnv.lang so the Zig path below is untouched.
    if (__koru_std.mem.eql(u8, CompilerEnv.lang, "js")) return;

    // Now compile the emitted code
    // Check for cross-compilation target from build:config
    const build_target = emitter_helpers.getBuildConfig("target");

    // First check if build_output.zig exists (has user build requirements)
    const has_build_output = blk: {
        __koru_std.fs.cwd().access("build_output.zig", .{}) catch break :blk false;
        break :blk true;
    };

    if (has_build_output) {
        // Use zig build with build_output.zig (includes user dependencies)
        var bo_argv: [5][]const u8 = undefined;
        bo_argv[0] = "zig";
        bo_argv[1] = "build";
        bo_argv[2] = "--build-file";
        bo_argv[3] = "build_output.zig";
        var bo_argc: usize = 4;
        var dt_buf: [128]u8 = undefined;
        if (build_target) |t| {
            bo_argv[4] = __koru_std.fmt.bufPrint(&dt_buf, "-Dtarget={s}", .{t}) catch "-Dtarget=native";
            bo_argc = 5;
        }
        const result = __koru_std.process.Child.run(.{
            .allocator = allocator,
            .argv = bo_argv[0..bo_argc],
        }) catch |err| {
            const stderr = __koru_std.fs.File.stderr();
            var err_buf: [512]u8 = undefined;
            const err_msg = try __koru_std.fmt.bufPrint(&err_buf, "✗ Failed to spawn zig compiler: {}\n", .{err});
            try stderr.writeAll(err_msg);
            __koru_std.process.exit(1);
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const stdout2 = __koru_std.fs.File.stdout();
        var buf2: [512]u8 = undefined;
        if (result.term.Exited == 0) {
            // Copy from zig-out/bin/output to the requested output name
            __koru_std.fs.cwd().copyFile("zig-out/bin/output", __koru_std.fs.cwd(), output_exe, .{}) catch |copy_err| {
                const msg2 = try __koru_std.fmt.bufPrint(&buf2, "✗ Failed to copy output: {}\n", .{copy_err});
                try __koru_std.fs.File.stderr().writeAll(msg2);
                __koru_std.process.exit(1);
            };
            const msg2 = try __koru_std.fmt.bufPrint(&buf2, "✓ Compiled to {s}\n", .{output_exe});
            try stdout2.writeAll(msg2);
        } else {
            const msg2 = try __koru_std.fmt.bufPrint(&buf2, "✗ Compilation failed\n", .{});
            try stdout2.writeAll(msg2);
            if (result.stderr.len > 0) {
                var err_buf2: [65536]u8 = undefined;
                const err_msg2 = try __koru_std.fmt.bufPrint(&err_buf2, "Error: {s}\n", .{result.stderr});
                try __koru_std.fs.File.stderr().writeAll(err_msg2);
            }
            __koru_std.process.exit(1);
        }
    } else {
        // Fall back to direct zig build-exe (no user dependencies)
        var emit_path_buf: [256]u8 = undefined;
        const emit_path = try __koru_std.fmt.bufPrint(&emit_path_buf, "-femit-bin={s}", .{output_exe});
        const debug = CompilerEnv.hasFlag("debug");
        var exe_argv: [14][]const u8 = undefined;
        var exe_argc: usize = 0;
        exe_argv[exe_argc] = "zig"; exe_argc += 1;
        exe_argv[exe_argc] = "build-exe"; exe_argc += 1;
        exe_argv[exe_argc] = emitted_file; exe_argc += 1;
        // koru_allocator() backs onto std.heap.c_allocator (real libc
        // malloc/free) -- needs libc linked on this direct build-exe path too.
        exe_argv[exe_argc] = "-lc"; exe_argc += 1;
        if (build_target) |t| {
            exe_argv[exe_argc] = "-target"; exe_argc += 1;
            exe_argv[exe_argc] = t; exe_argc += 1;
        }
        exe_argv[exe_argc] = "-O"; exe_argc += 1;
        // Hyper-performance language: the OUTPUT binary defaults to
        // ReleaseFast. ReleaseSmall was the orphaned default of a removed
        // `--tiny` flag — a silent perf-degradation (it benchmarked
        // size-optimized koru against ReleaseFast rivals). `--debug`
        // produces a real Debug build for debugging.
        if (debug) {
            exe_argv[exe_argc] = "Debug"; exe_argc += 1;
        } else {
            exe_argv[exe_argc] = "ReleaseFast"; exe_argc += 1;
        }
        exe_argv[exe_argc] = emit_path; exe_argc += 1;
        const result = __koru_std.process.Child.run(.{
            .allocator = allocator,
            .argv = exe_argv[0..exe_argc],
        }) catch |err| {
            const stderr = __koru_std.fs.File.stderr();
            var err_buf: [512]u8 = undefined;
            const err_msg = try __koru_std.fmt.bufPrint(&err_buf, "✗ Failed to spawn zig compiler: {}\n", .{err});
            try stderr.writeAll(err_msg);
            __koru_std.process.exit(1);
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const stdout2 = __koru_std.fs.File.stdout();
        var buf2: [512]u8 = undefined;
        if (result.term.Exited == 0) {
            const msg2 = try __koru_std.fmt.bufPrint(&buf2, "✓ Compiled to {s}\n", .{output_exe});
            try stdout2.writeAll(msg2);
        } else {
            const msg2 = try __koru_std.fmt.bufPrint(&buf2, "✗ Compilation failed\n", .{});
            try stdout2.writeAll(msg2);
            if (result.stderr.len > 0) {
                var err_buf2: [65536]u8 = undefined;
                const err_msg2 = try __koru_std.fmt.bufPrint(&err_buf2, "Error: {s}\n", .{result.stderr});
                try __koru_std.fs.File.stderr().writeAll(err_msg2);
            }
            __koru_std.process.exit(1);
        }
    }
}