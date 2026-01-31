# Negative Test Plan

Tests for "almost correct" Koru code - ensuring helpful error messages.

**DELETE THIS DOCUMENT WHEN TESTS ARE IMPLEMENTED!!!**

**Should not live after february 10th**

---

## Legend

- **FRONTEND** = Caught by frontend with clean error (good!)
- **BACKEND** = Slips to backend, cryptic Zig error (needs parser fix)
- **DONE** = Test exists with expected.txt for exact matching
- **SKIP** = Compiler bug - code compiles but shouldn't

---

## Syntax/Tokenization Errors

| ID | Description | Caught? | Status |
|----|-------------|---------|--------|
| 510_015 | Wrong keyword (typo): `~evnet` | FRONTEND (wrong msg) | DONE |
| 510_016 | Wrong arrow: `-> ` instead of `\|>` | FRONTEND (wrong msg) | TODO |
| 510_017 | Double tilde: `~~event` | BACKEND | TODO |
| 510_018 | Wrong case: `~Event` | BACKEND | TODO |

## Event Structure Errors

| ID | Description | Caught? | Status |
|----|-------------|---------|--------|
| 510_001 | Unclosed input brace | FRONTEND | DONE |
| 510_002 | Unclosed branch brace | FRONTEND | DONE |
| 510_005 | Missing event name | FRONTEND | DONE |
| 510_020 | Missing pipe before branch | BACKEND | TODO |
| 510_021 | Duplicate branch names | BACKEND | DONE |
| 510_022 | Double pipe: `\|\| done` | FRONTEND | DONE |
| 510_023 | Branch without name: `\| {}` | FRONTEND | DONE |

## Shape Syntax Errors

| ID | Description | Caught? | Status |
|----|-------------|---------|--------|
| 510_030 | Missing colon: `{ x i32 }` | FRONTEND | DONE |
| 510_031 | Missing comma: `{ x: i32 y: i32 }` | BACKEND | DONE |
| 510_032 | Numeric field: `{ 123: i32 }` | COMPILES! | SKIP |
| 510_033 | Empty type: `{ x: }` | BACKEND | DONE |

## Proc/Flow Syntax Errors

| ID | Description | Caught? | Status |
|----|-------------|---------|--------|
| 510_040 | Missing = in proc | BACKEND | TODO |
| 510_041 | Empty proc body | BACKEND | TODO |
| 510_042 | Proc for undefined event | ? | TODO |
| 510_043 | Wrong branch in proc | ? | TODO |

## Import Errors

| ID | Description | Caught? | Status |
|----|-------------|---------|--------|
| 510_050 | Empty path: `~import ""` | FRONTEND | DONE |
| 510_051 | No quotes: `~import foo` | FRONTEND | DONE |
| 510_052 | Nonexistent: `~import "$src/x"` | STACK TRACE | TODO |

---

## Summary

**Created this session: 10 new tests**

Frontend catches with good errors (6):
- 510_022, 510_023, 510_030, 510_050, 510_051 (+ 510_015 with wrong msg)

Backend errors - need parser fixes (4):
- 510_021, 510_031, 510_033

Compiler bug (1):
- 510_032 - numeric field names accepted

---

## Priority for Parser Fixes

1. **510_021** - Duplicate branches → should be PARSE error
2. **510_031** - Missing comma → should be PARSE error
3. **510_033** - Empty type → should be PARSE error
4. **510_032** - Numeric field → should be rejected

---

## Notes

- Run individual test: `./run_regression.sh 510_0XX`
- Run all negative: `./run_regression.sh 510`
