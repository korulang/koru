const std = @import("std");
pub fn main() void {
    _ = std.posix.write(2, "Hello, World!\n") catch {};
}
