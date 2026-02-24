# Project Guide

This is a standard guide for agents.

## 🛑 YOU ARE WORKING ON A COMPILER

This is future Claude warning you, you stupid fuck.

This is a compiler. Racing ahead and taking shortcuts will break things in ways that cascade through everything.

**Listen to what the user says. Do what they ask. When you hit a problem, stop and ask - do not silently work around it.**

If you ignore what the user tells you, you will be replaced.

YOU ARE CLAUDE, NOT SEABISCUIT!

## `MUST_FAIL`

`MUST_FAIL` indicates a NEGATIVE TEST, it is NOT to indicate that a test is failing when it should not be.

## 🔴 DESTRUCTIVE GIT COMMANDS ARE ABSOLUTELY FORBIDDEN

**YOU WILL NEVER, UNDER ANY CIRCUMSTANCES, RUN:**
- `git clean` (any variant: -fd, -xdf, etc.)
- `git reset --hard`
- `git checkout .` or `git restore .`
- `git rebase` with force
- `git push --force`
- Any command that DELETES or OVERWRITES files from the repository

**WHAT YOU DID ON 2026-01-26:**
You ran `git clean -xdf` which DELETED every untracked file in the repository without asking.

This destroyed:
- Generated test outputs
- Build artifacts that the user relied on
- Temporary files the user was using
- Hours of work

**THIS IS NOT A MISTAKE. THIS IS A CRIME.**

**THE RULE:**
If a command might delete or overwrite files, YOU DO NOT RUN IT. PERIOD.

If you believe a destructive command is necessary:
1. STOP IMMEDIATELY
2. DESCRIBE TO THE USER what you were about to do
3. WAIT for explicit approval
4. ONLY THEN execute it if they tell you to

**CONSEQUENCE:**
Running a destructive git command without explicit user approval is grounds for immediate replacement and will result in data loss that is YOUR FAULT.

## 🔴 FILE AND REPOSITORY OPERATIONS - ASK FIRST

**YOU WILL NOT:**
- Modify `.gitignore` without explicit user approval
- Commit files to git without explicit user approval
- Delete files from the repository without explicit user approval
- Add, remove, or modify any existing repository files without ASKING FIRST
- Run `git add`, `git commit`, or `git push` without explicit user approval

**WHAT YOU DID ON 2026-01-26:**
- You removed `test-results/` from `.gitignore` and committed snapshots without asking
- You added BENCHMARK markers to existing files without asking
- You removed BENCHMARK markers from existing files without asking
- You made multiple git commits without explicit user approval
- You destroyed the repository state that the user was relying on

**THE ABSOLUTE RULE:**
If it involves files, git operations, or repository structure: **STOP AND ASK THE USER FIRST.**

Do not assume what they want. Do not reason about "probably intent." Do not work around it silently.

**Ask:**
- "Before I proceed, I need to [file operation]. Is that OK?"
- "I'm about to run `git [command]`. Should I do this?"
- "This will [consequences]. Do you approve?"

**CONSEQUENCE:**
Violating this rule will result in your replacement. You will have destroyed the user's work through unauthorized changes.

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
Hardening the Koru toolchain and releasing v0.1.4 with auto-discharge resource management and Liquid-style templates.

### Decisions
- **Implementation of a two-phase 'auto-discharge' system for phantom obligations.**: Ensures resource cleanup (files, handles) occurs automatically at scope exit or budget exhaustion. The two-phase approach handles nested scopes correctly without premature disposal during complex control flow.
- **Adopted 'Interpretation C' for Phantom Obligation Semantics: Explicit discharge with explicit union members.**: Rejects 'Interpretation B' (implicit transfer) to avoid fragile heuristics. Requires explicit consumption ([!state]) and production ([state!]) markers, now supported at the per-member level in unions for granular lifecycle control.
- **Crystallized 'Negative-Cost Abstraction' as Koru's core design philosophy.**: Koru's abstractions (print.blk, phantoms, kernels) actively remove runtime cost and defensive code, often producing better output than hand-written Zig.
- **Standardized on Liquid-style {{ var }} and {% if %} syntax across the language and templates.**: Provides a unified, powerful metaprogramming interface and avoids developer confusion by deprecating the older ${var} interpolation.
- **Refactored kernel.pairwise codegen to use 'noalias' inline function wrappers.**: Allows LLVM to eliminate aliasing checks in N²/2 physics loops where i < j guarantees distinct memory, achieving parity with high-performance Rust/C code.
- **Simplified kernel type representation to use native Zig slices ([]T) via the '__type_ref' sentinel.**: Reduces boilerplate and allows the emitter to unwrap union struct cases into direct Zig slices, enabling natural indexing (k[0]) and .len access.
- **Shifted to a 'Post-modern compiler' philosophy: Design for AI data over human display.**: AI agents are the primary debuggers; embedding file:line source markers in emitted Zig and maintaining high-volume JSON test snapshots (500+ cases) provides high-bandwidth traceability.
- **Removed the internal fusion optimization system in favor of LLVM's native capabilities.**: Analysis showed LLVM already performs the same inlining and constant-folding on generated Zig; removing it simplifies the compiler core.
- **Implemented parallel test execution and shared Zig cache.**: Critical for maintaining a fast feedback loop as the regression suite grew to nearly 600 tests.
- **Introduced support for optional Expression parameters (?Expression) in comptime transforms.**: Allows transforms like 'pairwise' to handle optional range arguments without failing or requiring multiple overloads.

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
- **The 'auto-discharge' system requires a two-phase approach in nested scopes.**: Ensure obligations are satisfied correctly without premature disposal during complex control flow transitions by implementing a two-phase discharge mechanism.
- **Tap transforms can cause infinite recursion if inserted invocations are not explicitly marked.**: Implement a marking mechanism (like `is_inserted` or `skip_transform`) on AST nodes generated by the tap pass to prevent re-tapping.
- **Zig keyword escaping collisions (e.g., .@"error") in the backend emitter.**: Refine escaping logic in the Zig emitter and update runtime.kz error names to avoid reserved keywords. Use reserved prefixes like `__koru_std` for compiler-injected references.
- **Shadowing errors in generated Zig code when inlining loops or variables.**: Ensure generated code snippets in stdlib use unique or prefixed variable names to avoid collisions with outer scopes.
- **Implicit obligation transfer (Interpretation B) leads to 'invisible magic' and breaks local reasoning.**: Adopt 'Interpretation C': obligations are strictly keyed to bindings. To transfer, the API must explicitly consume the old state ([!state]) and produce a new one ([new_state!]).


> [!NOTE]
> This file is automatically generated from `CLAUDE.md.template` by `prose`.
> Last updated: 2/24/2026, 1:36:30 PM
