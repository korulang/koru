pub const status = struct {
    pub const check = struct {
        pub const Input = struct {
        };
        pub const Output = union(enum) {
            @"ok": struct { },
            @"error": struct { code: i32 },
        };
    };
};
pub const db = struct {
    pub const lookup = struct {
        pub const Input = struct {
            id: i32,
        };
        pub const Output = union(enum) {
            @"success": struct { 
                name: []const u8,
                email: []const u8,
            },
            @"failure": struct { },
        };
        pub fn handler(e: Input) Output {
            if (e.id == 1) {
                return .{ .success = .{ .name = "Real User", .email = "real@example.com" } };
            }
            return .{ .failure = .{} };
        }
    };
};
pub const calc = struct {
    pub const add = struct {
        pub const Input = struct {
            a: i32,
            b: i32,
        };
        pub const Output = union(enum) {
            @"result": struct { sum: i32 },
        };
    };
};
pub const io = struct {
    pub const print = struct {
        pub const Input = struct {
            msg: []const u8,
        };
        pub const Output = void;
        pub fn handler(e: Input) Output {
            std.debug.print("{s}\n", .{e.msg});
        }
    };
};
pub const user = struct {
    pub const fetch = struct {
        pub const Input = struct {
            id: i32,
        };
        pub const Output = union(enum) {
            @"found": struct { 
                name: []const u8,
                email: []const u8,
            },
            @"not_found": struct { },
        };
    };
    pub const fetchComplex = struct {
        pub const Input = struct {
            id: i32,
        };
        pub const Output = union(enum) {
            @"found": struct { 
                name: []const u8,
                email: []const u8,
            },
            @"not_found": struct { },
        };
    };
};
// Test immediate return syntax for subflows
// Immediate returns are useful for constants, stubs, mocks, and prototyping
const std = @import("std");
// Define an event that we want to mock
// Traditional implementation with a flow
// Declare the db.lookup event
// IMMEDIATE RETURN SYNTAX - Just return a branch directly!
// Perfect for constants, stubs, testing, or any fixed response
// Test an event with parameters that returns fixed values
// Constant implementation that always returns 42
// Test empty branch
// Simple stub that always returns ok
// Declare print events for output
// Use the events with immediate returns - only one main flow allowed
// Proc for db.lookup (for the complex version)
const SubflowResult_calc_add = union(enum) {
    @"result": struct { sum: i32 },
};

const SubflowResult_status_check = union(enum) {
    @"ok": struct {  },
};

const SubflowResult_user_fetch = union(enum) {
    @"found": struct { name: []const u8, email: []const u8 },
};

const SubflowResult_user_fetchComplex = union(enum) {
    @"found": struct { name: []const u8, email: []const u8 },
    @"not_found": struct {  },
};

fn subflow_calc_add_impl(_: calc.add.Input) calc.add.Output {
    return .{ .result = .{ .sum = 42 } };
}

fn subflow_status_check_impl(_: status.check.Input) status.check.Output {
    return .{ .ok = .{ } };
}

fn subflow_user_fetch_impl(_: user.fetch.Input) user.fetch.Output {
    return .{ .found = .{ .name = "Test User",  .email = "test@example.com" } };
}

fn subflow_user_fetchComplex_impl(_: user.fetchComplex.Input) user.fetchComplex.Output {
    // TODO: Generate flow implementation
    return undefined;
}

pub fn main() void {
        subflow_user_fetch_impl(123);
}
