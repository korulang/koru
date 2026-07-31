const std = @import("std");
const ast = @import("ast");
const Parser = @import("parser").Parser;
const PurityChecker = @import("purity_checker.zig").PurityChecker;

/// Helper: Find a proc by name in the AST
fn findProc(source: *ast.Program, name: []const u8) ?*ast.ProcDecl {
    for (source.items) |*item| {
        if (item.* == .proc_decl) {
            const proc = @constCast(&item.proc_decl);
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
            const event = @constCast(&item.event_decl);
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
        \\~tor add { x: i32 }
        \\| done i32
        \\
        \\~[pure]proc add {
        \\    return .{ .done = x * 2 };
        \\}
    ;

    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
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
        \\~tor log { msg: string }
        \\| done {}
        \\
        \\~proc log {
        \\    std.debug.print("{s}", .{msg});
        \\    return .{ .done = .{} };
        \\}
    ;

    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
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

// ════════════════════════════════════════
// Phase 2: Call graph population (proc → inline-flow dispatches)
//
// The parser's inline-flow extraction is feature-gated off (KORU003 in
// extractInlineFlows), so no parseable program carries proc.inline_flows
// today. These tests graft a parsed flow into a proc to pin the mechanism:
// the call graph must be populated from inline flows, and a [pure] proc
// whose visible dispatches reach an impure event must NOT be marked
// transitively pure. This is the machinery the feature gate will land on.
// ════════════════════════════════════════

/// Helper: parse a program and graft its top-level flow into the named proc's
/// inline_flows. Uses an arena via the caller so shared ownership is safe.
fn graftFlowIntoProc(allocator: std.mem.Allocator, source_file: *ast.Program, proc_name: []const u8) !*ast.ProcDecl {
    const proc = findProc(source_file, proc_name) orelse return error.ProcNotFound;
    const flows = try allocator.alloc(ast.Flow, 1);
    var found = false;
    for (source_file.items) |*item| {
        if (item.* == .flow) {
            flows[0] = item.flow;
            found = true;
        }
    }
    if (!found) return error.FlowNotFound;
    proc.inline_flows = flows;
    return proc;
}

test "pure proc whose inline flow dispatches an impure event is not transitively pure" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const source =
        \\~tor log { msg: string }
        \\| done {}
        \\
        \\~proc log {
        \\    std.debug.print("{s}", .{msg});
        \\    return .{ .done = .{} };
        \\}
        \\
        \\~tor wrap { x: i32 } -> i32
        \\
        \\~[pure]proc wrap {
        \\    return x;
        \\}
        \\
        \\~log(msg: "side effect")
    ;

    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    var parse_result = try parser.parse();

    const wrap = try graftFlowIntoProc(allocator, &parse_result.source_file, "wrap");

    var checker = PurityChecker.init(allocator);
    try checker.check(&parse_result.source_file);

    // Locally pure by annotation — but its visible dispatch reaches the
    // impure log event, so transitive purity must be refused
    try std.testing.expect(wrap.is_pure == true);
    try std.testing.expect(wrap.is_transitively_pure == false);

    // And the event it implements must not aggregate to transitively pure
    const wrap_event = findEvent(&parse_result.source_file, "wrap") orelse return error.EventNotFound;
    try std.testing.expect(wrap_event.is_transitively_pure == false);
}

test "pure proc whose inline flow dispatches a pure event is transitively pure" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const source =
        \\~tor double { x: i32 } -> i32
        \\
        \\~[pure]proc double {
        \\    return x * 2;
        \\}
        \\
        \\~tor wrap { x: i32 } -> i32
        \\
        \\~[pure]proc wrap {
        \\    return x;
        \\}
        \\
        \\~double(x: 21)
    ;

    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    var parse_result = try parser.parse();

    const wrap = try graftFlowIntoProc(allocator, &parse_result.source_file, "wrap");

    var checker = PurityChecker.init(allocator);
    try checker.check(&parse_result.source_file);

    // The populated call graph must not refuse a genuinely pure chain
    try std.testing.expect(wrap.is_pure == true);
    try std.testing.expect(wrap.is_transitively_pure == true);
}

// ════════════════════════════════════════
// Phase 3: Fixed point recurses into modules
//
// Imported modules are merged as module_decl items before the purity pass
// runs (import_pipeline.combineImports), so a [pure] proc living inside a
// module must reach the same fixed point as a top-level one.
// ════════════════════════════════════════

test "module-level pure proc is marked transitively pure" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const source =
        \\~tor compute { x: i32 } -> i32
        \\
        \\~[pure]proc compute {
        \\    return x * 2;
        \\}
    ;

    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    const parse_result = try parser.parse();

    // Wrap the parsed items in a module, the shape combineImports produces
    const items = try allocator.alloc(ast.Item, 1);
    items[0] = .{ .module_decl = .{
        .logical_name = "m",
        .canonical_path = "m",
        .items = parse_result.source_file.items,
        .is_system = false,
    } };
    var program = ast.Program{ .items = items, .allocator = allocator };

    var checker = PurityChecker.init(allocator);
    try checker.check(&program);

    var module_proc: ?*ast.ProcDecl = null;
    var module_event: ?*ast.EventDecl = null;
    for (items[0].module_decl.items) |*item| {
        switch (item.*) {
            .proc_decl => |*p| module_proc = @constCast(p),
            .event_decl => |*e| module_event = @constCast(e),
            else => {},
        }
    }

    const proc = module_proc orelse return error.ProcNotFound;
    const event = module_event orelse return error.EventNotFound;
    try std.testing.expect(proc.is_pure == true);
    try std.testing.expect(proc.is_transitively_pure == true);
    try std.testing.expect(event.is_transitively_pure == true);
}

test "pure proc calling no events is transitively pure" {
    const allocator = std.testing.allocator;

    const source =
        \\~tor compute { x: i32 } -> i32
        \\
        \\~[pure]proc compute {
        \\    return x * 2;
        \\}
    ;

    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    // Run purity checker
    var checker = PurityChecker.init(allocator);
    defer checker.deinit();
    try checker.check(&parse_result.source_file);

    const proc = findProc(&parse_result.source_file, "compute") orelse return error.ProcNotFound;
    const event = findEvent(&parse_result.source_file, "compute") orelse return error.EventNotFound;

    // Proc should be marked transitively pure (calls nothing)
    try std.testing.expect(proc.is_pure == true);
    try std.testing.expect(proc.is_transitively_pure == true);

    // Event should be pure (only pure proc)
    try std.testing.expect(event.is_pure == true);
    try std.testing.expect(event.is_transitively_pure == true);
}
