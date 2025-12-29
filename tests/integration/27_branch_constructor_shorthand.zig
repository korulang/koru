pub const copy = struct {
    pub const fields = struct {
        pub const Input = struct {
            source: []const u8,
            dest: []const u8,
        };
        pub const Output = union(enum) {
            @"copied": struct { 
                source: []const u8,
                dest: []const u8,
            },
        };
    };
};
pub const validate = struct {
    pub const data = struct {
        pub const Input = struct {
            input: []const u8,
        };
        pub const Output = union(enum) {
            @"valid": struct { 
                data: []const u8,
                metadata: []const u8,
            },
        };
    };
};
pub const process = struct {
    pub const order = struct {
        pub const Input = struct {
            order_id: i32,
            customer: []const u8,
            total: i32,
        };
        pub const Output = union(enum) {
            @"approved": struct { 
                id: i32,
                name: []const u8,
                amount: i32,
            },
            @"rejected": struct { reason: []const u8 },
        };
    };
};
pub const parse = struct {
    pub const result = struct {
        pub const Input = struct {
            text: []const u8,
        };
        pub const Output = union(enum) {
            @"parsed": struct { 
                value: []const u8,
                info: []const u8,
            },
        };
        pub fn handler(e: Input) Output {
            return .{ .parsed = .{
                .value = e.text,
                .info = "metadata"
            } };
        }
    };
};
pub const fetch = struct {
    pub const order = struct {
        pub const Input = struct {
            id: i32,
        };
        pub const Output = union(enum) {
            @"found": struct { 
                order_id: i32,
                customer: []const u8,
                total: i32,
            },
            @"not_found": struct { },
        };
        pub fn handler(e: Input) Output {
            if (e.id > 0) {
                return .{ .found = .{ 
                    .order_id = e.id,
                    .customer = "TestCustomer",
                    .total = 99
                } };
            }
            return .{ .not_found = .{} };
        }
    };
};
// Test branch constructor shorthand with field access expressions
const std = @import("std");
// Test shorthand with field accesses in branch constructors
// Test what field name is extracted
// Test that binding names work too
// Main test
// Proc implementations
const SubflowResult_validate_data = union(enum) {
    @"valid": struct { value: []const u8, metadata: []const u8 },
};

const SubflowResult_process_order = union(enum) {
    @"rejected": struct { reason: []const u8 },
    @"approved": struct { order_id: i32, customer: []const u8, total: i32 },
};

const SubflowResult_copy_fields = union(enum) {
    @"copied": struct { source: []const u8, dest: []const u8 },
};

fn subflow_validate_data_impl(_: validate.data.Input) validate.data.Output {
    // TODO: Generate flow implementation
    return undefined;
}

fn subflow_process_order_impl(_: process.order.Input) process.order.Output {
    // TODO: Generate flow implementation
    return undefined;
}

fn subflow_copy_fields_impl(_: copy.fields.Input) copy.fields.Output {
    // TODO: Generate flow implementation
    return undefined;
}

pub fn main() void {
        subflow_process_order_impl(42, "Alice", 100);
}
