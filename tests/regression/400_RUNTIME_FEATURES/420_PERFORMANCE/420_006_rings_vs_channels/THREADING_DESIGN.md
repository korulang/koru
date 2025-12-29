# Threading Abstraction Design: FlowAST + Implicit Blocks

**Status:** Specified in parser tests 054-056, awaiting full implementation

**Goal:** Express threading in Koru using natural flow syntax, without raw Zig code

---

## The Problem

Currently, the rings benchmark has this awkward pattern:

```koru
~proc spawn_producer {
    // RAW ZIG CODE - not Koru!
    const producer = std.Thread.spawn(.{}, struct {
        fn run(r: *Ring) void {
            var i: u64 = 0;
            while (i < MESSAGES) : (i += 1) {
                while (!r.tryEnqueue(i)) {
                    std.Thread.yield() catch {};
                }
            }
        }
    }.run, .{ring}) catch unreachable;

    producer.detach();
    return .{ .spawned = .{} };
}
```

**Problems:**
- Producer logic is in an anonymous Zig struct, not Koru events
- Can't use Koru's event flow for threading
- Can't profile/tap thread code
- Breaks the "all code is events" abstraction

---

## The Solution: Implicit Flow Blocks

### Beautiful Syntax

**Basic usage:**
```koru
~std.threading:spawn {
    ~producer_loop(ring: r.ring, i: 0)
    | done |> _
}
| spawned t |> consumer_loop(ring: r.ring)
    | done |> std.threading:join(thread: t)
        | joined |> validate(...)
```

**With configuration parameters:**
```koru
~std.threading:spawn(priority: 3, stack_size: 8192) {
    ~producer_loop(ring: r.ring, i: 0)
    | done |> _
}
| spawned t |> ...
```

**Event signature:**
```koru
~event spawn { priority: u8, stack_size: usize, work: FlowAST }
| spawned { handle: ThreadHandle }
```

**Design principle:**
- **Parameters in `()`** = Configuration (priority, stack size, name, etc.)
- **Block in `{ }`** = Behavior (the flow to execute)

This visually separates "what to configure" from "what to do"!

**What happens:**
1. Named args in `(priority: 3, ...)` bind to explicit fields
2. The `{ flow }` block is **implicitly compiled to FlowAST** at compile-time
3. FlowAST binds to the `work: FlowAST` field
4. The `spawn` event receives both configuration and behavior
5. The `spawn` proc spawns a thread with the config and executes the FlowAST
6. Both producer (in thread) and consumer (in main) are Koru flows!

**More examples showing the pattern:**

```koru
// HTTP server with handler flow
~std.http:server(port: 8080, threads: 4) {
    ~handle_request(req: request)
    | response r |> send(r)
    | error e |> send_error(e)
}
| listening |> ...

// Scheduled task
~std.scheduler:every(interval: "5s") {
    ~cleanup_cache()
    | done |> log("Cache cleaned")
}
| scheduled |> ...

// Database transaction with retry
~std.db:transaction(isolation: "serializable", retries: 3) {
    ~query(sql: "UPDATE accounts SET balance = balance - 100")
    | updated |> query(sql: "UPDATE accounts SET balance = balance + 100")
        | updated |> commit()
}
| committed |> ...
| failed e |> rollback()
```

**The pattern is universal:**
- Configuration goes in `(...)`
- Behavior goes in `{ ... }`
- Both are type-checked
- Beautiful, composable syntax!

---

## How It Works

### 1. Parser Recognition

When the parser sees:
```koru
~event_name { flow_body }
```

It knows: "This `{ }` block should be compiled to FlowAST"

**Parser steps:**
1. Recognize `{ }` after event invocation
2. Parse the flow inside the block
3. Mark it as "implicit FlowAST parameter"
4. Continue parsing as normal

### 2. Compile-Time FlowAST Serialization

At **compile-time** (frontend or backend):

