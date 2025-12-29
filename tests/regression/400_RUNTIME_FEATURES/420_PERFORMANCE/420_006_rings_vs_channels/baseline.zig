// Zig Baseline: Producer/Consumer with MPMC Ring
//
// Tests Vyukov's lock-free MPMC ring buffer:
// - MPMC ring (1024 capacity, lock-free atomics)
// - Threads (2 threads: producer + consumer)
// - Enqueue/dequeue (10M messages)
// - Synchronization (thread join)
// - Data integrity (checksum validation)
//
// MPMC ring vendored from beist-rings (https://github.com/...)
// Algorithm: Dmitry Vyukov's bounded MPMC queue

const std = @import("std");
const atomic = std.atomic;

const MESSAGES = 10_000_000;
const BUFFER_SIZE = 1024;

/// Vyukov's bounded MPMC ring buffer
fn MpmcRing(comptime T: type, comptime capacity: usize) type {
    if (capacity & (capacity - 1) != 0) {
        @compileError("Ring capacity must be power of 2");
    }

    const CacheLine = 64;

    const Slot = struct {
        seq: atomic.Value(usize),
        value: T,
    };

    return struct {
        const Self = @This();

        head: atomic.Value(usize) align(CacheLine),
        _pad1: [CacheLine - @sizeOf(atomic.Value(usize))]u8 = undefined,

        tail: atomic.Value(usize) align(CacheLine),
        _pad2: [CacheLine - @sizeOf(atomic.Value(usize))]u8 = undefined,

        slots: [capacity]Slot align(CacheLine),

        pub fn init() Self {
            var self = Self{
                .head = atomic.Value(usize).init(0),
                .tail = atomic.Value(usize).init(0),
                .slots = undefined,
            };

            for (&self.slots, 0..) |*slot, i| {
                slot.seq = atomic.Value(usize).init(i);
                slot.value = undefined;
            }

            return self;
        }

        pub fn tryEnqueue(self: *Self, value: T) bool {
            var pos = self.head.load(.monotonic);

            while (true) {
                const slot = &self.slots[pos & (capacity - 1)];
                const seq = slot.seq.load(.acquire);
                const dif = @as(isize, @intCast(seq)) -% @as(isize, @intCast(pos));

                if (dif == 0) {
                    if (self.head.cmpxchgWeak(
                        pos,
                        pos + 1,
                        .monotonic,
                        .monotonic,
                    ) == null) {
                        slot.value = value;
                        slot.seq.store(pos + 1, .release);
                        return true;
                    }
                    pos = self.head.load(.monotonic);
                } else if (dif < 0) {
                    return false;
                } else {
                    pos = self.head.load(.monotonic);
                    std.Thread.yield() catch {};
                }
            }
        }

        pub fn tryDequeue(self: *Self) ?T {
            var pos = self.tail.load(.monotonic);

            while (true) {
                const slot = &self.slots[pos & (capacity - 1)];
                const seq = slot.seq.load(.acquire);
                const dif = @as(isize, @intCast(seq)) -% @as(isize, @intCast(pos + 1));

                if (dif == 0) {
                    if (self.tail.cmpxchgWeak(
                        pos,
                        pos + 1,
                        .monotonic,
                        .monotonic,
                    ) == null) {
                        const value = slot.value;
                        slot.seq.store(pos + capacity, .release);
                        return value;
                    }
                    pos = self.tail.load(.monotonic);
                } else if (dif < 0) {
                    return null;
                } else {
                    pos = self.tail.load(.monotonic);
                    std.Thread.yield() catch {};
                }
            }
        }
    };
}

pub fn main() !void {
    var ring = MpmcRing(u64, BUFFER_SIZE).init();

    var sum: u64 = 0;

    // Producer thread
    const producer = try std.Thread.spawn(.{}, struct {
        fn run(r: *MpmcRing(u64, BUFFER_SIZE)) void {
            var i: u64 = 0;
            while (i < MESSAGES) : (i += 1) {
                while (!r.tryEnqueue(i)) {
                    std.Thread.yield() catch {};
                }
            }
        }
    }.run, .{&ring});

    // Consumer runs on MAIN THREAD (same as Koru!)
    var received: u64 = 0;
    while (received < MESSAGES) {
        if (ring.tryDequeue()) |value| {
            sum +%= value;
            received += 1;
        } else {
            std.Thread.yield() catch {};
        }
    }

    producer.join();

    // Validate checksum
    const expected: u64 = MESSAGES * (MESSAGES - 1) / 2;
    if (sum == expected) {
        std.debug.print("✓ Zig: Validated {} messages (checksum: {})\n", .{ MESSAGES, sum });
    } else {
        std.debug.print("✗ Zig: CHECKSUM MISMATCH! got {}, expected {}\n", .{ sum, expected });
    }
}
