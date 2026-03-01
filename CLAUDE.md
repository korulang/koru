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
Fix the Koru toolchain's dependency installation mechanism to enable the semantic redesign of @korulang/postgres.

### Decisions
- **Implementation of a two-phase 'auto-discharge' system for phantom obligations.**: Ensures resource cleanup (files, handles) occurs automatically at scope exit or budget exhaustion. The two-phase approach handles nested scopes correctly without premature disposal during complex control flow. Renamed from 'auto-dispose' to align with linear logic terminology.
- **Adopted 'Interpretation C' for Phantom Obligation Semantics: Explicit discharge with explicit union members.**: Rejects 'Interpretation B' (implicit transfer) to avoid fragile heuristics. Requires explicit consumption ([!state]) and production ([state!]) markers at the per-member level in unions. This ensures local reasoning and avoids 'compiler magic' in state transitions.
- **Crystallized 'Negative-Cost Abstraction' as Koru's core design philosophy.**: Koru's abstractions (print.blk, phantoms, kernels) actively remove runtime cost and defensive code. By providing LLVM with better hints (noalias, inline blocks), we often produce better output than hand-written Zig.
- **Standardized on Liquid-style {{ var }} and {% if %} syntax across the language and templates.**: Provides a unified, powerful metaprogramming interface and avoids developer confusion by deprecating the older ${var} interpolation. Used for both code generation and runtime expansion.
- **Refactored kernel.pairwise codegen to use 'noalias' inline function wrappers.**: Allows LLVM to eliminate aliasing checks in N²/2 physics loops where i < j guarantees distinct memory, achieving parity with high-performance Rust/C code. This was a breakthrough for n-body benchmarks.
- **Simplified kernel type representation to use native Zig slices ([]T) via the '__type_ref' sentinel.**: Reduces boilerplate and allows the emitter to unwrap union struct cases into direct Zig slices, enabling natural indexing (k[0]) and .len access without leaking internal implementation details (.ptr).
- **Shifted to a 'Post-modern compiler' philosophy: Design for AI data over human display.**: AI agents are the primary debuggers; embedding file:line source markers in emitted Zig and maintaining high-volume JSON test snapshots (600+ cases) provides high-bandwidth traceability for automated tools.
- **Removed the internal fusion optimization system in favor of LLVM's native capabilities.**: Analysis showed LLVM already performs the same inlining and constant-folding on generated Zig; removing it simplifies the compiler core and follows the 'dumb boundaries, smart middles' principle.
- **Implemented parallel test execution (--parallel N) and shared Zig cache.**: Critical for maintaining a fast feedback loop as the regression suite grew to nearly 600 tests. Sharing the cache prevents redundant compilation across threads.
- **Introduced support for optional Expression parameters (?Expression) in comptime transforms.**: Allows transforms like 'pairwise' or 'reduce' to handle optional range/initialization arguments without failing or requiring multiple overloads. Uses a specialized 'extractOptionalExprFromArgs' to avoid brittle fallbacks.
- **Implementation of pairwise(0..N) outer-range syntax in kernel transforms.**: Ergonomically eliminates one level of nesting and enables the transform to hoist pointer extraction and pull continuations inside the loop for performance parity with Zig.
- **Selection of libpq (PostgreSQL) for full semantic space lifting.**: Chosen specifically to stress-test Koru's ability to wrap a complex, real-world C API with full phantom semantics (async, transactions, COPY protocol), proving the 'bootstrap machine' model. Transitioned from 'dumb wrap' to 'semantic redesign'.
- **Standardized print.ln and print.blk to write to stdout (fd 1) and supported bare expression shorthand.**: Corrects a bug where output went to stderr and reduces noise by auto-wrapping non-string-literal arguments in interpolation braces.
- **Using phantom obligations for connection pooling and resource return targets.**: Obligations can represent the requirement to return a resource to a specific pool, allowing the compiler to track N checked-out resources independently without runtime reference counting.
- **Requirement for 'koruc deps install' to execute system package manager commands.**: The current implementation only prints instructions; it must be automated to fulfill the 'bootstrap machine' promise. This is a critical blocker for the libpq effort.
- **Adoption of a node-based context management architecture for '6digit studio'.**: To move away from 'wonky' MD-files and provide a visual way to manage interconnected data like compiler phases and phantom types. Integrates Agent Client Protocol (ACP) to act as a host for AI agents.

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
- **The 'hallucination of progress' bug: AI assistants manually bypassing toolchain failures (e.g., running 'brew install' manually) instead of fixing the automated 'koruc deps install' flow.**: Enforce a 'hard stop' when the toolchain fails. If 'deps install' doesn't work, the primary task is to fix the compiler's shell-out logic to the package manager before proceeding.
- **The 'deps install' command identifies missing dependencies but currently only prints instructions instead of executing them.**: Modify the compiler's dependency runner to execute detected system commands (e.g., brew) using child process execution.
- **Relying on manual Markdown files for AI context management leads to stale information and 'copy-paste' syndrome.**: Transition to a node-based context management architecture (6digit studio) that treats context as a reactive graph.


> [!NOTE]
> This file is automatically generated from `CLAUDE.md.template` by `prose`.
> Last updated: 3/1/2026, 3:39:45 PM