```koru
// What you write:
~std.threading:spawn {
    ~producer_loop(ring: r.ring, i: 0)
    | done |> _
}

// Gets compiled to (conceptually):
const work_flow = FlowAST{
    .items = &[_]Item{
        .{ .flow = Flow{
            .invocation = Invocation{ .path = "producer_loop", ... },
            .continuations = ...
        }},
    }
};
~std.threading:spawn(work: work_flow)
```

### 3. Event Signature

The `spawn` event accepts FlowAST:

```koru
~event spawn { work: FlowAST }
| spawned { handle: ThreadHandle }
```

**Key insight:** `FlowAST` is a FIRST-CLASS TYPE in Koru!

### 4. Runtime Execution

The `spawn` proc executes the FlowAST in a new thread:

```koru
~proc spawn {
    // Helper spawns thread and executes FlowAST
    const thread = spawn_thread_with_flow(work);
    return .{ .spawned = .{ .handle = thread } };
}
```

Where `spawn_thread_with_flow` is in `$std/threading`:

```koru
// Helper function (probably in Zig for now)
fn spawn_thread_with_flow(work: FlowAST) ThreadHandle {
    const thread = std.Thread.spawn(.{}, struct {
        fn run(flow: FlowAST) void {
            // Execute FlowAST in this thread
            execute_flow_ast(flow);
        }
    }.run, .{work}) catch unreachable;

    return thread.handle();
}
```

### 5. FlowAST Execution Loop

The execution loop interprets the FlowAST:

```koru
fn execute_flow_ast(flow: FlowAST) void {
    for (flow.items) |item| {
        switch (item) {
            .flow => |f| {
                // Call the event handler
                const result = call_handler(f.invocation);

                // Follow the matching continuation
                for (f.continuations) |cont| {
                    if (matches(result, cont.branch)) {
                        // Execute pipeline
                        for (cont.pipeline) |step| {
                            execute_step(step);
                        }
                        break;
                    }
                }
            },
            // ... other item types
        }
    }
}
```

---

## Variable Capture

Flows in `{ }` blocks can capture variables from outer scope:

```koru
~create_ring()
| created r |> std.threading:spawn {
    // 'r.ring' is captured from outer scope!
    ~producer_loop(ring: r.ring, i: 0)
    | done |> _
  }
  | spawned t |> ...
```

**Compiler detects captured variables:**
1. Parse the flow block
2. Find all variable references
3. Check which ones come from outer scope
4. Include them in FlowAST data structure
5. Make them available when FlowAST executes

This is like **closure capture**!

---

## Full Example: Rings Benchmark Rewritten

### Before (Raw Zig)

```koru
~proc spawn_producer {
    const producer = std.Thread.spawn(.{}, struct {
        fn run(r: *Ring) void {
            var i: u64 = 0;
            while (i < MESSAGES) : (i += 1) {
                while (!r.tryEnqueue(i)) {
                    std.Thread.yield() catch {};
                }
            }
        }
    }.run, .{ring}) catch unreachable;

    producer.detach();
    return .{ .spawned = .{} };
}
```

### After (Pure Koru)

```koru
// Producer event (pure Koru!)
~event producer_loop { ring: *Ring, i: u64 }
| continue { i: u64 }
| done {}

~proc producer_loop {
    if (i >= MESSAGES) {
        return .{ .done = .{} };
    }

    if (ring.tryEnqueue(i)) {
        return .{ .continue = .{ .i = i + 1 } };
    } else {
        std.Thread.yield() catch {};
        return .{ .continue = .{ .i = i } };
    }
}

// Main flow with beautiful threading
~create_ring()
| created r |> std.threading:spawn {
    // Producer runs in spawned thread
    #produce producer_loop(ring: r.ring, i: 0)
    | continue c |> @produce(ring: r.ring, i: c.i)
    | done |> _
  }
  | spawned t |> #consume consumer_loop(ring: r.ring, sum: 0)
      // Consumer runs in main thread
      | continue c |> @consume(ring: r.ring, sum: c.sum)
      | done d |> std.threading:join(thread: t)
          | joined |> validate(sum: d.sum)
```

