// Pins reserve-once capacity estimation end-to-end: an array of objects
// whose string fields exceed 64 bytes and carry every escape class forces
// the emitted pre-pass (element lens + per-element static + separators,
// the ?string arm's if/else bound) and the 16-byte vector escanner across
// word and tail boundaries. Output stays byte-identical to the unreserved
// writer.

import std/io
import std/json

pub tor docs {} -> []{ id: i64, body: string, note: ?string }
proc docs|zig {
    return &.{
        .{ .id = 7, .body = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\\\n\t\x01bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .note = "ok" },
        .{ .id = 3, .body = "cccccccccccccccccccccccccccccccccccccccc\"dddddddddddddddddddddddddddddddddddddddd", .note = null },
        // 15 bytes, quote on the last byte — the padded-tail vector check
        // must still flag it and the per-byte pass must escape it.
        .{ .id = 11, .body = "ABCDEFGHIJKLMN\"", .note = null },
        // 17 bytes, control char at index 16 — first tail byte is dirty.
        .{ .id = 12, .body = "eeeeeeeeeeeeeeee\x01", .note = null },
        // 40 control bytes — escapes expand ~6x past the v.len + 2 reserve.
        .{ .id = 13, .body = "\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01", .note = null },
    };
}

docs(): ds
|> std/json:emit(value: { docs: ds }): out
|> std/io:print.ln("{{ out:s }}") |> std/json:emit.free(text: out)
