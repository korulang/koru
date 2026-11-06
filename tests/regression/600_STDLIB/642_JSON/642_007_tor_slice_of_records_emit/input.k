// Pins the `-> []{ f: T, ... }` bare-return lowering: Output emits
// `[]const struct { ... }` with each field type lowered (string → []const
// u8), and std/json:emit closes every element object inside the array —
// the arr/opt pending-flush ordering fix. The proc returns a slice literal:
// record literals coerce element-wise to the anonymous Output element.

import std/io
import std/json

pub tor posts {} -> []{ id: i64, body: string, created_at: string, author: string, like_count: i64 }
proc posts|zig {
    return &.{
        .{ .id = 2, .body = "he said \"hi\"", .created_at = "2025-01-02T03:04:05Z", .author = "ada", .like_count = 3 },
        .{ .id = 1, .body = "x\ny", .created_at = "2024-12-31T23:59:59Z", .author = "cid", .like_count = 0 },
    };
}

posts(): ps
|> std/json:emit(value: { posts: ps }): out
|> std/io:print.ln("{{ out:s }}") |> std/json:emit.free(text: out)
