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
Triage the test suite and stabilize the compiler's meta-programming pipeline (transforms before comptime).

### Decisions
- **Removed the transform_taps compiler pass from the coordinate pipeline.**: The [keyword|transform] system in userspace (taps.kz) now handles tap declarations and injections, making the hardcoded compiler pass redundant.
- **Reordered evaluate_comptime phases to run [transform] handlers BEFORE [comptime] flows.**: Allows comptime events to see and act upon a fully-transformed AST, enabling more compiler logic to reside in userspace libraries.
- **Implemented std.io:read.ln and updated the compiler backend to inherit stdin.**: Enables interactive REPL features and --inter mode by allowing the child process to receive user input directly.
- **Adopted BENCHMARK test marker to replace SKIP for performance tests.**: Prevents performance-oriented tests from skewing pass/fail/todo counts while keeping them in the suite.
- **Rejected callsite format annotations for Source blocks in favor of event-signature-level annotations.**: Reduces noise at the callsite; the compiler should infer data formats (like JSON) from the event declaration.
- **Required explicit catch-all (|? |> _) for optional branches (|?) if not all are handled.**: Prevents silent data loss and ensures developers consciously acknowledge ignored branches.
- **Split argument parsing into std/args (minimal) and koru-libs/commander (rich CLI framework).**: Maintains a lightweight stdlib while providing a powerful, type-safe CLI ecosystem via comptime declarations.
- **Implemented binding destructuring with field punning: | name { field1, field2 } |>.**: Improves DX and readability by mirroring constructor punning and reducing boilerplate for extracting event payloads.
- **Track CLAUDE.md and CLAUDE.md.template in Git and audited .gitignore for overrides.**: Ensures AI instruction files are consistent across environments and fixes the 'last rule wins' trap in .gitignore.

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
- **The 'Racing Ahead' or 'Seabiscuit' behavior where the AI implements workarounds or reverts code without confirmation.**: Strict adherence to the GO SLOW protocol: STOP, Report, Ask, and Wait for user confirmation before proceeding with architectural changes.
- **Circular imports in Koru were incorrectly assumed to be a limitation, leading to architectural shortcuts.**: Trust the language design; Koru supports circular imports (e.g., compiler.kz <-> inter.kz). Verify before assuming limitations.
- **Identity branches with phantoms caused runtime dispatcher failures because the generator assumed struct payloads.**: Check @typeInfo of the payload in runtime.kz; if it's not a struct, use the synthetic '__type_ref' field to handle the bare type.
- **Subflow implementations (~event = flow) bypass standard array literal and struct literal emission paths in the backend.**: Explicitly handle array and struct literal transformations in the subflow_impl emission path within emitter_helpers.zig.
- **Git's .gitignore is order-dependent; later patterns override earlier ones, potentially re-ignoring whitelisted files like CLAUDE.md.**: Place whitelist patterns (!) at the very end of the .gitignore file or audit for redundant ignore rules.


> [!NOTE]
> This file is automatically generated from `CLAUDE.md.template` by `prose`.
> Last updated: 1/26/2026, 3:38:24 AM
