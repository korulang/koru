pub const validate = struct {
    pub const item = struct {
        pub const Input = struct {
            name: []const u8,
        };
        pub const Output = union(enum) {
            @"valid": struct { item_name: []const u8 },
            @"invalid": struct { },
        };
        pub fn handler(e: Input) Output {
            if (std.mem.eql(u8, e.name, "")) {
                return .{ .invalid = .{} };
            }
            return .{ .valid = .{ .item_name = e.name } };
        }
    };
};
pub const transform = struct {
    pub const user = struct {
        pub const Input = struct {
            user_id: i32,
            user_name: []const u8,
            user_email: []const u8,
        };
        pub const Output = union(enum) {
            @"transformed": struct { 
                id: i32,
                name: []const u8,
                email: []const u8,
            },
        };
    };
};
pub const db = struct {
    pub const save = struct {
        pub const Input = struct {
            id: i32,
        };
        pub const Output = union(enum) {
            @"saved": struct { },
            @"error": struct { msg: []const u8 },
        };
        pub fn handler(e: Input) Output {
            if (e.id == 0) {
                return .{ .error = .{ .msg = "Invalid ID" } };
            }
            return .{ .saved = .{} };
        }
    };
};
pub const complete = struct {
    pub const task = struct {
        pub const Input = struct {
            task_id: i32,
        };
        pub const Output = union(enum) {
            @"done": struct { message: []const u8 },
            @"failed": struct { @"error": []const u8 },
        };
    };
};
pub const fetch = struct {
    pub const details = struct {
        pub const Input = struct {
            id: i32,
        };
        pub const Output = union(enum) {
            @"found": struct { 
                full_name: []const u8,
                address: []const u8,
            },
        };
        pub fn handler(_: Input) Output {
            return .{ .found = .{ 
                .full_name = "John Doe",
                .address = "123 Main St"
            } };
        }
    };
};
pub const process = struct {
    pub const item = struct {
        pub const Input = struct {
            item: []const u8,
            count: i32,
        };
        pub const Output = union(enum) {
            @"processed": struct { total: i32 },
        };
    };
};
pub const log = struct {
    pub const message = struct {
        pub const Input = struct {
            text: []const u8,
        };
        pub const Output = void;
    };
};
// Test subflow validation rules and edge cases
const std = @import("std");
// Test 1: Subflow must implement all event branches
// This implementation covers all branches - VALID
// Test 2: Input field shadowing is not allowed
// This would be an ERROR if we tried: | valid item |>
// because 'item' would shadow the input field 'item'
// Test 3: Shorthand in complex expressions
// Mix shorthand and explicit in same call
// Test 4: Void events (no branches) work too
// Main test flow
// Proc implementations
const SubflowResult_process_item = union(enum) {
    @"processed": struct { total: i32 },
};

const SubflowResult_transform_user = union(enum) {
    @"transformed": struct { id: i32, name: []const u8, email: []const u8 },
};

const SubflowResult_complete_task = union(enum) {
    @"done": struct { message: []const u8 },
    @"failed": struct { @"error": []const u8 },
};

fn subflow_process_item_impl(_: process.item.Input) process.item.Output {
    // TODO: Generate flow implementation
    return undefined;
}

fn subflow_log_message_impl(_: log.message.Input) log.message.Output {
    // TODO: Generate flow implementation
    return undefined;
}

fn subflow_transform_user_impl(_: transform.user.Input) transform.user.Output {
    // TODO: Generate flow implementation
    return undefined;
}

fn subflow_complete_task_impl(_: complete.task.Input) complete.task.Output {
    // TODO: Generate flow implementation
    return undefined;
}

pub fn main() void {
        subflow_complete_task_impl(42);
}
