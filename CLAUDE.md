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
Harden the Koru compiler's semantic layer by implementing phantom type serialization, refining phase inheritance, and automating regression tracking.

### Decisions
- **Include 'phantom' type annotations (e.g., File[open!]) in AST JSON serialization.**: To support downstream tools and debuggers that need to distinguish between standard types and semantic state-tracking metadata.
- **Implemented compile-time validation for array literals assigned to non-array targets.**: To catch type mismatches early and ensure Koru's array literals ([...]) have a known element type from context, avoiding performance-degrading heuristics.
- **Introduced deps.kz for centralized dependency management and enhanced testing.kz with mock support.**: Standardizes internal/external dependency resolution and provides better visibility into regression suite health via automated reporting (CLEANUP_TESTS.md).
- **Refined phase annotation inheritance to allow module-level defaults (e.g., [comptime]) with item-level overrides (e.g., [runtime]).**: Enables modules like testing.kz to be comptime by default while allowing specific runtime components, preventing illegal cross-phase references of AST pointers.
- **Established a 'Ground Truth' documentation policy, prioritizing verified tests and code over markdown.**: Prevents 'poisoning' the development process with outdated design docs. Generated llms.md as a machine-consumable spec derived strictly from SUCCESS-marked tests.
- **Adopted the '.impl' pattern and atomic unit treatment for complex control structures (try/catch, switch).**: Ensures architectural symmetry and prevents 'Frankenstein' states where a partial block (like a catch) is executed or transformed without its parent.
- **Standardized on Liquid-style {{ var }} syntax, deprecating ${var}.**: Provides a unified, powerful metaprogramming interface and reduces maintenance burden of dual-syntax templating.

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
- **Module-level phase annotations (e.g., [comptime]) were failing to propagate to individual items unless explicitly handled in inheritance logic.**: Refactor 'shouldFilter' to check both module and item-level annotations, allowing item-level to override or complement module defaults.
- **Circular dependencies or runtime crashes occur when modules containing AST pointers (like CompilerContext) are marked for runtime emission.**: Strictly mark modules with AST dependencies as ~[comptime] and ensure the emitter filters them out of runtime builds.
- **Array literals assigned to non-array types or mutable targets ([]T) lacked strict validation, leading to type-resolution gaps.**: Enforce strict type-driven emission where array literals resolve to a known slice type from context or error out; forbid mutable targets to prevent hidden allocations.
- **Large test result JSONs (6000+ lines) can bloat the repository and make diffs difficult to review.**: Maintain 'test-results/latest.json' as the primary pointer and consider git-ignoring individual timestamped runs.


> [!NOTE]
> This file is automatically generated from `CLAUDE.md.template` by `prose`.
> Last updated: 2/6/2026, 7:22:11 PM
