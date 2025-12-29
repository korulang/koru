const std = @import("std");
const parser = @import("parser");
const ast = @import("ast");
const PurityAnalyzer = @import("purity_analyzer").PurityAnalyzer;
const EffectAnalyzer = @import("effect_analyzer").EffectAnalyzer;

test "compiler passes pipeline" {
    const allocator = std.testing.allocator;
    
    const source =
        \\// Pure event (annotated)
        \\~event[pure] math.calculate { value: i32 }
        \\| computed { result: i32 }
        \\
        \\// Event with effects
        \\~event[effects(io|network)] fetch.data { url: []const u8 }
        \\| fetched { data: []u8 }
        \\| error { msg: []const u8 }
        \\
        \\// Pure proc (syntactically)
        \\~proc pure_transform {
        \\    ~math.calculate(value: e.input)
        \\    | computed c |> success { output: c.result }
        \\}
        \\
        \\// Proc with effects (annotated)
        \\~proc[effects(io)] save_result {
        \\    const file = openFile("output.txt");
        \\    writeFile(file, e.data);
        \\    return .{ .saved = .{} };
        \\}
        \\
        \\// Proc marked pure but has effects (should warn!)
        \\~proc[pure|effects(network)] fetch_pure {
        \\    const data = http.get(e.url);
        \\    return .{ .data = data };
        \\}
        \\
        \\// Extern C function
        \\~event[extern_c] libc.malloc { size: usize }
        \\| raw { ptr: *anyopaque }
    ;
    
    // Parse the source
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    std.debug.print("\n=== COMPILER PASSES PIPELINE TEST ===\n", .{});
    
    // Pass 1: Purity Analysis
    std.debug.print("\n--- Pass 1: Purity Analysis ---\n", .{});
    var purity_analyzer = try PurityAnalyzer.init(allocator, &result.source_file);
    defer purity_analyzer.deinit();
    
    const purity_metadata = try purity_analyzer.analyze();
    defer purity_metadata.deinit(allocator);
    
    // Check purity results
    var purity_iter = purity_metadata.proc_purity.iterator();
    while (purity_iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;
        std.debug.print("  {s}: syntactic={}, annotated={}, final={}\n", .{
            name,
            info.syntactic_pure,
            info.annotated_pure,
            info.isPure(),
        });
    }
    
    // Pass 2: Effect Analysis (uses purity data)
    std.debug.print("\n--- Pass 2: Effect Analysis ---\n", .{});
    var effect_analyzer = EffectAnalyzer.init(allocator, &result.source_file, &purity_metadata);
    
    const effect_metadata = try effect_analyzer.analyze();
    defer effect_metadata.deinit(allocator);
    
    // Check effect results
    var effect_iter = effect_metadata.proc_effects.iterator();
    while (effect_iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const effects = entry.value_ptr.*;
        
        if (!effects.isEmpty()) {
            std.debug.print("  {s} has effects: ", .{name});
            inline for (std.meta.fields(@import("effect_analyzer").Effect)) |field| {
                const effect = @field(@import("effect_analyzer").Effect, field.name);
                if (effects.has(effect)) {
                    std.debug.print("{s} ", .{field.name});
                }
            }
            std.debug.print("\n", .{});
        }
    }
    
    // Pass 3: Backend Selection (mock)
    std.debug.print("\n--- Pass 3: Backend Selection ---\n", .{});
    var proc_iter = purity_metadata.proc_purity.iterator();
    while (proc_iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const purity_info = entry.value_ptr.*;
        const effects = effect_metadata.proc_effects.get(name) orelse continue;
        
        // Decide backend based on purity and effects
        if (purity_info.isPure() and effects.isEmpty()) {
            std.debug.print("  {s} -> Any backend (pure, no effects)\n", .{name});
        } else if (effects.has(.extern_c)) {
            std.debug.print("  {s} -> Native backend only (extern_c)\n", .{name});
        } else if (effects.has(.network)) {
            std.debug.print("  {s} -> Server backends only (network)\n", .{name});
        } else if (effects.has(.io)) {
            std.debug.print("  {s} -> Non-browser backends (io)\n", .{name});
        } else {
            std.debug.print("  {s} -> Zig backend (default)\n", .{name});
        }
    }
    
    std.debug.print("\n=== PIPELINE COMPLETE ===\n", .{});
    std.debug.print("Metadata flows through passes without modifying AST!\n", .{});
}

test "effect annotation parsing" {
    const allocator = std.testing.allocator;
    
    const source =
        \\// Complex effect annotations
        \\~proc[effects(io|network|memory)] complex_effects {
        \\    doStuff();
        \\}
        \\
        \\// Mixed annotations
        \\~proc[pure|async|effects(console)] mixed_annotations {
        \\    ~print(msg: "hello")
        \\    | done |> success {}
        \\}
        \\
        \\// Just extern_c implies effects
        \\~proc[extern_c] c_function {
        \\    return call_c();
        \\}
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    // Check annotations were parsed correctly
    for (result.source_file.items) |item| {
        switch (item) {
            .proc_decl => |proc| {
                std.debug.print("Proc annotations: [", .{});
                for (proc.annotations, 0..) |ann, i| {
                    if (i > 0) std.debug.print("|", .{});
                    std.debug.print("{s}", .{ann});
                }
                std.debug.print("]\n", .{});
            },
            else => {},
        }
    }
}