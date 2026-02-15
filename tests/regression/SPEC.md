# Koru Language Specification

> **Philosophy**: Documentation lives where it's tested. The regression tests cannot lie.

---

## Test Status

**Current status**: Run `./run_regression.sh --status` to see test results

The regression tests are the source of truth. They either compile and run, or they don't.

```bash
# See current test status (fast!)
./run_regression.sh --status

# Find regressions
./run_regression.sh --regressions

# Run specific test
./run_regression.sh 330_016

# Run a range (330-339)
./run_regression.sh 330

# Check specific test history
./run_regression.sh --history 123
```

---

## Directory Structure

```
tests/regression/
├── 000_CORE_LANGUAGE/          # Events, procs, flows, types
│   ├── 010_BASIC_SYNTAX/
│   ├── 020_EVENTS_FLOWS/
│   ├── 030_TYPES_VALUES/
│   └── 040_CONTROL_FLOW/
├── 100_MODULE_SYSTEM/          # Imports, namespaces, packages
│   ├── 110_IMPORTS/
│   ├── 120_NAMESPACES/
│   └── 130_PACKAGES/
├── 100_PARSER/                 # Parser features (identity branches, etc.)
├── 200_COMPILER_FEATURES/      # Parser, compilation, codegen, emitter
│   ├── 210_PARSER/
│   ├── 220_COMPILATION/
│   ├── 220_FLOW_CHECKER/
│   ├── 230_CODEGEN/
│   ├── 230_EMITTER/
│   ├── 240_STD_LIBRARY/
│   └── 260_SUBFLOW/
├── 200_SYNTAX/                 # Struct constructors
├── 300_ADVANCED_FEATURES/      # Comptime, phantom types, taps, etc.
│   ├── 310_COMPTIME/
│   ├── 320_STDLIB/
│   ├── 330_PHANTOM_TYPES/
│   ├── 340_FUSION/
│   ├── 340_TRANSFORMS/
│   ├── 350_SUBFLOWS/
│   ├── 355_OPTIONAL_BRANCHES/
│   ├── 360_TAPS_OBSERVERS/
│   ├── 365_INTERCEPTORS/       (design phase)
│   ├── 370_ACTORS/             (design phase)
│   ├── 380_TEMPLATING/
│   └── 390_KERNEL/
├── 320_CONTROL_FLOW/           # Expand, auto-thread pipeline
├── 400_RUNTIME_FEATURES/       # Purity, performance, budgeted interpreter
│   ├── 410_BUDGETED_INTERPRETER/
│   ├── 410_PURITY_CHECKING/
│   ├── 420_PERFORMANCE/
│   └── 430_RUNTIME/
├── 500_INTEGRATION_TESTING/    # Negative tests, bug reproductions, validation
│   ├── 510_NEGATIVE_TESTS/
│   ├── 520_BUG_REPRODUCTION/
│   └── 540_VALIDATION/
├── 600_STDLIB/                 # String, fmt
├── 700_EVENT_GLOBBING/         # Generics, glob patterns
├── 900_EXAMPLES_SHOWCASE/      # Hello world, language shootout, demos
│   ├── 910_LANGUAGE_SHOOTOUT/
│   └── 920_DEMO_APPLICATIONS/
└── tour/                       # Guided tour examples
```

---

## Specifications (SPEC.md files)

| Location | Topic | Status |
|----------|-------|--------|
| [000_CORE_LANGUAGE/SPEC.md](000_CORE_LANGUAGE/SPEC.md) | Events, procs, flows, type system | Needs path updates |
| [300_ADVANCED_FEATURES/310_COMPTIME/SPEC.md](300_ADVANCED_FEATURES/310_COMPTIME/SPEC.md) | Compile-time metaprogramming | Needs path updates |
| [300_ADVANCED_FEATURES/330_PHANTOM_TYPES/SPEC.md](300_ADVANCED_FEATURES/330_PHANTOM_TYPES/SPEC.md) | Phantom type states | Needs path updates |
| [300_ADVANCED_FEATURES/360_TAPS_OBSERVERS/SPEC.md](300_ADVANCED_FEATURES/360_TAPS_OBSERVERS/SPEC.md) | Event observation (`~tap()`) | Updated 2026-02-15 |
| [300_ADVANCED_FEATURES/365_INTERCEPTORS/SPEC.md](300_ADVANCED_FEATURES/365_INTERCEPTORS/SPEC.md) | Payload transformation | Design phase |
| [300_ADVANCED_FEATURES/370_ACTORS/SPEC.md](300_ADVANCED_FEATURES/370_ACTORS/SPEC.md) | Virtual actor system | Design phase |
| [300_ADVANCED_FEATURES/380_TEMPLATING/SPEC.md](300_ADVANCED_FEATURES/380_TEMPLATING/SPEC.md) | Liquid templates (`~emit`) | OK |
| [400_RUNTIME_FEATURES/410_BUDGETED_INTERPRETER/SPEC.md](400_RUNTIME_FEATURES/410_BUDGETED_INTERPRETER/SPEC.md) | Metered execution | Design phase |
| [400_RUNTIME_FEATURES/420_PERFORMANCE/SPEC.md](400_RUNTIME_FEATURES/420_PERFORMANCE/SPEC.md) | Optional branches, optimizations | Needs path updates |
| [500_INTEGRATION_TESTING/540_VALIDATION/SPEC.md](500_INTEGRATION_TESTING/540_VALIDATION/SPEC.md) | Branch coverage, phantom checking | Needs path updates |
| [900_EXAMPLES_SHOWCASE/910_LANGUAGE_SHOOTOUT/SPEC.md](900_EXAMPLES_SHOWCASE/910_LANGUAGE_SHOOTOUT/SPEC.md) | Benchmark methodology | OK |

> **WARNING**: Several SPEC.md files contain stale cross-references to old directory names.
> The tests themselves are the source of truth. When in doubt, read the test code.

---

## Quick Start

**New to Koru?** Start with the tests:

1. `000_CORE_LANGUAGE/010_BASIC_SYNTAX/` - Hello world, simple events
2. `100_MODULE_SYSTEM/110_IMPORTS/` - Multi-file programs
3. `300_ADVANCED_FEATURES/310_COMPTIME/` - Compile-time metaprogramming

**Looking for something specific?** Use `./run_regression.sh --status` or grep the test directories.

---

*The regression tests are the ultimate documentation - they cannot misrepresent reality.*
