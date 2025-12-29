const std = @import("std");
const parser = @import("parser");
const ast = @import("ast");
const PurityAnalyzer = @import("purity_analyzer").PurityAnalyzer;

test "transitive purity analysis" {
    const allocator = std.testing.allocator;
    
    const source =
        \\// Pure event
        \\~event[pure] pure_transform { value: i32 }
        \\| transformed { result: i32 }
        \\
        \\// Impure event (no annotation)
        \\~event side_effect { data: []u8 }
        \\| done {}
        \\
        \\// Syntactically pure proc that calls pure event
        \\~proc should_be_transitively_pure {
        \\    ~pure_transform(value: e.input)
        \\    | transformed t |> success { output: t.result }
        \\}
        \\
        \\// Syntactically pure proc that calls IMPURE event  
        \\~proc should_not_be_transitively_pure {
        \\    ~side_effect(data: e.data)
        \\    | done |> complete {}
        \\}
        \\
        \\// Pure proc calling another pure proc
        \\~proc calls_pure_proc {
        \\    ~should_be_transitively_pure(input: e.value)
        \\    | success s |> final { result: s.output }
        \\}
        \\
        \\// Annotated pure despite having Zig code
        \\~proc[pure] manually_pure {
        \\    const hash = computeHash(e.data);
        \\    return .{ .hash = .{ .value = hash } };
        \\}
        \\
        \\// Calls manually pure proc
        \\~proc calls_manually_pure {
        \\    ~manually_pure(data: e.input)
        \\    | hash h |> result { h: h.value }
        \\}
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    // Run the GLORIOUS purity analyzer!
    var analyzer = try PurityAnalyzer.init(allocator, &result.source_file);
    defer analyzer.deinit();
    
    try analyzer.analyze();
    
    std.debug.print("\n=== FINAL PURITY RESULTS ===\n", .{});
    
    // Check the results
    for (result.source_file.items) |item| {
        switch (item) {
            .proc_decl => |proc| {
                const proc_name = try pathToString(allocator, proc.path);
                defer allocator.free(proc_name);
                
                // Check annotation
                var has_pure_annotation = false;
                for (proc.annotations) |ann| {
                    if (std.mem.eql(u8, ann, "pure")) {
                        has_pure_annotation = true;
                        break;
                    }
                }
                
                const is_transitively_pure = analyzer.visited.get(proc_name) orelse false;
                
                std.debug.print("'{s}': syntactic={}, annotated={}, transitive={}\n", .{
                    proc_name,
                    proc.is_pure,
                    has_pure_annotation, 
                    is_transitively_pure,
                });
                
                // Verify expectations
                if (std.mem.eql(u8, proc_name, "should_be_transitively_pure")) {
                    try std.testing.expect(is_transitively_pure == true);
                } else if (std.mem.eql(u8, proc_name, "should_not_be_transitively_pure")) {
                    try std.testing.expect(is_transitively_pure == false);
                } else if (std.mem.eql(u8, proc_name, "calls_pure_proc")) {
                    try std.testing.expect(is_transitively_pure == true);
                } else if (std.mem.eql(u8, proc_name, "manually_pure")) {
                    try std.testing.expect(is_transitively_pure == true); // Due to annotation
                } else if (std.mem.eql(u8, proc_name, "calls_manually_pure")) {
                    try std.testing.expect(is_transitively_pure == true);
                }
            },
            else => {},
        }
    }
}

test "cycle detection in purity analysis" {
    const allocator = std.testing.allocator;
    
    const source =
        \\// Mutual recursion - both should be pure!
        \\~proc ping {
        \\    ~pong(value: e.data)
        \\    | result r |> done { r }
        \\}
        \\
        \\~proc pong {
        \\    ~ping(data: e.value)
        \\    | done d |> result { d }
        \\}
        \\
        \\// Self recursion
        \\~proc recursive {
        \\    ~recursive(n: e.n - 1)
        \\    | result r |> result { value: r }
        \\}
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    var analyzer = try PurityAnalyzer.init(allocator, &result.source_file);
    defer analyzer.deinit();
    
    try analyzer.analyze();
    
    // All should handle cycles gracefully
    std.debug.print("\n=== CYCLE TEST RESULTS ===\n", .{});
    for (result.source_file.items) |item| {
        switch (item) {
            .proc_decl => |proc| {
                const proc_name = try pathToString(allocator, proc.path);
                defer allocator.free(proc_name);
                
                const is_transitively_pure = analyzer.visited.get(proc_name) orelse false;
                std.debug.print("'{s}': handles cycles, marked as pure = {}\n", .{
                    proc_name,
                    is_transitively_pure,
                });
                
                // Cycles are optimistically assumed pure
                try std.testing.expect(is_transitively_pure == true);
            },
            else => {},
        }
    }
}

fn pathToString(allocator: std.mem.Allocator, path: ast.DottedPath) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    for (path.segments, 0..) |seg, i| {
        if (i > 0) try buf.append('.');
        try buf.appendSlice(seg);
    }
    return buf.toOwnedSlice();
}