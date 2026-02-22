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
Implement and verify functional-style data parallelism in the Koru standard library kernel via AST-aware comptime transformations.

### Decisions
- **Crystallized 'Negative-Cost Abstraction' as Koru's core design philosophy.**: Koru's abstractions (print.blk, phantoms, kernels) actively remove runtime cost and defensive code, often producing better output than hand-written Zig.
- **Implementation of kernel.self and pairwise as [comptime|transform] events with AST fusion.**: Allows per-element operations over kernel data to emit optimized Zig for-loops with known-length bounds and hoisted pointer extraction, outperforming standard runtime iteration.
- **Adopted ast_functional.replaceInvocationNodeAndContinuationsRecursive for pipeline-aware AST surgery.**: Ensures that transformations (like loop fusion) can 'swallow' downstream continuations to maintain correct scoping and flow in the generated code.
- **Standardized on Liquid-style {{ var }} and {% if %} syntax, deprecating ${var}.**: Provides a unified, powerful metaprogramming interface and avoids developer confusion across the language and standard library.
- **Implemented '//@koru:inline_stmt' marker in the Zig emitter.**: Allows transforms to inject multi-statement blocks (like if/return chains) into generated Zig without the emitter forcing invalid trailing semicolons.
- **Shifted to a 'Post-modern compiler' philosophy: Design for AI data over human display.**: AI agents are the primary debuggers; embedding file:line source markers in emitted Zig code provides high-bandwidth traceability without complex sourcemaps.
- **Automated npm release process with scripts/release.sh and AI-generated changelogs.**: Ensures reproducible cross-compilation for 5 targets and synchronizes versions across Zig and Node ecosystems.
- **Removed the redundant 'Fusion' optimization system in favor of LLVM's native capabilities.**: Analysis showed LLVM already performs the same inlining and constant-folding on generated Zig, making Koru-level fusion unnecessary overhead.
- **Implemented two-phase 'auto-discharge' for resource cleanup via phantom obligations.**: Automates resource management at scope boundaries, reducing boilerplate and preventing leaks by treating cleanup as a type-level requirement.

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
- **Comptime stripping Phase 3 was deleting transformed flows (like ~if or ~for), resulting in empty emitted code.**: Update compiler.kz to preserve flows containing 'inline_body', 'preamble_code', or '@pass_ran' metadata, even if they originated as comptime events.
- **AI 'hallucination' of progress and unauthorized code generation in sensitive library code (e.g., vaxis).**: Enforce minimal, targeted changes and verify against actual test results rather than aspirational specs. Use Sonnet for higher-fidelity reasoning.
- **Zig keyword escaping collisions (e.g., .@"error") in the backend emitter.**: Refine escaping logic in the Zig emitter and update runtime.kz error names to avoid reserved keywords.
- **Outdated documentation (SPEC.md) causing context poisoning for AI agents.**: Treat tests as the primary source of truth; delete stale documentation (like KORU_SYNTAX.md) and use automated test-result snapshots.
- **Shadowing errors in generated Zig code when inlining loops or variables.**: Ensure generated code snippets in stdlib use unique or prefixed variable names to avoid collisions with outer scopes.


> [!NOTE]
> This file is automatically generated from `CLAUDE.md.template` by `prose`.
> Last updated: 2/22/2026, 7:49:07 AM
