# Contributing to Koru

Thank you for contributing to Koru! This guide ensures our documentation stays accurate and our codebase remains clean.

---

## 📋 Documentation Update Protocol

### When Adding a Feature

Follow this order strictly:

1. **✅ Add Regression Test First**
   - Create test in `tests/regression/XXX_feature_name/`
   - Tests are the source of truth - they cannot lie
   - Include `input.kz`, `expected.txt`, and marker files

2. **✅ Update SPEC.md**
   - Add grammar/syntax rules
   - Reference test number: `(verified by test XXX)`
   - Update relevant sections

3. **✅ Update KORU.md**
   - Add tutorial example
   - Show practical usage
   - Link to SPEC.md section

4. **✅ Update STATUS.md**
   - Add to feature list
   - Mark implementation status
   - Note any limitations

5. **✅ Link Documentation to Tests**
   - Update `docs/development/TEST_DOCUMENTATION_MAP.md`
   - Map SPEC.md sections to test numbers
   - Prove documentation accuracy

### When Fixing a Bug

1. **✅ Add/Update Regression Test**
   - Reproduce the bug in a test
   - Fix the bug
   - Verify test passes

2. **✅ Update KNOWN_ISSUES.md**
   - If documenting a workaround, add it
   - If fixing an issue, remove it
   - Keep the list current

3. **✅ Update STATUS.md**
   - Note the fix in recent achievements
   - Update implementation percentages

### When Updating Documentation

1. **✅ Verify Against Tests**
   - Check claims against `tests/regression/`
   - Only document what tests prove works
   - No aspirational claims

2. **✅ Add Verification Date**
   - Update "Last Verified" date
   - Note which tests verify the claim
   - Format: `Last Verified: 2025-10-02 (test 401-405)`

3. **✅ Update Cross-References**
   - Update DOCUMENTATION.md if adding new docs
   - Ensure all links work
   - Keep hierarchy clear

---

## 🏆 Documentation Trust Hierarchy

When in doubt, trust this order:

1. **🥇 Regression Tests** (`tests/regression/`)
   - Cannot lie - either compile/run or don't
   - Ultimate source of truth
   - All doc claims must be verified against tests

2. **🥈 Source Code** (`src/*.zig`)
   - Implementation is reality
   - Parser defines syntax
   - Emitter defines semantics

3. **🥉 SPEC.md + KORU.md**
   - Kept in sync with tests
   - Verification dates tracked
   - Test numbers referenced

4. **📊 STATUS.md**
   - Snapshot of current state
   - Updated with each session
   - Verified against test results

5. **📚 Other Documentation**
   - Useful but verify before trusting
   - Check last updated date
   - Cross-reference with tests

---

## ✅ Pull Request Checklist

### For New Features

- [ ] Regression test added and passing
- [ ] SPEC.md updated with syntax
- [ ] KORU.md updated with tutorial
- [ ] STATUS.md updated with feature status
- [ ] TEST_DOCUMENTATION_MAP.md updated
- [ ] All existing tests still pass
- [ ] `zig build` compiles successfully

### For Bug Fixes

- [ ] Regression test reproduces bug (or updated existing test)
- [ ] Test passes after fix
- [ ] KNOWN_ISSUES.md updated (added or removed)
- [ ] STATUS.md updated if significant
- [ ] All other tests still pass

### For Documentation Only

- [ ] Claims verified against regression tests
- [ ] Verification date added
- [ ] Test numbers referenced
- [ ] Links checked and working
- [ ] DOCUMENTATION.md updated if new file added

---

## 🔍 Monthly Documentation Audit

Maintainers should run this monthly:

### Step 1: Test Verification
```bash
./run_regression.sh
# Check: Do results match STATUS.md claims?
```

### Step 2: Age Check
```bash
find . -name "*.md" -mtime +30 -ls
# Flag: Docs older than 30 days need review
```

