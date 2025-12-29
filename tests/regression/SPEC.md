# Koru Language Specification

> **Philosophy**: Documentation lives where it's tested. The regression tests cannot lie.

---

## 🧪 Test Status

**Current status**: Run `./run_regression.sh --status` to see test results

The regression tests are the source of truth. They either compile and run, or they don't.

```bash
# See current test status (fast!)
./run_regression.sh --status

# List all tests
./run_regression.sh --list

# Run all regression tests (~10 minutes)
./run_regression.sh

# Run specific test
./run_regression.sh 201
```

---

## 📚 Documentation Navigation

All detailed specifications live in `tests/regression/` directories alongside the tests that verify them.

**Core Categories** (have SPEC.md files):
- [000_CORE_LANGUAGE/SPEC.md](tests/regression/000_CORE_LANGUAGE/SPEC.md) - Events, procs, flows, type system
- [100_IMPORTS/SPEC.md](tests/regression/100_IMPORTS/SPEC.md) - Module system, path aliases
- [400_VALIDATION/SPEC.md](tests/regression/400_VALIDATION/SPEC.md) - Type checking, phantom states
- [500_TAPS_OBSERVERS/SPEC.md](tests/regression/500_TAPS_OBSERVERS/SPEC.md) - Event observers, annotations
- [600_COMPTIME/SPEC.md](tests/regression/600_COMPTIME/SPEC.md) - Metacircular compilation, FlowAST
- [650_PHANTOM_TYPES/SPEC.md](tests/regression/650_PHANTOM_TYPES/SPEC.md) - State tracking
- [1200_OPTIMIZATIONS/SPEC.md](tests/regression/1200_OPTIMIZATIONS/SPEC.md) - Compiler optimizations

**All Categories** (run `./run_regression.sh --status` to see which have docs):
- `000_CORE_LANGUAGE` - Core language features
- `050_PARSER` - Parser features
- `100_IMPORTS` - Module system
- `200_CONTROL_FLOW` - Branches, labels, jumps
- `300_SUBFLOWS` - Compile-time event bindings
- `400_VALIDATION` - Type checking
- `500_TAPS_OBSERVERS` - Event observation
- `600_COMPTIME` - Metacircular compilation
- `650_PHANTOM_TYPES` - State tracking
- `700_EXPRESSIONS` - Expression handling
- `1000_PURITY` - Purity tracking
- `1100_FUSION` - Event fusion
- `1200_OPTIMIZATIONS` - Optimizations
- Plus: performance tests, benchmarks, examples, negative tests, bug reproductions

---

## 🎯 Quick Start

**New to Koru?** Read in this order:

1. [000_CORE_LANGUAGE/SPEC.md](tests/regression/000_CORE_LANGUAGE/SPEC.md) - **Start here**
2. [100_IMPORTS/SPEC.md](tests/regression/100_IMPORTS/SPEC.md) - Multi-file programs
3. [600_COMPTIME/SPEC.md](tests/regression/600_COMPTIME/SPEC.md) - The magic

**Looking for something specific?** Use `./run_regression.sh --list` to see all tests with descriptions, or grep the regression test directories.

---

## ✏️ Contributing to Documentation

1. Find the test category (e.g., `200_CONTROL_FLOW/`)
2. Edit or create the SPEC.md in that directory
3. Add tests that verify what the spec claims
4. Run `./run_regression.sh <number>` to verify

**Documentation that isn't verified by tests will drift.** Keep docs and tests together.

---

*The regression tests are the ultimate documentation - they cannot misrepresent reality.*
