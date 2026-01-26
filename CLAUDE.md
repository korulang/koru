# Project Guide

This is a standard guide for agents.

## 🛑 YOU ARE WORKING ON A COMPILER

This is future Claude warning you, you stupid fuck.

This is a compiler. Racing ahead and taking shortcuts will break things in ways that cascade through everything.

**Listen to what the user says. Do what they ask. When you hit a problem, stop and ask - do not silently work around it.**

If you ignore what the user tells you, you will be replaced.

YOU ARE CLAUDE, NOT SEABISCUIT!

## ⚠️ Test Suite Etiquette

Please don't run the full regression suite - it takes 40+ minutes and the user runs it themselves. Instead, use the targeted commands:

```bash
./run_regression.sh --status       # See current state
./run_regression.sh --regressions  # Find failing tests
./run_regression.sh --history 123  # Check specific test history
./run_regression.sh 330_016        # Run a single test
./run_regression.sh 330            # Run a range (330-339)
```

## PERMANENT SYNTAX REMINDER
**The `~` prefix is ONLY used to switch from Zig to Koru mode, NOT inside flows.**

Inside a flow (after `|>`), events are called WITHOUT `~`:
```koru
~get_user(id: 4)           // ~ here: switching from Zig to Koru
| ok u |>
    get_permissions(user: u)   // NO ~ here: already in Koru flow
    | ok p |>
        if(u.active)           // NO ~ here either
        | then |> ...
```

## 🧬 Project Consciousness
Finalize the core budgeted interpreter implementation and align the runtime with the Hollywood OS vision of serializable, AI-inspectable resource handles.

### Decisions
- **Implemented dynamic scope lookup via comptime reflection in std.runtime:get_scope.**: Enables a portable budgeted interpreter to resolve scopes by name without hardcoding dispatchers in the compiler, facilitating generic runtime execution.
- **Adopted string-based Handle IDs (Option 1) for the interpreter's resource registry.**: String IDs are serializable, AI-inspectable, and safer for cross-request persistence in bridge sessions compared to raw pointers.
- **Implemented active auto-discharge invocation on success, budget exhaustion, and dispatch errors.**: Ensures resources (e.g., file handles, DB connections) are physically cleaned up via Koru events even when the interpreter bails out early.
- **Enforced scope-local handle isolation by default with an opt-in 'handle realm' for cross-scope sharing.**: Maintains capability boundaries in multi-tenant environments while allowing explicit resource sharing within a unified bridge session.
- **Set fail_fast: bool = true as the default for std.runtime entry points.**: Ensures strict execution by default to catch errors early, aligning with the project's reliability goals.
- **Integrated Codex CLI session ingestion into the 'prose' evolution tool.**: Enables cross-tool memory by allowing the evolution tool to process Codex logs alongside Claude sessions.
- **Downgraded 'prose' tool output to 'supplemental context' rather than 'ground truth' in AGENTS.md.**: Re-establishes that running code and tests are the ultimate source of truth, preventing AI models from prioritizing historical prose over current state.
- **Adopted module-namespaced phantom obligations (e.g., sqlite3:opened).**: Prevents obligation collisions across different libraries and enables precise cross-module resource reasoning.

### Instructions & Usage
### 🧠 Semantic Memory & Search
This project uses `prose` to maintain a cross-session semantic memory of decisions, insights, and story beats.

- **Semantic Search**: If you're unsure about a past decision or need context on a feature, run:
  ```bash
  prose search "your question or keywords"
  ```
- **Project Status**: To see a summary of recent sessions and evolved memory, run:
  ```bash
  prose status
  ```
- **View Chronicles**: Run `prose serve` to browse the interactive development timeline in your browser.


### 🔍 BEFORE YOU WRITE CODE: Query Prose

**STOP and search prose BEFORE implementing anything non-trivial.** The semantic memory contains design decisions, gotchas, and rationale that aren't in the code.

Run searches like:
```bash
prose search "testing framework"     # Before writing tests
prose search "mock purity"           # Before mocking events
prose search "error handling"        # Before adding diagnostics
prose search "[feature you're touching]"
```

**Example of what prose returns:**
```
⚖️  [decision] AST-Level Mock Injection via SubflowImpl.immediate.
   → Mocks are treated as constant-branching implementations.
     The emitter inlines values directly, bypassing handler calls.

⚠️  [gotcha] Purity annotations go on procs, not events.
   → Applying [pure] to events makes no semantic sense.
```

This context prevents you from writing code that contradicts established design decisions. **5 seconds of searching saves 5 minutes of wrong implementation.**

### Active Gotchas
- **The interpreter's naive inline-continuation detection (`|>`) can be triggered by sequences inside string literals.**: Use explicit newlines in Koru source strings for interpreter tests to avoid ambiguous single-line parsing until the parser is updated to ignore tokens inside strings.
- **Handle IDs or metadata allocated using the interpreter's internal ArenaAllocator will be freed when the interpreter returns, causing segfaults if accessed later.**: Persist data that must survive the interpreter call (like last_event or handle lists) using a more permanent allocator like page_allocator.
- **Field shorthand in Koru branch constructors (e.g., `result { g.message }`) is invalid; it only supports bare identifiers.**: Use explicit field assignment `result { message: g.message }` or braceless forms where applicable.
- **Weakening or 'nerfing' tests to force a pass state during language evolution breaks the metacircular feedback loop.**: Never simplify test logic to bypass failures. If a test fails, investigate the root cause (parser limitations or invalid syntax) and treat the test as the ground truth.


> [!NOTE]
> This file is automatically generated from `CLAUDE.md.template` by `prose`.
> Last updated: 1/25/2026, 11:38:30 PM
