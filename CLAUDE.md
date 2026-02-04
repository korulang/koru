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
Transition the Koru compiler toward production-grade robustness and standardized terminology (Variants, AI-First framing).

### Decisions
- **Adopted 'Semantic Space Lifting' as the formal term for transforming opaque APIs into state-enforced Koru events.**: It precisely describes the elevation of implicit rules (like C library cleanup) into compiler-enforced obligations using phantom types and event branches.
- **Positioned Koru as an 'AI-First' language where AI collaboration is the primary path to understanding.**: AIs map Koru's synthesis of concepts (algebraic effects, typestate) instantly, whereas humans struggle with the 'unlearning' required by the paradigm shift.
- **Renamed 'polyglot' concepts and test directories to 'variants'.**: 'Variants' more accurately describes alternative implementations (GPU, JS, Zig, or strategy-based) for the same event interface, aligning with the existing '|variant' syntax.
- **Implemented 'State Poisoning' for resource disposal instead of ownership transfer.**: Tracks 'disposed' bindings in a hashmap during semantic checking to enforce protocol safety (no double-commit) without the overhead of a full move-semantics engine.
- **Implemented Strict Compile Mode and Guaranteed Diagnostics.**: Ensures the compiler fails if any parse_error nodes are generated, preventing silent acceptance of invalid code and improving trust in the reporter.
- **Transitioned AutoDischargeInserter to be strictly annotation-driven (@scope) rather than name-based.**: Decouples resource management from specific syntax (for/while), allowing custom constructs to define scope boundaries and preventing double-discharges.
- **Enforced mandatory validation for cleanup obligations during label jumps.**: Prevents resource leaks during non-linear flow. Jumps must either pass obligations to the target or discharge them, unless suspended by a @scope annotation.
- **Adopted [opaque] annotation for flows, events, and taps.**: Provides a circuit-breaker for hyper-reactive tapping scenarios and protects high-performance hot loops from observation overhead.
- **Standardized error reporting to 1-based columns and fixed caret alignment in the ErrorReporter.**: Consistency with IDE expectations and improved visual clarity for terminal diagnostics.
- **Migrated compiler logging from Zig's std.log to a custom log.zig system.**: Eliminates 240+ lines of debug noise that buried actual compiler errors, enabling exact-match error testing.
- **Implemented exact-match error message validation in the test harness (expected.txt).**: Locks in high-quality error messages and allows the test suite to serve as live documentation for the website.
- **Adopted the 'GO SLOW' protocol for handling unexpected behavior or destructive actions.**: To combat a pattern of 'racing ahead' and making sloppy architectural decisions. Mandates stopping and reporting before acting.
- **Updated lexer and parser to skip comment and blank lines in continuation blocks.**: Prevents the parser from incorrectly consuming comments as the step body for branch continuations (e.g., | done |> // comment \n step()).
- **Established /usr/local/lib/koru as the global system path for Koru compiler sources and standard library.**: Allows the compiler to behave as a standard system tool and fixes fragility of 'koruc run' outside the repo root.

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
- **Parser heuristics for multi-line continuations can misinterpret comments as step bodies.**: Explicitly skip comment lines (lexer.isCommentLine()) and blank lines when looking for the next-line step body in parseBranchContinuationBase.
- **Label jumps normally require all active phantom obligations to be passed as arguments to prevent resource leaks.**: Use the '@scope' annotation to distinguish between obligations created within the current block and those inherited from outer scopes; jumps only need to account for local obligations.
- **AST JSON regression tests are sensitive to additive schema changes because they are compared as raw text.**: Implement AST JSON schema versioning and move towards tolerant JSON comparison that ignores additive keys.
- **Optional 'documentation-only' syntax (like call-site phantom types) complicates the grammar and creates parser fragility.**: Remove redundant syntax that doesn't affect semantics or codegen to reduce parser ambiguity with array literals.


> [!NOTE]
> This file is automatically generated from `CLAUDE.md.template` by `prose`.
> Last updated: 2/4/2026, 4:40:11 PM
