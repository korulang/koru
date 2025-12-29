pub const validate = struct {
    pub const input = struct {
        pub const Input = struct {
            value: u32,
        };
        pub const Output = union(enum) {
            @"valid": struct { value: u32 },
            @"invalid": struct { msg: []const u8 },
        };
        pub fn handler(e: Input) Output {
            if (e.value > 0 and e.value < 1000) {
                return .{ .@"valid" = .{ .value = e.value } };
            } else {
                return .{ .@"invalid" = .{ .msg = "Value out of range" } };
            }
        }
    };
};
pub const log = struct {
    pub const @"error" = struct {
        pub const Input = struct {
            code: u32,
            message: []const u8,
        };
        pub const Output = void;
        pub fn handler(e: Input) Output {
            std.debug.print("ERROR {}: {s}\n", .{ e.code, e.message });
        }
    };
    pub const info = struct {
        pub const Input = struct {
            msg: []const u8,
        };
        pub const Output = void;
        pub fn handler(e: Input) Output {
            std.debug.print("INFO: {s}\n", .{e.msg});
        }
    };
};
pub const process = struct {
    pub const value = struct {
        pub const Input = struct {
            data: u32,
        };
        pub const Output = union(enum) {
            @"done": struct { result: u32 },
            @"failed": struct { 
                error_code: u32,
                reason: []const u8,
            },
        };
        pub fn handler(e: Input) Output {
            if (e.data % 2 == 0) {
                return .{ .@"done" = .{ .result = e.data * 2 } };
            } else {
                return .{ .@"failed" = .{ .error_code = 500, .reason = "Odd numbers not supported" } };
            }
        }
    };
};
pub const transform = struct {
    pub const data = struct {
        pub const Input = struct {
            input: u32,
        };
        pub const Output = union(enum) {
            @"success": struct { 
                output: u32,
                status: []const u8,
            },
            @"error": struct { 
                code: u32,
                message: []const u8,
            },
        };
    };
};
// Test subflows implementing event interfaces with branch constructors
const std = @import("std");
// Define the interface
// Implement it with a subflow using branch constructors
// Helper events
// Test using the subflow
// Logging events
// Procs
pub fn main() void {
        const out0 = validate.input.handler(.{ .value = 42 });
    switch (out0) {
        .@"valid" => |v| {
            const out1 = process.value.handler(.{ .data = v.value });
            switch (out1) {
                .@"done" => |d| {
                    const out2 = .@"success"(.{ .output = d.result, .status = "completed" });
                },
                .@"failed" => |f| {
                    const out2 = .@"error"(.{ .code = f.error_code, .message = f.reason });
                },
            }
        },
        .@"invalid" => |i| {
            const out1 = .@"error"(.{ .code = 400, .message = i.msg });
        },
    }
}