### Step 3: Claim Verification
- Review STATUS.md against test results
- Check SPEC.md examples compile
- Verify KORU.md tutorials work
- Update or archive outdated docs

### Step 4: Archive Review
- Move superseded docs to `docs/archive/`
- Add README to archive explaining context
- Preserve git history with `git mv`

---

## 📂 File Organization Rules

### What Goes Where

**Root Directory** (essential only):
- README.md, SPEC.md, KORU.md, STATUS.md, AI.md
- DOCUMENTATION.md, CONTRIBUTING.md
- build.zig, run_regression.sh
- `.gitignore`, `koru.json`

**docs/architecture/** - Core design:
- System architecture documents
- Design specifications
- Not "how-to" - "how it works"

**docs/implementation/** - Feature details:
- Implementation guides
- Feature-specific docs
- Technical deep-dives

**docs/development/** - Dev resources:
- Issue tracking (KNOWN_ISSUES.md)
- Test coverage maps
- Development guides

**docs/archive/** - Historical:
- Outdated status reports
- Superseded design docs
- Preserved for reference only

### What NOT to Keep at Root

- ❌ Old test files (→ test/archive/)
- ❌ Generated code (→ .gitignore)
- ❌ Backup files (→ delete)
- ❌ Example code (→ examples/)
- ❌ Design docs (→ docs/architecture/)

---

## 🚫 Common Mistakes to Avoid

### 1. Documenting Before Testing
**Wrong**: Write docs → hope it works
**Right**: Test works → document it

### 2. Aspirational Claims
**Wrong**: "Koru supports feature X" (unimplemented)
**Right**: "Koru supports feature X (verified by test 123)"

### 3. Ignoring Verification Dates
**Wrong**: Update docs without date
**Right**: Add `Last Verified: YYYY-MM-DD (test NNN)`

### 4. Creating Duplicate Status Docs
**Wrong**: Add another "STATUS" document
**Right**: Update existing STATUS.md

### 5. Bypassing the Toolchain
**Wrong**: Document manual workarounds
**Right**: Fix the toolchain, document the fix

---

## 💡 Best Practices

### Writing Good Documentation

1. **Start with Tests**
   - Test proves it works
   - Documentation explains it
   - Tests prevent docs drift

2. **Be Specific**
   - Bad: "Imports work"
   - Good: "Import syntax: `~import \"file.kz\" => name` (test 405)"

3. **Link Everything**
   - Cross-reference related docs
   - Link to test numbers
   - Connect tutorial to spec

4. **Update Incrementally**
   - Small, focused updates
   - One feature at a time
   - Clear commit messages

5. **Archive, Don't Delete**
   - Move to `docs/archive/`
   - Add context README
   - Preserve git history

### Writing Good Tests

1. **Descriptive Names**
   - `405_import_explicit_namespace` ✅
   - `test123` ❌

2. **Clear Expected Output**
   - Exact string in `expected.txt`
   - Or clear error message
   - No ambiguity

3. **Self-Documenting**
   - Comments explain what's tested
   - Header shows purpose
   - Minimal but complete

---

## 🤝 Code Review Guidelines

### What to Look For

1. **Test Coverage**
   - Is there a regression test?
   - Does it actually test the feature?
   - Does it pass?

2. **Documentation Accuracy**
   - Are claims verified by tests?
   - Are test numbers referenced?
   - Are verification dates current?

3. **File Organization**
   - Is everything in the right place?
   - No root directory pollution?
   - Archives used properly?

4. **Cross-References**
   - Do all links work?
   - Is DOCUMENTATION.md updated?
   - Is TEST_DOCUMENTATION_MAP.md updated?

---

## 📞 Questions?

- **Feature questions**: Check `tests/regression/` - they prove what works
- **Architecture questions**: See `docs/architecture/`
- **Getting started**: Read DOCUMENTATION.md
- **Stuck**: Check KNOWN_ISSUES.md

---

**Remember**: Tests are the source of truth. When documentation conflicts with tests, the tests are always right.
