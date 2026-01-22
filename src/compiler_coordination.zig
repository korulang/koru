// Compiler Coordinator - Orchestrates compilation passes
const std = @import("std");
const ast = @import("ast");
const errors = @import("errors");
const phantom_semantic = @import("phantom_semantic_checker");

pub const CoordinationResult = struct {
    ast: *const ast.Program,
    metrics: []const u8,
    transformations_applied: usize,
};

/// The main coordination function that orchestrates compilation
/// NOTE: User overrides are now handled by the abstract/impl mechanism in compiler.kz
pub fn coordinate(
    allocator: std.mem.Allocator,
    source_ast: *const ast.Program,
    filename: []const u8,
) !CoordinationResult {
    std.debug.print("Coordinator: Running frontend passes\n", .{});
    
    // Default coordination strategy
    var current_ast = source_ast;
    var transformations: usize = 0;
    
    // Pass 1: Analysis
    const analysis = try analyzeAST(allocator, current_ast);
    defer allocator.free(analysis.metrics);
    
    // Pass 2: Planning
    const passes = try planPasses(allocator, analysis);
    defer allocator.free(passes);
    
    // Pass 3: Execution
    for (passes) |pass| {
        const result = try executePass(allocator, current_ast, pass, filename);
        if (result.transformed) {
            current_ast = result.ast;
            transformations += 1;
        }
    }
    
    // Pass 4: Validation
    try validateAST(current_ast);
    
    return CoordinationResult{
        .ast = current_ast,
        .metrics = try std.fmt.allocPrint(
            allocator, 
            "Passes: {}, Transformations: {}", 
            .{passes.len, transformations}
        ),
        .transformations_applied = transformations,
    };
}

const AnalysisResult = struct {
    has_small_events: bool,
    has_loops: bool,
    has_dead_code: bool,
    metrics: []const u8,
};

fn analyzeAST(allocator: std.mem.Allocator, source_ast: *const ast.Program) !AnalysisResult {
    var small_event_count: usize = 0;
    var total_events: usize = 0;
    var has_loops = false;
    
    for (source_ast.items) |item| {
        switch (item) {
            .event_decl => |event| {
                total_events += 1;
                var field_count: usize = event.input.fields.len;
                for (event.branches) |branch| {
                    field_count += branch.payload.fields.len;
                }
                if (field_count <= 5) {
                    small_event_count += 1;
                }
            },
            .flow => |flow| {
                if (flow.post_label) |_| {
                    has_loops = true;
                }
            },
            else => {},
        }
    }
    
    const metrics = try std.fmt.allocPrint(
        allocator,
        "Events: {}, Small: {}, Loops: {}",
        .{total_events, small_event_count, has_loops}
    );
    
    return AnalysisResult{
        .has_small_events = small_event_count > 0,
        .has_loops = has_loops,
        .has_dead_code = false,
        .metrics = metrics,
    };
}

const Pass = enum {
    evaluate_comptime,  // MUST be first - can generate new events/branches
    inline_small_events,
    optimize_loops,
    eliminate_dead_code,
    validate_shapes,
    check_phantom_semantic,  // Phantom type checking
    inject_taps,
};

fn planPasses(allocator: std.mem.Allocator, analysis: AnalysisResult) ![]const Pass {
    var passes = try std.ArrayList(Pass).initCapacity(allocator, 7);  // Increased for comptime pass
    defer passes.deinit(allocator);

    // Comptime evaluation MUST run first (can generate new events/branches)
    try passes.append(allocator, .evaluate_comptime);

    try passes.append(allocator, .validate_shapes);

    // REMOVED: Phantom type checking must run AFTER transforms in the backend (compiler.kz)
    // Running it here in the frontend would check the untransformed AST with [transform] events
    // which haven't been replaced yet by process_all_transforms()
    // try passes.append(allocator, .check_phantom_semantic);

    // Always inject taps early in the pipeline (if any exist)
    try passes.append(allocator, .inject_taps);
    
    // TEMPORARILY DISABLED: Inlining generates invalid code for flows
    // Re-enable when the inliner is fixed to generate valid Zig
    const enable_inlining = false;
    if (enable_inlining and analysis.has_small_events) {
        try passes.append(allocator, .inline_small_events);
    }
    
    if (analysis.has_loops) {
        try passes.append(allocator, .optimize_loops);
    }
    
    if (analysis.has_dead_code) {
        try passes.append(allocator, .eliminate_dead_code);
    }
    
    return try passes.toOwnedSlice(allocator);
}

const PassResult = struct {
    ast: *const ast.Program,
    transformed: bool,
};

/// Check if an event is comptime-only (has Program or Source parameters)
fn isComptimeOnlyEvent(event_decl: *const ast.EventDecl) bool {
    for (event_decl.input.fields) |field| {
        if (field.is_source or field.is_expression) {
            return true;
        }
        // Check for Program type (which is an alias for Program), or Item
        if (std.mem.eql(u8, field.type, "Program") or 
            std.mem.eql(u8, field.type, "Program") or
            std.mem.eql(u8, field.type, "Item") or
            std.mem.eql(u8, field.type, "*const Item") or
            std.mem.eql(u8, field.type, "*const Program")) 
        {
            return true;
        }
    }
    return false;
}

