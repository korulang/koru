pub const main_module = struct {
    // Tour 01: Dynamic Hello World
    // This version shows how to concatenate strings dynamically using an allocator
    const std = @import("std");
    // Event that takes an allocator for dynamic string operations
    pub const greet_dynamic_event = struct {
        pub const Input = struct {
            name: []const u8,
            allocator: std.mem.Allocator,
        };
        pub const Output = union(enum) {
            welcomed: struct {
                message: []const u8,
            },
            @"error": struct {
                msg: []const u8,
            },
        };
        pub fn handler(__koru_event_input: Input) Output {
            // >>> PROC: greet_dynamic
            const name = __koru_event_input.name;
            const allocator = __koru_event_input.allocator;
            _ = &name;
            _ = &allocator;
            _ = &__koru_event_input;

                // Use the provided allocator to create a dynamic string
                const message = std.fmt.allocPrint(e.allocator, "Hello, {s}!", .{e.name}) catch |err| {
                    // If allocation fails, return an error branch
                    return .{ .@"error" = .{ .msg = "Failed to allocate greeting" }};
                };
    
                return .{ .welcomed = .{ .message = message }};

        }
    };
    // Proc that creates a dynamic greeting
    // Note: In a real program, you'd call this with an actual allocator:
    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // const allocator = gpa.allocator();
    // ~greet_dynamic(name: "World", allocator: allocator)
    // | welcomed w |> ... // Use w.message
    // | error e |> ... // Handle error
    pub fn koru_start_flow() void {
        const result_0 = koru_koru.start_event.handler(.{  });
        const result_0_done = result_0.done;
        _ = &result_0_done;
    }
    pub fn koru_end_flow() void {
        const result_0 = koru_koru.end_event.handler(.{  });
        const result_0_done = result_0.done;
        _ = &result_0_done;
    }
};

pub const koru_std = struct {
    // Koru Standard Library: Root
    // Auto-imported when any $std/* module is imported
    // Transitively imports control to make keywords (like ~if, ~for) available
};
pub const koru_koru = struct {
    pub const start_event = struct {
        pub const Input = struct {
        };
        pub const Output = union(enum) {
            done: struct {
            },
        };
        pub fn handler(__koru_event_input: Input) Output {
            _ = &__koru_event_input;
            return .{ .done = .{} };
        }
    };
    pub const end_event = struct {
        pub const Input = struct {
        };
        pub const Output = union(enum) {
            done: struct {
            },
        };
        pub fn handler(__koru_event_input: Input) Output {
            _ = &__koru_event_input;
            return .{ .done = .{} };
        }
    };
};
pub fn main() void {
    main_module.koru_start_flow();
    main_module.koru_end_flow();
}
