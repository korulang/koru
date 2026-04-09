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

## PERMANENT SYNTAX REMINDER: The `~` Prefix

**The `~` prefix switches the parser from the host language (Zig) to Koru. It is NEVER used inside a Koru flow.**

Once you're in Koru (after the initial `~`), you stay in Koru until the flow ends. The `~` is a parser mode switch, not an "event call" operator.

```koru
// ~ switches from Zig to Koru - this starts a flow
~get_user(id: 4)
| ok u |>
    get_permissions(user: u)   // Already in Koru - no ~
    | ok p |>
        std.io:print.ln("...")  // Still in Koru - no ~
        | then |> ...
```

**WRONG - using `~` inside a flow:**
```koru
~provide()
| ok val |>
    ~std.io:print.ln("...")   // WRONG! This starts a NEW flow!
```

The parser will silently accept this and create TWO separate flows:
1. `~provide() | ok val |>` (with unused binding `val`)
2. `~std.io:print.ln(...)` (new top-level flow that can't see `val`)

**CORRECT:**
```koru
~provide()
| ok val |> std.io:print.ln("{{ val:any }}")
```

## 🧬 Project Consciousness
Enhance the Koru compiler help system to support and display subcommands dynamically from the AST.

### Decisions
- **Replaced string-scanning validation with structural AST parsing for branch constructors.**: String-based validation was too aggressive and lacked structural understanding, rejecting valid arithmetic and builtins. AST parsing allows precise rejection of function calls (enforcing purity) while permitting complex pure expressions like indexing and math.
- **Unified parameter parsing to use the ExpressionParser and enriched ast.Arg with a parsed_expression field.**: Ensures consistency across the language and enables complex expressions in parameters. The enrichment allows structured access for analysis while keeping raw strings for backend emission, avoiding breaking changes.
- **Adopted 'Interpretation C' for Phantom Obligation Semantics: Explicit discharge with explicit union members.**: Rejects implicit transfer to avoid fragile heuristics. Enforces 'meaningful consumption' (e.g., a connection must be used for a transaction) rather than just 'eventual disposal'. Now includes canonicalized base-type filtering ({module}:{type}) to prevent state collisions between different types.
- **Delegated base type checking to Zig's type system by default (lazy checking) with an optional --strict-base-types flag.**: Zig handles type aliases and module-qualified types more accurately than string-based comparison. The flag allows for earlier, albeit cruder, Koru-native error reporting when desired.
- **Transitioned error reporting to an 'algorithmic narrative' based on graph walking of phantom state machines.**: Since Koru rejects programs that don't reach a final discharge state, the compiler can provide 'GPS-like' navigation. Refined messages now distinguish between singular ('Call: x') and plural ('Call one of: x, y') disposal paths for better DX.
- **Shifted to dynamic help discovery by parsing the full AST (including imports) when --help is invoked.**: Previous help was 'fake' metacircular; it only saw flags in the immediate file. Deferring help execution until after AST construction allows discovery of user-defined commands and flags from the entire program.
- **Adopted 'Negative-Cost Abstraction' as Koru's core design philosophy, targeting sub-2KB binaries.**: Koru's abstractions (print.blk, phantoms, kernels) actively remove runtime cost. Aggressive optimization flags (-fno-unwind-tables, -z norelro) and compile-time asset embedding allow Koru to match or beat hand-written C/Zig performance and size.
- **Implemented a JSON-based test result snapshotting system with a 'latest.json' symlink.**: Tracks regression and progress across ~600 tests with detailed status (passed, failed, todo, etc.). Provides a stable reference point for CI/CD and developer visibility via a grep-friendly test index.
- **Migrated compiler and backend logging to a structured log module with levels (debug, verbose, info, err).**: Unconditional debug output was cluttering stderr and leaking into regression test results. Structured logging allows clean default output while preserving deep diagnostic traces via flags.
- **Proposed extending command.declare to support a nested subcommands array.**: Current command system is flat, leading to 'hidden' functionality (like 'deps install') that isn't discoverable in the dynamic help system.

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
- **The '--help' flag was short-circuiting the compiler before the AST was fully built, preventing discovery of flags/commands in imports.**: Defer help execution by setting a 'show_help' flag during argument parsing, allowing the frontend to complete AST construction and import resolution first.
- **Zig 0.15 'pointless discard' errors: Zig now rejects '_ = field;' for certain local constants, breaking emitted Koru handlers.**: The emitter must normalize all discards to address-of references: '_ = &field;'.
- **Eager string-based type checking in the phantom semantic checker causes false positives with Zig type aliases (e.g., 'const Conn = Connection').**: Delegate base type checking to the Zig compiler by default (lazy checking) and only enable eager Koru-native checking via '--strict-base-types'.
- **Phantom state name collisions (e.g., both Connection and Transaction having an 'active' state).**: Canonicalize base types into '{module}:{type}' format and filter disposal events by both state name and base type.


> [!NOTE]
> This file is automatically generated from `CLAUDE.md.template` by `prose`.
> Last updated: 3/28/2026, 5:28:31 PM
