const std = @import("std");
const ast = @import("ast");
const Parser = @import("parser").Parser;
const PurityChecker = @import("purity_checker.zig").PurityChecker;

/// Helper: Find a proc by name in the AST
fn findProc(source: *ast.Program, name: []const u8) ?*ast.ProcDecl {
    for (source.items) |*item| {
        if (item.* == .proc_decl) {
            const proc = &item.proc_decl;
            // Match single-segment path
            if (proc.path.segments.len == 1 and
                std.mem.eql(u8, proc.path.segments[0], name)) {
                return proc;
            }
        }
    }
    return null;
}

/// Helper: Find an event by name in the AST
fn findEvent(source: *ast.Program, name: []const u8) ?*ast.EventDecl {
    for (source.items) |*item| {
        if (item.* == .event_decl) {
            const event = &item.event_decl;
            // Match single-segment path
            if (event.path.segments.len == 1 and
                std.mem.eql(u8, event.path.segments[0], name)) {
                return event;
            }
        }
    }
    return null;
}

// ════════════════════════════════════════
// Phase 1: Local Purity (Already implemented in parser)
// ════════════════════════════════════════

test "proc with pure annotation is marked pure" {
    const allocator = std.testing.allocator;

    const source =
        \\~event add { x: i32 }
        \\| done { result: i32 }
        \\
        \\~[pure]proc add {
        \\    return .{ .done = .{ .result = x * 2 } };
        \\}
    ;

    var parser = try Parser.init(allocator, source, "test.kz");
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    // Parser should have already marked this as pure
    const proc = findProc(&parse_result.source_file, "add") orelse return error.ProcNotFound;

    try std.testing.expect(proc.is_pure == true);
    try std.testing.expect(proc.is_transitively_pure == false); // Not yet analyzed
}

test "proc without pure annotation is not pure" {
    const allocator = std.testing.allocator;

    const source =
        \\~event log { msg: []const u8 }
        \\| done {}
        \\
        \\~proc log {
        \\    std.debug.print("{s}", .{msg});
        \\    return .{ .done = .{} };
        \\}
    ;

    var parser = try Parser.init(allocator, source, "test.kz");
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    const proc = findProc(&parse_result.source_file, "log") orelse return error.ProcNotFound;

    try std.testing.expect(proc.is_pure == false);
    try std.testing.expect(proc.is_transitively_pure == false);
}

// ════════════════════════════════════════
// Phase 3 & 4: Transitive Purity (Requires purity checker implementation)
// ════════════════════════════════════════

test "pure proc calling no events is transitively pure" {
    const allocator = std.testing.allocator;

    const source =
        \\~event double { x: i32 }
        \\| done { result: i32 }
        \\
        \\~[pure]proc double {
        \\    return .{ .done = .{ .result = x * 2 } };
        \\}
    ;

    var parser = try Parser.init(allocator, source, "test.kz");
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    // Run purity checker
    var checker = PurityChecker.init(allocator);
    defer checker.deinit();
    try checker.check(&parse_result.source_file);

    const proc = findProc(&parse_result.source_file, "double") orelse return error.ProcNotFound;
    const event = findEvent(&parse_result.source_file, "double") orelse return error.EventNotFound;

    // Proc should be marked transitively pure (calls nothing)
    try std.testing.expect(proc.is_pure == true);
    try std.testing.expect(proc.is_transitively_pure == true);

    // Event should be pure (only pure proc)
    try std.testing.expect(event.is_pure == true);
    try std.testing.expect(event.is_transitively_pure == true);
}
