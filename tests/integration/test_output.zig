pub const io = struct {
    pub const print_result = struct {
        pub const Input = struct {
            msg: []const u8,
        };
        pub const Output = void;
        pub fn handler(e: Input) Output {
            std.debug.print("Result: {s}\n", .{e.msg});
        }
    };
};
pub const math = struct {
    pub const calculate = struct {
        pub const Input = struct {
            x: i32,
        };
        pub const Output = union(enum) {
            @"positive": struct { value: i32 },
            @"negative": struct { value: i32 },
            @"zero": struct { },
        };
        pub fn handler(e: Input) Output {
            if (e.x > 0) {
                return .{ .@"positive" = .{ .value = e.x } };
            } else if (e.x < 0) {
                return .{ .@"negative" = .{ .value = e.x } };
            } else {
                return .{ .@"zero" = .{} };
            }
        }
    };
};
// Test simple subflow shape return
const std = @import("std");
// Subflow that returns a constructed shape
// Main flow uses the subflow's return value
// Proc implementations
const SubflowResult_check_number = union(enum) {
    @"failure": struct { message: []const u8 },
    @"success": struct { result: i32, message: []const u8 },
};

pub fn main() void {
        const out0 = math.calculate.handler(.{ .x = 5 });
    switch (out0) {
        .@"positive" => |p| {
            const out1 = SubflowResult_check_number{ .@"success" = .{ .result = p.value, .message = "positive" } };
            switch (out1) {
                .@"success" => |s| {
                    _ = io.print_result.handler(.{ .msg = s.message });
                    // Flow terminates here (_)
                    return;
                },
                .@"failure" => |f| {
                    _ = io.print_result.handler(.{ .msg = f.message });
                    // Flow terminates here (_)
                    return;
                },
            }
        },
        .@"negative" => |n| {
            const out1 = SubflowResult_check_number{ .@"success" = .{ .result = n.value, .message = "negative" } };
            switch (out1) {
                .@"success" => |s| {
                    _ = io.print_result.handler(.{ .msg = s.message });
                    // Flow terminates here (_)
                    return;
                },
                .@"failure" => |f| {
                    _ = io.print_result.handler(.{ .msg = f.message });
                    // Flow terminates here (_)
                    return;
                },
            }
        },
        .@"zero" => |_| {
            const out1 = SubflowResult_check_number{ .@"failure" = .{ .message = "was zero" } };
            switch (out1) {
                .@"success" => |s| {
                    _ = io.print_result.handler(.{ .msg = s.message });
                    // Flow terminates here (_)
                    return;
                },
                .@"failure" => |f| {
                    _ = io.print_result.handler(.{ .msg = f.message });
                    // Flow terminates here (_)
                    return;
                },
            }
        },
    }
}
