//! Freestanding wasm export layer for the browser playground. ZERO host imports
//! (no wasi, no fs, no process) — JS passes source bytes in, gets emitted JS or
//! diagnostics JSON out. This is the module a browser actually loads.
//!
//! Browser protocol:
//!   const p   = koru_alloc(srcLen);                  // input buffer ptr
//!   new Uint8Array(mem.buffer, p, srcLen).set(bytes);// write source
//!   const rp  = koru_compile_js(p, srcLen);          // result ptr (sets result_len)
//!   const out = decode(mem.buffer, rp, koru_result_len());
//!
//! koru_alloc resets the arena each call, so read a result BEFORE the next
//! koru_alloc. Single-threaded, single-shot — exactly the playground's usage.

const std = @import("std");
const pg = @import("playground");

var arena: ?std.heap.ArenaAllocator = null;
var result_len: usize = 0;

fn allocator() std.mem.Allocator {
    return arena.?.allocator();
}

/// Reset the arena (freeing the previous round) and hand back a fresh input
/// buffer for the browser to write `len` source bytes into.
export fn koru_alloc(len: usize) [*]u8 {
    if (arena) |*a| {
        _ = a.reset(.free_all);
    } else {
        arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    }
    const buf = allocator().alloc(u8, len) catch unreachable;
    return buf.ptr;
}

/// Compile source → JavaScript. Returns the result pointer; length via
/// koru_result_len(). On a compile error, returns an empty result (len 0) —
/// call koru_check for diagnostics.
export fn koru_compile_js(ptr: [*]const u8, len: usize) [*]const u8 {
    const out = pg.compileToJs(allocator(), ptr[0..len], "/playground.k") catch {
        result_len = 0;
        return "";
    };
    result_len = out.len;
    return out.ptr;
}

/// Run the diagnostics core → JSON array of diagnostics. Result ptr returned;
/// length via koru_result_len().
export fn koru_check(ptr: [*]const u8, len: usize) [*]const u8 {
    const out = pg.check(allocator(), ptr[0..len], "/playground.k") catch {
        result_len = 0;
        return "";
    };
    result_len = out.len;
    return out.ptr;
}

export fn koru_result_len() usize {
    return result_len;
}
