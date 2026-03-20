const std = @import("std");
pub fn main() void {
    _ = std.posix.write(1, "Hello, World!\n") catch {};
}
