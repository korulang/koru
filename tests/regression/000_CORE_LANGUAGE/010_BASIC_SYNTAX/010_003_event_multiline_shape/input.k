// Event input shape braces may open on the line after the event name.

event example.write
{
    value: i32,
    note: []const u8,
}
| success usize
| failure []const u8