fn executePass(
    allocator: std.mem.Allocator,
    source_ast: *const ast.Program,
    pass: Pass,
    filename: []const u8,
) !PassResult {
    switch (pass) {
        .evaluate_comptime => {
            std.debug.print("Coordinator: Executing evaluate_comptime pass\n", .{});

            // First, build a map of which events are comptime-only
            var comptime_events = std.StringHashMap(bool).init(allocator);
            defer comptime_events.deinit();

            for (source_ast.items) |item| {
                switch (item) {
                    .event_decl => |event_decl| {
                        const event_name = try std.mem.join(allocator, ".", event_decl.path.segments);
                        defer allocator.free(event_name);
                        std.debug.print("  [DEBUG] Checking top-level event: {s}\n", .{event_name});
                        
                        // Check if this event has comptime-only parameters
                        if (isComptimeOnlyEvent(&event_decl)) {
                            const gop = try comptime_events.getOrPut(event_name);
                            if (!gop.found_existing) {
                                std.debug.print("  Found comptime-only event: {s}\n", .{event_name});
                                gop.value_ptr.* = true;
                            }
                        }
                    },
                    .module_decl => |module| {
                        std.debug.print("  [DEBUG] Scanning module: {s} ({s}) items: {}\n", .{module.logical_name, module.canonical_path, module.items.len});
                        // Check events in imported modules too
                        for (module.items) |mod_item| {
                            std.debug.print("    [DEBUG] Item type: {s}\n", .{@tagName(mod_item)});
                            switch (mod_item) {
                                .event_decl => |event_decl| {
                                    const event_name = try std.mem.join(allocator, ".", event_decl.path.segments);
                                    defer allocator.free(event_name);
                                    std.debug.print("      [DEBUG] Event: {s}\n", .{event_name});
                                    if (isComptimeOnlyEvent(&event_decl)) {
                                        const full_name = if (module.logical_name.len > 0)
                                            try std.fmt.allocPrint(allocator, "{s}:{s}", .{module.logical_name, event_name})
                                        else
                                            try allocator.dupe(u8, event_name);
                                            
                                        const gop = try comptime_events.getOrPut(full_name);
                                        if (!gop.found_existing) {
                                            std.debug.print("      Found comptime-only event: {s}\n", .{full_name});
                                            gop.value_ptr.* = true;
                                        } else {
                                            allocator.free(full_name);
                                        }
                                    }
                                },
                                .proc_decl => |proc| {
                                    const proc_name = try std.mem.join(allocator, ".", proc.path.segments);
                                    defer allocator.free(proc_name);
                                    std.debug.print("      [DEBUG] Proc: {s}\n", .{proc_name});
                                },
                                .subflow_impl => |subflow| {
                                    const flow_name = try std.mem.join(allocator, ".", subflow.event_path.segments);
                                    defer allocator.free(flow_name);
                                    std.debug.print("      [DEBUG] Subflow: {s}\n", .{flow_name});
                                },
                                else => {},
                            }
                        }
                    },
                    else => {
                        // std.debug.print("  [DEBUG] Ignoring top-level item type: {}\n", .{@as(ast.Item, item)});
                    },
                }
            }

            // TODO: Walk flows and find invocations of comptime events
            // For now, just report what we found
            std.debug.print("  Detected {} comptime-only event definitions\n", .{comptime_events.count()});

            return PassResult{
                .ast = source_ast,
                .transformed = false,
            };
        },
        .inline_small_events => {
            std.debug.print("Coordinator: Executing inline_small_events pass\n", .{});
            return PassResult{
                .ast = source_ast,
                .transformed = false,
            };
        },
        .optimize_loops => {
            std.debug.print("Coordinator: Executing optimize_loops pass\n", .{});
            return PassResult{
                .ast = source_ast,
                .transformed = false,
            };
        },
        .eliminate_dead_code => {
            std.debug.print("Coordinator: Executing eliminate_dead_code pass\n", .{});
            return PassResult{
                .ast = source_ast,
                .transformed = false,
            };
        },
        .validate_shapes => {
            std.debug.print("Coordinator: Executing validate_shapes pass\n", .{});
            return PassResult{
                .ast = source_ast,
                .transformed = false,
            };
        },
        .check_phantom_semantic => {
            // Create error reporter for phantom checker
            var reporter = try errors.ErrorReporter.init(allocator, filename, "");
            defer reporter.deinit();

            // Run phantom semantic checker
            var checker = try phantom_semantic.PhantomSemanticChecker.init(allocator, &reporter);
            defer checker.deinit();

            checker.check(source_ast) catch |err| {
                // Report errors and fail compilation
                if (reporter.errors.items.len > 0) {
                    std.debug.print("Phantom type checking failed:\n", .{});
                    var buf = try std.ArrayList(u8).initCapacity(allocator, 4096);
                    defer buf.deinit(allocator);
                    try reporter.printErrors(buf.writer(allocator));
                    std.debug.print("{s}", .{buf.items});
                }
                return err;
            };

            // Check if any errors were reported during checking
            if (reporter.hasErrors()) {
                std.debug.print("Phantom type checking failed with {} errors:\n", .{reporter.errors.items.len});
                var buf = try std.ArrayList(u8).initCapacity(allocator, 4096);
                defer buf.deinit(allocator);
                try reporter.printErrors(buf.writer(allocator));
                std.debug.print("{s}", .{buf.items});
                return error.PhantomTypeCheckFailed;
            }

            return PassResult{
                .ast = source_ast,
                .transformed = false,
            };
        },
        .inject_taps => {
            std.debug.print("Coordinator: Executing inject_taps pass\n", .{});
            // TODO: Actually inject tap calls using TapCollector and TapCodegen
            return PassResult{
                .ast = source_ast,
                .transformed = false,
            };
        },
    }
}

fn validateAST(source_ast: *const ast.Program) !void {
    _ = source_ast;
    std.debug.print("Coordinator: AST validation passed\n", .{});
}