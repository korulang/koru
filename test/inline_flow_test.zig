const std = @import("std");
const parser = @import("parser");
const ast = @import("ast");

test "inline flow extraction" {
    const allocator = std.testing.allocator;

    const source =
        \\// Test inline flow detection
        \\
        \\~proc with_inline_flow {
        \\    const x = prepare(e.data);
        \\    
        \\    ~validate(input: x)
        \\    | valid v |> process(v)
        \\    | invalid i |> error { msg: i }
        \\    
        \\    const y = finalize();
        \\}
        \\
        \\~proc pure_flow_proc {
        \\    ~validate(input: e.data)
        \\    | valid v |> transform(v)
        \\    | invalid i |> error { msg: i }
        \\}
    ;

    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();

    var result = try p.parse();
    defer result.deinit();

    // Check we parsed 2 procs
    var proc_count: usize = 0;
    for (result.source_file.items) |item| {
        switch (item) {
            .proc_decl => |proc| {
                proc_count += 1;
                
                if (std.mem.eql(u8, proc.path.segments[0], "with_inline_flow")) {
                    // This should be impure (has Zig code)
                    // Purity is now tracked in compiler passes, not in AST  
                // try std.testing.expect(proc.is_pure == false);
                    // Should have 1 inline flow
                    try std.testing.expect(proc.inline_flows.len == 1);
                    
                    const flow = proc.inline_flows[0];
                    try std.testing.expect(std.mem.eql(u8, flow.invocation.path.segments[0], "validate"));
                    try std.testing.expect(flow.continuations.len == 2);
                } else if (std.mem.eql(u8, proc.path.segments[0], "pure_flow_proc")) {
                    // This should be pure (only flows)
                    // Purity is now tracked in compiler passes, not in AST
                // try std.testing.expect(proc.is_pure == true);
                    // Should have 1 inline flow
                    try std.testing.expect(proc.inline_flows.len == 1);
                }
            },
            else => {},
        }
    }
    
    try std.testing.expect(proc_count == 2);
}

test "complex nested inline flow" {
    const allocator = std.testing.allocator;

    const source =
        \\~proc complex_flow {
        \\    const setup = init();
        \\    
        \\    ~process(data: setup)
        \\    | ready r |> stage_one(r)
        \\        | ok o |> stage_two(o)
        \\            | final f |> complete { result: f }
        \\        | err e |> handle_error(e)
        \\    | not_ready n |> wait(n)
        \\    
        \\    cleanup();
        \\}
    ;

    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();

    var result = try p.parse();
    defer result.deinit();

    // Find the proc
    for (result.source_file.items) |item| {
        switch (item) {
            .proc_decl => |proc| {
                std.debug.print("complex_flow: inline_flows={}\n", .{proc.inline_flows.len});
                std.debug.print("Body: {s}\n", .{proc.body});
                
                // Should be impure
                // Purity is now tracked in compiler passes, not in AST  
                // try std.testing.expect(proc.is_pure == false);
                // Should have 1 inline flow
                try std.testing.expect(proc.inline_flows.len == 1);
                
                const flow = proc.inline_flows[0];
                // Check it's the process flow
                try std.testing.expect(std.mem.eql(u8, flow.invocation.path.segments[0], "process"));
                // Should have 2 top-level continuations
                try std.testing.expect(flow.continuations.len == 2);
                
                // Check nested continuations exist
                const ready_cont = flow.continuations[0];
                try std.testing.expect(ready_cont.pipeline.len > 0);
            },
            else => {},
        }
    }
}

test "proc annotations" {
    const allocator = std.testing.allocator;

    const source =
        \\// Pure via annotation
        \\~proc[pure] math_calc {
        \\    const result = sqrt(e.value);
        \\    return result;
        \\}
        \\
        \\// Multiple annotations
        \\~proc[pure|async] fetch {
        \\    const data = await fetch(e.url);
        \\    return data;
        \\}
        \\
        \\// No annotation, syntactically pure
        \\~proc simple_pure {
        \\    ~transform(e.data)
        \\    | done d |> success { result: d }
        \\}
    ;

    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();

    var result = try p.parse();
    defer result.deinit();

    var proc_count: usize = 0;
    for (result.source_file.items) |item| {
        switch (item) {
            .proc_decl => |proc| {
                proc_count += 1;
                
                if (std.mem.eql(u8, proc.path.segments[0], "math_calc")) {
                    // Should have [pure] annotation
                    try std.testing.expect(proc.annotations.len == 1);
                    try std.testing.expect(std.mem.eql(u8, proc.annotations[0], "pure"));
                    // Should be marked pure due to annotation
                    // Purity is now tracked in compiler passes, not in AST
                // try std.testing.expect(proc.is_pure == true);
                } else if (std.mem.eql(u8, proc.path.segments[0], "fetch")) {
                    // Should have [pure|async] annotations
                    try std.testing.expect(proc.annotations.len == 2);
                    var has_pure = false;
                    var has_async = false;
                    for (proc.annotations) |ann| {
                        if (std.mem.eql(u8, ann, "pure")) has_pure = true;
                        if (std.mem.eql(u8, ann, "async")) has_async = true;
                    }
                    try std.testing.expect(has_pure);
                    try std.testing.expect(has_async);
                } else if (std.mem.eql(u8, proc.path.segments[0], "simple_pure")) {
                    // No annotations but syntactically pure
                    try std.testing.expect(proc.annotations.len == 0);
                    // Purity is now tracked in compiler passes, not in AST
                // try std.testing.expect(proc.is_pure == true);
                }
            },
            else => {},
        }
    }
    
    try std.testing.expect(proc_count == 3);
}

test "multiple inline flows in one proc" {
    const allocator = std.testing.allocator;

    const source =
        \\~proc multi_flow {
        \\    ~first_flow(data: e.input)
        \\    | ok o |> handle_ok(o)
        \\    
        \\    const middle = process();
        \\    
        \\    ~second_flow(value: middle)
        \\    | success s |> done(s)
        \\}
    ;

    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();

    var result = try p.parse();
    defer result.deinit();

    // Find the proc
    for (result.source_file.items) |item| {
        switch (item) {
            .proc_decl => |proc| {
                // Should be impure (has Zig code)
                // Purity is now tracked in compiler passes, not in AST  
                // try std.testing.expect(proc.is_pure == false);
                // Should have 2 inline flows
                try std.testing.expect(proc.inline_flows.len == 2);
                
                // Check first flow
                try std.testing.expect(std.mem.eql(u8, proc.inline_flows[0].invocation.path.segments[0], "first_flow"));
                // Check second flow
                try std.testing.expect(std.mem.eql(u8, proc.inline_flows[1].invocation.path.segments[0], "second_flow"));
            },
            else => {},
        }
    }
}