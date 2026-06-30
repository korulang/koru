//! Poison allocator for hunting read-after-free in the frontend.
//!
//! Two modes, selected by env:
//!  - KORU_POISON=1 (default): LEAK mode — on free, fill with 0xAA and never
//!    return memory to the child. A read-after-free then reads 0xAA, which is
//!    invalid UTF-8 → surfaces as a serialize/JSON SyntaxError. Catches the
//!    `location.file`-dangle class (commit 1780e17e).
//!  - KORU_POISON=reuse: REUSE mode — on free, fill with a VALID-UTF-8 sentinel
//!    (0x5A = 'Z') and forward the free to the child so the block is reused.
//!    A read-after-free then reads 'Z' bytes (or another live allocation's
//!    content) — VALID UTF-8 but wrong. This is the variant that reproduces the
//!    "Unknown event 'ZZZ…'" symptom: a dangling event-name / module-qualifier
//!    string corrupted into printable garbage rather than 0xAA.
//!
//! Diagnostic only. Gated behind KORU_POISON so normal builds are unaffected.

const std = @import("std");

pub const PoisonAllocator = struct {
    child: std.mem.Allocator,
    fill: u8,
    reuse: bool,

    pub fn init(child: std.mem.Allocator) PoisonAllocator {
        // Default: leak mode, 0xAA.
        var fill: u8 = 0xAA;
        var reuse = false;
        if (std.process.getEnvVarOwned(std.heap.page_allocator, "KORU_POISON")) |val| {
            defer std.heap.page_allocator.free(val);
            if (std.mem.eql(u8, val, "reuse")) {
                fill = 0x5A; // 'Z' — valid UTF-8
                reuse = true;
            }
        } else |_| {}
        return .{ .child = child, .fill = fill, .reuse = reuse };
    }

    pub fn allocator(self: *PoisonAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        // Forbid in-place grow so a logical realloc always moves+poisons the old
        // buffer (catches stale pointers into a grown ArrayList's old storage).
        if (new_len > memory.len) return false;
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return null; // never remap in place — force alloc+copy+free
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        @memset(memory, self.fill);
        if (self.reuse) {
            // Return to child so the poisoned block is recycled into the next
            // allocation — a dangling read sees the sentinel or fresh content.
            self.child.rawFree(memory, alignment, ret_addr);
        }
        // else: LEAK — keep the 0xAA bytes intact forever.
    }
};
