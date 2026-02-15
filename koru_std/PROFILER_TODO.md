# Chrome Tracing Profiler - Current Status & Future Work

## What Works Today ✅

The profiler in `$std/profiler` is a **working proof-of-concept** that demonstrates:

1. **Meta-events fire correctly**
   - `koru:start` fires at program startup
   - `koru:end` fires at program completion
   - Both can be tapped like any other event

2. **Universal taps work**
   - `~tap(* -> *)` captures ALL event transitions
   - Profile metatype receives source, destination, branch, and runtime timestamp
   - Taps are inlined at compile-time (zero runtime overhead when disabled)

3. **Chrome Tracing visualization**
   - Generates valid Chrome Tracing Format JSON
   - Complete events ("ph":"X") show as horizontal bars with duration
   - Duration calculated as time between consecutive events
   - Load `/tmp/koru_profile.json` in `chrome://tracing` to visualize

4. **Zero-cost when disabled**
   - Conditional import: `~[PROFILE]import "$std/profiler"`
   - Without `--PROFILE` flag, entire profiler dead-strips at compile time
   - No runtime cost in production builds

## Current Limitations ⚠️

### Thread Safety (CRITICAL)

**The profiler is NOT thread-safe.** It uses global mutable state:

```zig
var profile_file: ?std.fs.File = null;
var first_event: bool = true;
var previous_timestamp_ns: i128 = 0;
```

**Problem**: If multiple threads fire transitions concurrently, you'll get:
- Race conditions on `first_event` and `previous_timestamp_ns`
- Corrupted JSON output (interleaved writes)
- Incorrect duration calculations
- Potential crashes

**Impact**: Fine for single-threaded sequential programs. **Will break** if:
- You spawn threads with Zig's `std.Thread`
- Multiple flows run concurrently
- Any event handler spawns async work

### Hardcoded Single Process/Thread

```json
{"pid":0,"tid":0}
```

**Problem**: All events show as pid=0, tid=0 regardless of actual execution context.

**Impact**: Can't visualize:
- Multi-threaded execution patterns
- Thread interactions
- Concurrency bottlenecks

## Future Work 🚀

### Phase 1: Thread Safety (Required for Production)

Add mutex for safe concurrent access:

```zig
var profiler_mutex: std.Thread.Mutex = .{};
var profile_file: ?std.fs.File = null;
var first_event: bool = true;
var previous_timestamp_ns: i128 = 0;

~proc write_event {
    profiler_mutex.lock();
    defer profiler_mutex.unlock();

    // ... existing code ...
}
```

**Pros**: Simple, correct, works immediately
**Cons**: Serializes all profiler writes (contention on hot paths)

### Phase 2: Per-Thread Buffering (Zero Contention)

Give each thread its own buffer, merge at end:

```zig
const ThreadLocalBuffer = struct {
    events: std.ArrayList(TraceEvent),
    thread_id: usize,
};

threadlocal var thread_buffer: ThreadLocalBuffer = undefined;

~proc write_event {
    // Append to thread-local buffer (no locking!)
    thread_buffer.events.append(...);
}

~proc write_footer {
    // Collect all thread buffers, sort by timestamp, write merged output
}
```

**Pros**: Zero contention, scales to many threads
**Cons**: More complex, needs thread registration/cleanup

### Phase 3: Dynamic Process/Thread Tracking

Capture actual OS thread IDs:

```zig
const tid = std.Thread.getCurrentId();
```

Emit in JSON:
```json
{"pid":0,"tid":12345}
```

**Result**: Chrome Tracing shows separate tracks per thread, visualizing concurrency!

### Phase 4: Additional Features

- **Event filtering**: Profile only specific event patterns
- **Stack traces**: Capture call stacks at each transition
- **Custom categories**: Group events by domain (network, compute, I/O)
- **Metadata events**: Add process/thread names for better visualization
- **Binary format**: Switch to Perfetto's binary format for smaller files

## Testing Strategy

### Current Test (626_meta_events)

- ✅ Verifies meta-events fire
- ✅ Validates Chrome Tracing JSON structure
- ✅ Confirms all three events present
- ⚠️ Only tests single-threaded sequential execution

### Needed Tests

1. **Multi-threaded stress test**
   - Spawn 10 threads firing events concurrently
   - Should produce valid JSON (currently will fail!)
   - Validates thread safety fixes

2. **Duration accuracy test**
   - Events with known sleep() durations
   - Verify reported durations match expectations
   - Catch timestamp calculation bugs

3. **Large trace test**
   - 10,000+ events
   - Verify file writes don't corrupt
   - Test Chrome Tracing can load it

## Design Philosophy

This profiler embodies Koru's "let it fail loudly" principle:

- No fallbacks or silent degradation
- Current implementation works perfectly for its scope
- Clear documentation of limitations
- Thread issues will corrupt JSON visibly (not silently)
- When you need threads, you'll know immediately

**Better to have an honest toy than a dishonest "production" system.**

## Usage Example

```koru
// In your Koru program
~[PROFILE]import "$std/profiler"

~event process_data { items: []Item }
| done { results: []Result }

~proc process_data {
    // Your code here - profiler automatically captures this transition!
    return .{ .done = .{ .results = results } };
}
```

Compile with profiling:
```bash
koruc my_app.kz --PROFILE
./my_app
```

View in Chrome:
1. Open Chrome and navigate to `chrome://tracing`
2. Click "Load" button
3. Select `/tmp/koru_profile.json`
4. See beautiful timeline visualization!

## Conclusion

This is a **working, honest, educational proof-of-concept**. It:

- ✅ Proves meta-events work
- ✅ Proves universal taps work
- ✅ Proves compile-time conditional imports work
- ✅ Produces usable profiling output
- ⚠️ Documents its limitations clearly
- 🚀 Provides clear path to production-ready version

**Ship it in `$std` with pride, knowing exactly what it is and what it isn't.**

---

*Last updated: 2025-10-18*
*Status: Single-threaded proof-of-concept - works great, documented honestly*
