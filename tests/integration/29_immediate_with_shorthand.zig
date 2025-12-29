// Test immediate return syntax with shorthand
// Shows how immediate returns can be used for configuration, defaults, or testing
const std = @import("std");
// Define an event
// Immediate return with explicit values
// Could be used for default configuration or fixed business rules
// Test with variables from outer scope using shorthand
const fixed_id = 42;
const fixed_msg = "Always works!";
// Can we use variables? (This would need to be constants)
// For now, let's use literals
// Declare output event
// Use the mocked events - only one main flow allowed
const validate = struct {
    pub const Input = struct {
        id: i32,
        total: i32,
    };
    pub const Output = union(enum) {
        @"valid": struct { 
            order_id: i32,
            amount: i32,
            status: []const u8,
        },
        @"invalid": struct { reason: []const u8 },
    };
};
const simple = struct {
    pub const Input = struct {
        input: []const u8,
    };
    pub const Output = union(enum) {
        @"done": struct { 
            id: i32,
            message: []const u8,
        },
    };
};
const output = struct {
    pub const Input = struct {
        text: []const u8,
    };
    pub const Output = void;
    pub fn handler(e: Input) Output {
        std.debug.print("{s}\n", .{e.text});
    }
};
pub fn main() void {
    // Top-level flow 1
    {
                subflow_order_validate_impl(1, 50);
    }
}
const SubflowResult_order_validate = union(enum) {
    @"valid": struct { order_id: i32, amount: i32, status: []const u8 },
};

const SubflowResult_test_simple = union(enum) {
    @"done": struct { id: i32, message: []const u8 },
};

fn subflow_order_validate_impl(_: order.validate.Input) order.validate.Output {
    return .{ .valid = .{ .order_id = 999,  .amount = 100,  .status = "approved" } };
}

fn subflow_test_simple_impl(_: @"test".simple.Input) @"test".simple.Output {
    return .{ .done = .{ .id = 42,  .message = "Fixed response" } };
}