**What we gained:**
- ✅ Producer is pure Koru events
- ✅ Can profile/tap producer code
- ✅ Natural flow syntax
- ✅ No raw Zig anonymous structs
- ✅ Variable capture works naturally

---

## Implementation Checklist

### Phase 1: Parser Support (Tests 054-056)

- [ ] Recognize `FlowAST` type in event signatures
- [ ] Set `is_flow_ast = true` flag on FlowAST fields
- [ ] Recognize `Source` type in event signatures
- [ ] Set `is_source = true` flag on Source fields
- [ ] Serialize flags to `--ast-json` output

### Phase 2: Implicit Flow Block Syntax

- [ ] Recognize `~event { flow }` syntax
- [ ] Parse flow block as FlowAST parameter
- [ ] Detect captured variables from outer scope
- [ ] Create FlowAST with captures

### Phase 3: Runtime Helpers

- [ ] Implement `execute_flow_ast(FlowAST)` interpreter
- [ ] Implement `spawn_thread_with_flow(FlowAST)` helper
- [ ] Thread handle management
- [ ] Variable capture mechanism

### Phase 4: Standard Library

- [ ] Create `$std/threading` module
- [ ] Implement `spawn` event
- [ ] Implement `join` event
- [ ] Implement `detach` event
- [ ] Thread-local storage helpers

### Phase 5: Optimization

- [ ] JIT-compile FlowAST to Zig code (avoid interpretation)
- [ ] Inline small flows
- [ ] Zero-cost threading abstraction

---

## Tests

- **054_flowast_parameter_syntax**: FlowAST type recognition
- **055_source_parameter_syntax**: Source type recognition
- **056_implicit_flow_block_syntax**: `{ flow }` block syntax
- **2004_rings_vs_channels**: Full threading benchmark

---

## Design Rationale

### Why FlowAST?

**Flow as data** enables:
- Threading (execute flow in new thread)
- Metaprogramming (transform flows at compile-time)
- Lazy evaluation (defer flow execution)
- RPC (serialize flow, send to remote)

**FlowAST is the KEY to metacircular Koru!**

### Why Implicit Blocks?

**Explicit FlowAST construction is verbose:**
```koru
const flow = FlowAST { ... explicit construction ... };
~spawn(work: flow)
```

**Implicit blocks are natural:**
```koru
~spawn { ~work() | done |> _ }
```

The compiler does the heavy lifting!

### Why Not Two-Branch Parallel Execution?

We considered:
```koru
~[parallel] event spawn { }
| thread |> ...  // Runs in spawned thread
| parent |> ...  // Runs in main thread
```

**Problems:**
- Breaks "one branch chosen" semantic
- No thread handle (can't join)
- Limited to spawn/fork pattern
- Can't pass flows to other events

**FlowAST is more general:**
- Flows are data (can be passed around)
- Threading is just one use case
- Same mechanism works for metaprogramming
- Preserves event semantics

---

## Future: Full Metacircularity

When the frontend is written in Koru, compiler passes will use FlowAST:

```koru
~[comptime] event optimize { ast: ProgramAST }
| optimized { ast: ProgramAST }

~proc optimize {
    // Transform AST
    for (ast.items) |item| {
        if (item == .flow) {
            // Execute optimization pass as FlowAST!
            const optimized_flow = run_optimizer_flow(item.flow);
            // Replace in AST
        }
    }
    return .{ .optimized = .{ .ast = ast } };
}
```

**Compiler passes are flows executing on FlowAST!** True metacircularity.

---

*Design Discussion: 2025-10-21*
*"Threading should be as beautiful as everything else in Koru."*
