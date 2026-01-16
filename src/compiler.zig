const std = @import("std");
const ast = @import("ast");

/// Compiler Bootstrap - Metacircular Compilation Support
///
/// This module implements the bootstrap mechanism that:
/// 1. Detects if user has overridden compiler.coordinate
/// 2. Injects compiler.coordinate.default when override exists
/// 3. Makes all compiler passes available as events
/// 4. Enables complete compiler replaceability

pub const CompilerBootstrap = struct {
    allocator: std.mem.Allocator,
    has_user_override: bool,
    user_override_ast: ?*const ast.SubflowImpl = null,
    
    /// Check if the AST contains a user override for compiler.coordinate
    pub fn checkForOverride(allocator: std.mem.Allocator, source_file: *const ast.Program) !CompilerBootstrap {
        var bootstrap = CompilerBootstrap{
            .allocator = allocator,
            .has_user_override = false,
            .user_override_ast = null,
        };
        
        std.debug.print("Bootstrap: Checking for compiler.coordinate override...\n", .{});

        // Look for ~compiler.coordinate = ... (subflow) or ~proc compiler.coordinate (proc_decl)
        // Check both top-level and inside modules
        for (source_file.items) |*item| {
            switch (item.*) {
                .subflow_impl => |*subflow| {
                    std.debug.print("Bootstrap: Found subflow for event: ", .{});
                    for (subflow.event_path.segments, 0..) |seg, i| {
                        if (i > 0) std.debug.print(".", .{});
                        std.debug.print("{s}", .{seg});
                    }
                    std.debug.print("\n", .{});

                    if (isCompilerCoordinate(&subflow.event_path)) {
                        std.debug.print("Bootstrap: DETECTED compiler.coordinate override (subflow)!\n", .{});
                        bootstrap.has_user_override = true;
                        bootstrap.user_override_ast = subflow;
                        break;
                    }
                },
                .proc_decl => |*proc| {
                    std.debug.print("Bootstrap: Found proc for event: ", .{});
                    for (proc.path.segments, 0..) |seg, i| {
                        if (i > 0) std.debug.print(".", .{});
                        std.debug.print("{s}", .{seg});
                    }
                    std.debug.print("\n", .{});

                    if (isCompilerCoordinate(&proc.path)) {
                        std.debug.print("Bootstrap: DETECTED compiler.coordinate override (proc)!\n", .{});
                        bootstrap.has_user_override = true;
                        // Note: user_override_ast remains null for proc overrides
                        break;
                    }
                },
                .module_decl => |*module| {
                    // Also check inside modules (like compiler_bootstrap)
                    std.debug.print("Bootstrap: Checking inside module: {s}\n", .{module.logical_name});
                    for (module.items) |*mod_item| {
                        switch (mod_item.*) {
                            .subflow_impl => |*subflow| {
                                if (isCompilerCoordinate(&subflow.event_path)) {
                                    std.debug.print("Bootstrap: DETECTED compiler.coordinate override in module (subflow)!\n", .{});
                                    bootstrap.has_user_override = true;
                                    bootstrap.user_override_ast = subflow;
                                    break;
                                }
                            },
                            .proc_decl => |*proc| {
                                if (isCompilerCoordinate(&proc.path)) {
                                    std.debug.print("Bootstrap: DETECTED compiler.coordinate override in module (proc)!\n", .{});
                                    bootstrap.has_user_override = true;
                                    break;
                                }
                            },
                            else => {},
                        }
                    }
                    if (bootstrap.has_user_override) break;
                },
                else => {},
            }
        }
        
        std.debug.print("Bootstrap: Override detected = {}\n", .{bootstrap.has_user_override});
        
        return bootstrap;
    }
    
    /// Check if user has overridden the compiler coordinator
    /// NOTE: The default coordinator is hardcoded in main.zig, not injected as a flow
    pub fn injectDefaults(self: *CompilerBootstrap, source_file: *ast.Program) !void {
        _ = source_file; // Not used - coordinator is hardcoded in main.zig

        if (!self.has_user_override) {
            std.debug.print("Bootstrap: Using default compiler coordinator (hardcoded in main.zig)\n", .{});
        } else {
            std.debug.print("Bootstrap: User has overridden compiler.coordinate, using their implementation\n", .{});
        }
    }
    
    /// Generate the compile-time code for compiler coordination
    pub fn generateComptimeCode(self: *CompilerBootstrap) ![]const u8 {
        var code = try std.ArrayList(u8).initCapacity(self.allocator, 4096);
        defer code.deinit();
        
        // Generate the koruCompile function
        try code.appendSlice(
            \\pub fn koruCompile(comptime ast: Program, comptime config: CompileConfig) Program {
            \\    comptime {
            \\
        );
        
        if (self.has_user_override) {
            // User has override, call their implementation
            try code.appendSlice(
                \\        // User has overridden compiler.coordinate
                \\        // Default implementation available as compiler.coordinate.default
                \\        return callUserCoordinator(ast, config);
                \\
            );
        } else {
            // Use default implementation
            try code.appendSlice(
                \\        // Using default compiler.coordinate implementation
                \\        return defaultCoordinate(ast, config);
                \\
            );
        }
        
        try code.appendSlice(
            \\    }
            \\}
            \\
        );
        
        // Generate the default coordinator implementation
        try self.generateDefaultCoordinator(&code);
        
        if (self.has_user_override) {
            // Generate user coordinator caller
            try self.generateUserCoordinatorCaller(&code);
        }
        
        // Generate individual pass implementations
        try self.generatePassImplementations(&code);
        
        return try code.toOwnedSlice();
    }
    
    // Private helper functions
    
    fn isCompilerCoordinate(path: *const ast.DottedPath) bool {
        if (path.segments.len != 2) return false;
        return std.mem.eql(u8, path.segments[0], "compiler") and
               std.mem.eql(u8, path.segments[1], "coordinate");
    }

    // NOTE: injectDefaultBinding() removed - the coordinator is hardcoded in main.zig

    fn generateDefaultCoordinator(_: *CompilerBootstrap, code: *std.ArrayList(u8)) !void {
        try code.appendSlice(
            \\fn defaultCoordinate(comptime ast: Program, comptime config: CompileConfig) Program {
            \\    // Analyze the AST
            \\    const analysis = analyzeAST(ast, config);
            \\    
            \\    // Plan passes based on analysis
            \\    const passes = planPasses(analysis, config);
            \\    
            \\    // Execute passes
            \\    var current_ast = ast;
            \\    for (passes) |pass| {
            \\        current_ast = executePass(current_ast, pass);
            \\    }
            \\    
            \\    // Validate final AST
            \\    validateAST(current_ast);
            \\    
            \\    return current_ast;
            \\}
            \\
        );
    }
    
    fn generateUserCoordinatorCaller(_: *CompilerBootstrap, code: *std.ArrayList(u8)) !void {
        try code.appendSlice(
            \\fn callUserCoordinator(comptime ast: Program, comptime config: CompileConfig) Program {
            \\    // This would invoke the user's ~compiler.coordinate implementation
            \\    // The actual implementation depends on how we translate Koru flows to Zig
            \\    return userCoordinate(ast, config);
            \\}
            \\
        );
    }
    
    fn generatePassImplementations(_: *CompilerBootstrap, code: *std.ArrayList(u8)) !void {
        // Generate inline pass
        try code.appendSlice(
            \\fn inlinePass(comptime ast: Program, comptime config: InlineConfig) Program {
            \\    // Use the functional inline transformer
            \\    const inline_functional = @import("transforms/inline_small_events_functional");
            \\    return inline_functional.inlineSmallEvents(ast, config);
            \\}
            \\
        );
        
        // Generate deadcode elimination pass
        try code.appendSlice(
            \\fn deadcodePass(comptime ast: Program) Program {
            \\    // Remove unreachable code
            \\    var result = ast;
            \\    // Implementation would analyze and remove dead branches
            \\    return result;
            \\}
            \\
        );
        
        // Generate fusion pass
        try code.appendSlice(
            \\fn fusionPass(comptime ast: Program) Program {
            \\    // Fuse similar branches
            \\    var result = ast;
            \\    // Implementation would detect and merge similar branches
            \\    return result;
            \\}
            \\
        );
        
        // Generate loop optimization pass
        try code.appendSlice(
            \\fn loopOptimizationPass(comptime ast: Program) Program {
            \\    // Optimize loops through unrolling and vectorization
            \\    var result = ast;
            \\    // Implementation would detect loops and optimize them
            \\    return result;
            \\}
            \\
        );
    }
};