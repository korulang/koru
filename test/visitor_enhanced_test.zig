const std = @import("std");
const parser = @import("parser");
const ast = @import("ast");
const visitor = @import("ast_visitor_enhanced");
const PurityAnalyzer = @import("purity_analyzer").PurityAnalyzer;
const EffectAnalyzer = @import("effect_analyzer").EffectAnalyzer;
const MetadataAggregator = @import("metadata_aggregator").MetadataAggregator;

test "enhanced visitor framework" {
    const allocator = std.testing.allocator;
    
    const source =
        \\// Test various AST nodes
        \\~event math.add { a: i32, b: i32 }
        \\| sum { result: i32 }
        \\
        \\~proc calculator {
        \\    ~math.add(a: 1, b: 2)
        \\    | sum s |> { .result = s.result }
        \\}
        \\
        \\~flow compute =
        \\    math.add(a: 10, b: 20)
        \\    | sum s |> done { value: s.result }
        \\
        \\~tap math.add => {
        \\    console.log("Adding: " ++ a ++ " + " ++ b)
        \\}
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    std.debug.print("\n=== ENHANCED VISITOR TEST ===\n", .{});
    
    // Create a counting visitor to test the framework
    var counter = visitor.ExampleCountingVisitor.init(allocator);
    const counter_visitor = visitor.makeVisitor(
        visitor.ExampleCountingVisitor,
        visitor.VisitorContext(void),
        &counter
    );
    
    var walker = try visitor.Walker(void).init(allocator, {}, counter_visitor);
    defer walker.deinit();
    
    try walker.walk(&result.source_file);
    
    std.debug.print("Counted nodes:\n", .{});
    std.debug.print("  Events: {}\n", .{counter.event_count});
    std.debug.print("  Procs: {}\n", .{counter.proc_count});
    std.debug.print("  Flows: {}\n", .{counter.flow_count});
    std.debug.print("  Taps: {}\n", .{counter.tap_count});
    
    try std.testing.expect(counter.event_count == 1);
    try std.testing.expect(counter.proc_count == 1);
    try std.testing.expect(counter.flow_count == 2); // 1 standalone + 1 inline
    try std.testing.expect(counter.tap_count == 1);
}

test "metadata aggregation" {
    const allocator = std.testing.allocator;
    
    const source =
        \\// Pure event
        \\~event[pure] math.square { n: i32 }
        \\| squared { result: i32 }
        \\
        \\// Event with effects
        \\~event[effects(io|network)] api.fetch { url: []const u8 }
        \\| data { body: []u8 }
        \\
        \\// Pure proc (syntactically)
        \\~proc pure_calc {
        \\    ~math.square(n: 5)
        \\    | squared s |> { .result = s.result * 2 }
        \\}
        \\
        \\// Proc with effects
        \\~proc[effects(io|console)] logger {
        \\    const file = openFile("log.txt");
        \\    writeFile(file, e.message);
        \\    console.log("Logged: " ++ e.message);
        \\}
        \\
        \\// Mixed annotations
        \\~proc[pure|async|effects(memory)] allocator {
        \\    const buf = allocate(1024);
        \\    return .{ .buffer = buf };
        \\}
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    std.debug.print("\n=== METADATA AGGREGATION TEST ===\n", .{});
    
    // Run purity analysis
    var purity_analyzer = try PurityAnalyzer.init(allocator, &result.source_file);
    defer purity_analyzer.deinit();
    const purity_metadata = try purity_analyzer.analyze();
    defer purity_metadata.deinit(allocator);
    
    // Run effect analysis
    var effect_analyzer = EffectAnalyzer.init(allocator, &result.source_file, &purity_metadata);
    const effect_metadata = try effect_analyzer.analyze();
    defer effect_metadata.deinit(allocator);
    
    // Aggregate metadata
    var aggregator = MetadataAggregator.init(allocator);
    defer aggregator.deinit();
    
    try aggregator.addPurityMetadata(&purity_metadata);
    try aggregator.addEffectMetadata(&effect_metadata);
    
    // Test queries
    std.debug.print("\nQuerying aggregated metadata:\n", .{});
    
    // Check purity
    try std.testing.expect(aggregator.isPure("math.square"));
    try std.testing.expect(aggregator.isPure("pure_calc"));
    try std.testing.expect(!aggregator.isPure("logger"));
    
    // Check effects
    if (aggregator.getEffects("api.fetch")) |effects| {
        std.debug.print("api.fetch effects: ", .{});
        for (effects) |effect| {
            std.debug.print("{s} ", .{@tagName(effect)});
        }
        std.debug.print("\n", .{});
    }
    
    // Check backend compatibility
    try std.testing.expect(aggregator.canCompileToBackend("math.square", .browser));
    try std.testing.expect(!aggregator.canCompileToBackend("logger", .browser)); // Has io effect
    
    // Generate report
    var report_buffer = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer report_buffer.deinit();
    
    try aggregator.generateReport(report_buffer.writer());
    std.debug.print("\n{s}\n", .{report_buffer.items});
}

