const std = @import("std");
const ast = @import("ast");
const ast_functional = @import("ast_functional");
const fusion_detector = @import("fusion_detector.zig");

/// Fusion Optimizer - Functional AST transformation for event chain fusion
///
/// This module implements Phase 2 of the fusion optimization:
/// - Takes immutable Program
/// - Detects fusion opportunities
/// - Generates |fused variant procs with provenance tracking
/// - Returns NEW Program with both original and fused variants
///
/// Architecture: Purely functional - no mutation, uses ast_functional helpers

/// Optimize AST by generating fused variants for detected opportunities
/// Returns a pointer to the optimized AST:
/// - If no optimizations: returns the same pointer (no allocation)
/// - If optimizations applied: returns pointer to new heap-allocated AST, deinits input
pub fn optimize(
    allocator: std.mem.Allocator,
    program_ast: *const ast.Program,
    source: *const ast.Program
) !*const ast.Program {
    // Detect fusion opportunities
    var detector = fusion_detector.FusionDetector.init(allocator);
    defer detector.deinit();

    var report = try detector.detect(source);
    defer report.deinit();

    if (report.opportunities.items.len == 0) {
        // No opportunities - return the same pointer (no allocation!)
        return source;
    }

    // Start with clone of original AST
    var current_ast = try ast_functional.cloneSourceFile(allocator, source);
    errdefer current_ast.deinit();

    // For each opportunity, add a fused variant
    for (report.opportunities.items) |opportunity| {
        // Find the proc that contains this fusion opportunity
        const proc_index = findProcByName(&current_ast, opportunity.location) orelse continue;

        // Generate fused variant proc
        const fused_proc_item = try generateFusedVariant(allocator, &current_ast, proc_index, &opportunity);

        // Insert fused variant after the original proc
        const new_ast = try ast_functional.insertAt(allocator, &current_ast, proc_index + 1, fused_proc_item);

        // Clean up intermediate AST and move to new one
        current_ast.deinit();
        current_ast = new_ast;
    }

    // Clean up the input AST (safe - handles both PROGRAM_AST and heap ASTs)
    ast_functional.maybeDeinit(program_ast, source);

    // Allocate result on heap and return pointer
    const result_ptr = try allocator.create(ast.Program);
    result_ptr.* = current_ast;
    return result_ptr;
}

/// Find proc by name in source file
fn findProcByName(source: *const ast.Program, name: []const u8) ?usize {
    for (source.items, 0..) |*item, i| {
        if (item.* == .proc_decl) {
            const proc = &item.proc_decl;
            // Compare last segment of path
            if (proc.path.segments.len > 0) {
                const proc_name = proc.path.segments[proc.path.segments.len - 1];
                if (std.mem.eql(u8, proc_name, name)) {
                    return i;
                }
            }
        }
    }
    return null;
}

/// Generate a |fused variant of a proc (Phase 1: stub implementation)
fn generateFusedVariant(
    allocator: std.mem.Allocator,
    source: *const ast.Program,
    proc_index: usize,
    opportunity: *const fusion_detector.FusionOpportunity,
) !ast.Item {
    const original_proc = &source.items[proc_index].proc_decl;

    // Create new path with |fused variant
    var fused_segments = try allocator.alloc([]const u8, original_proc.path.segments.len);
    errdefer allocator.free(fused_segments);

    // Copy path segments, adding |fused to last segment
    for (original_proc.path.segments, 0..) |seg, i| {
        if (i == original_proc.path.segments.len - 1) {
            // Last segment gets |fused suffix
            fused_segments[i] = try std.fmt.allocPrint(allocator, "{s}|fused", .{seg});
        } else {
            fused_segments[i] = try allocator.dupe(u8, seg);
        }
    }

    const fused_path = ast.DottedPath{
        .module_qualifier = null, // Local proc, no module qualifier
        .segments = fused_segments,
    };

    // Phase 1: Generate stub body that calls original
    // This proves the mechanism works before we do actual fusion
    const original_name = original_proc.path.segments[original_proc.path.segments.len - 1];

    // Build fusion comment showing what's being fused
    var fusion_comment = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer fusion_comment.deinit(allocator);

    try fusion_comment.appendSlice(allocator, "    // FUSION STUB: Detected fusable chain: ");
    for (opportunity.chain, 0..) |event_name, idx| {
        if (idx > 0) try fusion_comment.appendSlice(allocator, " -> ");
        try fusion_comment.appendSlice(allocator, event_name);
    }
    try fusion_comment.appendSlice(allocator, "\n    // TODO: Inline the fused operations\n");
    try fusion_comment.appendSlice(allocator, "    // For now, just call original implementation\n");

    const stub_body = try std.fmt.allocPrint(
        allocator,
        \\{s}    return {s}_event.handler(e);
        \\
    ,
        .{ fusion_comment.items, original_name },
    );

    // Create new proc decl with provenance
    const fused_proc = ast.ProcDecl{
        .path = fused_path,
        .body = stub_body,
        .inline_flows = &.{}, // No flows in generated code (yet)
        .annotations = &[_][]const u8{}, // TODO: Copy from original?
        .target = null, // Always Zig for generated code
        .is_pure = original_proc.is_pure,
        .is_transitively_pure = original_proc.is_transitively_pure,

        // PROVENANCE TRACKING
        .derived_from = original_proc,
        .optimization_applied = try allocator.dupe(u8, "fusion"),

        .location = original_proc.location, // Same location as original
        .module = try allocator.dupe(u8, original_proc.module),
    };

    return ast.Item{ .proc_decl = fused_proc };
}
