pub const file = struct {
    pub const print = struct {
        pub const Input = struct {
            contents: []const u8,
        };
        pub const Output = union(enum) {
            @"success": struct { },
            @"failure": struct { errno: u8 },
        };
        pub fn handler(e: Input) Output {
            std.debug.print("PRINT: {s}\n", .{e.contents});
            return .{ .@"success" = .{} };
        }
    };
    pub const read = struct {
        pub const Input = struct {
            path: []const u8,
        };
        pub const Output = union(enum) {
            @"success": struct { contents: []const u8 },
            @"failure": struct { errno: u8 },
        };
        pub fn handler(_: Input) Output {
            // Simple test implementation - just return success with dummy data
            return .{ .@"success" = .{ .contents = "test file contents" } };
        }
    };
};
pub const proc = struct {
    pub const exit = struct {
        pub const Input = struct {
            errno: u8,
        };
        pub const Output = void;
        pub fn handler(e: Input) Output {
            std.process.exit(e.errno);
        }
    };
};
// Test basic subflow inlining
const std = @import("std");
// Void event - no branches
// Define a subflow that wraps file reading with error handling
// Use the subflow
// Proc implementations
pub fn main() void {
        const out0 = file.read.handler(.{ .path = "input.txt" });
    switch (out0) {
        .@"success" => |s| {
            const out1 = file.print.handler(.{ .contents = s.contents });
            switch (out1) {
                .@"success" => |_| {
                    _ = proc.exit.handler(.{ .errno = 0 });
                    return;
                },
                .@"failure" => |_| {
                    _ = proc.exit.handler(.{ .errno = 1 });
                    return;
                },
            }
        },
        .@"failure" => |f| {
            _ = proc.exit.handler(.{ .errno = f.errno });
            return;
        },
    }
}