// Custom visitor for collecting specific information
const EffectCollectorVisitor = struct {
    allocator: std.mem.Allocator,
    procs_with_io: std.ArrayList([]const u8),
    pure_events: std.ArrayList([]const u8),
    
    pub fn init(allocator: std.mem.Allocator) !EffectCollectorVisitor {
        return .{
            .allocator = allocator,
            .procs_with_io = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .pure_events = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }
    
    pub fn deinit(self: *EffectCollectorVisitor) void {
        self.procs_with_io.deinit();
        self.pure_events.deinit();
    }
    
    pub fn visitProcDecl(self: *EffectCollectorVisitor, ctx: anytype, proc: *ast.ProcDecl) !void {
        _ = ctx;
        // Check if proc has io effect in annotations
        for (proc.annotations) |ann| {
            if (std.mem.indexOf(u8, ann, "io") != null) {
                const name = try pathToString(self.allocator, proc.path);
                try self.procs_with_io.append(name);
            }
        }
    }
    
    pub fn visitEventDecl(self: *EffectCollectorVisitor, ctx: anytype, event: *ast.EventDecl) !void {
        _ = ctx;
        // Check if event is marked pure
        for (event.annotations) |ann| {
            if (std.mem.eql(u8, ann, "pure")) {
                const name = try pathToString(self.allocator, event.path);
                try self.pure_events.append(name);
            }
        }
    }
    
    fn pathToString(allocator: std.mem.Allocator, path: ast.DottedPath) ![]const u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        defer buf.deinit();
        
        for (path.segments, 0..) |seg, i| {
            if (i > 0) try buf.append(buf.allocator, '.');
            try buf.appendSlice(buf.allocator, seg);
        }
        
        return try allocator.dupe(u8, buf.items);
    }
};

test "custom visitor implementation" {
    const allocator = std.testing.allocator;
    
    const source =
        \\~event[pure] calc.multiply { x: f64, y: f64 }
        \\| product { result: f64 }
        \\
        \\~proc[effects(io)] file_writer {
        \\    writeFile("output.txt", e.data);
        \\}
        \\
        \\~event[pure] calc.divide { x: f64, y: f64 }
        \\| quotient { result: f64 }
        \\| error { msg: []const u8 }
        \\
        \\~proc[effects(io|network)] uploader {
        \\    const data = readFile("input.txt");
        \\    http.post("/api/upload", data);
        \\}
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    std.debug.print("\n=== CUSTOM VISITOR TEST ===\n", .{});
    
    // Create custom visitor
    var collector = try EffectCollectorVisitor.init(allocator);
    defer collector.deinit();
    
    const collector_visitor = visitor.makeVisitor(
        EffectCollectorVisitor,
        visitor.VisitorContext(void),
        &collector
    );
    
    var walker = try visitor.Walker(void).init(allocator, {}, collector_visitor);
    defer walker.deinit();
    
    try walker.walk(&result.source_file);
    
    std.debug.print("Collected information:\n", .{});
    std.debug.print("  Pure events: ", .{});
    for (collector.pure_events.items) |name| {
        std.debug.print("{s} ", .{name});
        allocator.free(name);
    }
    std.debug.print("\n", .{});
    
    std.debug.print("  Procs with IO: ", .{});
    for (collector.procs_with_io.items) |name| {
        std.debug.print("{s} ", .{name});
        allocator.free(name);
    }
    std.debug.print("\n", .{});
    
    try std.testing.expect(collector.pure_events.items.len == 2);
    try std.testing.expect(collector.procs_with_io.items.len == 2);
}