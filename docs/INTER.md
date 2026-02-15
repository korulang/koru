# INTER: The Interactive Koru Compiler

**Vision Document** - This captures where we're going, not where we are.

## The Big Idea

```bash
koruc --inter myapp.kz
```

A TUI opens. The compiler becomes your development environment.

## Why This Isn't Crazy

Every piece already exists:

| Component | Status | Purpose |
|-----------|--------|---------|
| Event-driven architecture | ✅ | Everything is an observable transition |
| Immutable AST cloning | ✅ | Transform without destroying original |
| Universal taps (`~tap(* -> *)`) | ✅ | Observe every transition |
| Budgeted interpreter | ✅ | Safe, metered execution |
| Scope system | ✅ | Register capabilities, sandbox execution |
| HandlePool/Bridge | ✅ | State persists across calls |
| Compiler pipeline as events | ✅ | User-overridable passes |
| Testing framework | ✅ | Mock injection, purity tracking |
| Profile metatype | ✅ | Timing data built-in |
| `koru:start`/`koru:end` | ✅ | Program lifecycle events |

## The REPL

Instrument the whole program with taps. Add everything to a scope. Full REPL.

```
koru> ~app:withdraw(amount: 100)

TRACE: app:withdraw
  → account:balance | amount 50
  → withdraw | insufficient_funds

Result: .insufficient_funds

koru> ~account.balance = amount 1000   // Live mock injection

koru> ~app:withdraw(amount: 100)

TRACE: app:withdraw
  → account:balance | amount 1000  [MOCKED]
  → withdraw | success { remaining: 900 }

Result: .success { remaining: 900 }
```

## The TUI

```
┌─────────────────────────────────────────────────────────────────┐
│ KORU COMPILER - Interactive Mode                    [--inter]   │
├──────────────────────────────────┬──────────────────────────────┤
│ Pipeline                         │ AST Inspector                │
│ ✓ context_create                 │ ~event greet { name: str }   │
│ ✓ frontend                       │ | greeting { msg: str }      │
│ ▶ transform_taps ←               │                              │
│ ○ transform_user                 │ [Diff: +2 nodes, -0 nodes]   │
│ ○ backend                        │                              │
├──────────────────────────────────┼──────────────────────────────┤
│ AI Assistant                     │ Source: greet.kz             │
│                                  │                              │
│ You: Why did the tap wrap line   │  1│ ~event greet { ... }     │
│      42 but not line 45?         │  2│ | greeting { ... }       │
│                                  │  3│                          │
│ AI: Line 42 matches pattern      │  4│ ~tap(greet -> *)         │
│     `greet -> *` but line 45     │  5│ | greeting |> log(...)   │
│     is a void event with no...   │                              │
└──────────────────────────────────┴──────────────────────────────┘
```

### Key Features

- **Watch passes execute** - See each compiler phase in real-time
- **Inspect AST at any stage** - c0, c1, c2... all available (immutable cloning!)
- **Diff between passes** - See exactly what each transform changed
- **Pause and explore** - Step through compilation interactively
- **AI chat with full context** - Discuss the AST, get explanations

## The Koru Interpreter as THE AI Tool

This is the insight: **the Koru interpreter IS the AI tool interface**.

### Why One Tool is Enough

Traditional AI tool systems give the AI a bag of functions. The AI has to figure out:
- What tools exist?
- What order to call them?
- What constraints apply?
- How do results connect?

Koru solves all of this:

```koru
~pub event fs:open { path: []const u8 }
| handle []const u8[opened!]           // ← Phantom: creates obligation

~pub event fs:close { h: []const u8[!opened] }  // ← Must discharge!
| closed {}

~pub event fs:read { h: []const u8[opened] }    // ← Requires opened state
| data { content: []const u8 }
| eof {}
```

**Event signatures are self-documenting.** The AI reads the types.

**Phantom obligations are constraints.** `[opened!]` means "this creates an obligation". `[!opened]` means "this discharges it". The AI knows EXACTLY what must happen.

**Progressive disclosure.** The AI only sees events in scope. Register capabilities explicitly:

```koru
~std.runtime:register(scope: "file_ops") {
    fs:open(10)    // 10 budget units
    fs:close(1)
    fs:read(5)
}
```

**Budgeted execution.** The AI can't run forever. Budget exhaustion triggers auto-discharge of obligations.

### The AI Interaction Model

```
AI receives: scope "file_ops" with events:
  - fs:open { path: str } → handle str[opened!]
  - fs:close { h: str[!opened] } → closed
  - fs:read { h: str[opened] } → data | eof

AI understands:
  1. open creates obligation (must close)
  2. read requires opened state
  3. close discharges obligation

AI generates:
  ~fs:open(path: "/data.txt")
  | handle h |>
      fs:read(h: h)
      | data d |> process(d.content)
          |> fs:close(h: h)
              | closed |> done {}
      | eof |> fs:close(h: h)
          | closed |> done {}
```

The phantom types GUIDE the AI to correct code. No special prompting needed.

## Test Development in INTER

```
┌─────────────────────────────────────────────────────────────────┐
│ KORU - Test Development Mode                                    │
├──────────────────────────────────┬──────────────────────────────┤
│ Flow Trace                       │ Test Editor                  │
│                                  │                              │
│ ~app:withdraw(amount: 100)       │ ~test(overdraft blocked) {   │
│   ├─ calls: account.balance ⚠️   │   ~account.balance = 50      │
│   │   └─ IMPURE - needs mock!    │   ~app:withdraw(100)         │
│   └─ returns: insufficient_funds │   | insufficient_funds |>    │
│                                  │     assert.ok()              │
├──────────────────────────────────┤ }                            │
│ AI: "account.balance is impure.  ├──────────────────────────────┤
│      Suggested mock:             │ [R]un  [M]ock  [A]I help    │
│      ~account.balance = 50"      │                              │
└──────────────────────────────────┴──────────────────────────────┘
```

The compiler traces flows. Finds impure events. AI suggests mocks. You iterate live.

## Style Cop

The compiler has access to:
- The original Koru source (via source tracking in AST)
- The transformed AST at each stage
- All the semantic information (purity, phantoms, types)

So it can:
- **Lint** - Check style rules
- **Format** - Rewrite source files
- **Refactor** - Rename events, extract flows
- **All from inside the compiler**

## Implementation Path

### Phase 1: Source Tracking
Add Koru source text to AST nodes (like `host_lines` for Zig).

### Phase 2: TUI Scaffold
Integrate Vaxis (Zig TUI library). Basic panels for pipeline, AST, source.

### Phase 3: REPL
- Instrument program with universal tap
- Register all events in a scope
- Interactive event invocation with tracing

### Phase 4: AI Integration
- Tool calls via budgeted interpreter
- Context includes AST, source, trace history
- AI suggests mocks, fixes, refactors

### Phase 5: Write-back
- Style cop writes formatted code back to source files
- AI-suggested changes applied with confirmation

## Why This Matters

The compiler isn't just a compiler. It's:
- A **debugger** (trace every transition)
- An **IDE** (edit, test, refactor)
- An **AI interface** (progressive disclosure, phantom constraints)
- A **runtime** (budgeted interpreter)

All in one. All event-driven. All observable.

```
This is us, Claude.
```

---

*Vision captured: January 2026*
*Status: Dreaming, but the foundation is real*
