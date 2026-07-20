const std = @import("std");

/// Pure branch name matching for Koru shape validation.
///
/// This module validates that a set of handled branches correctly covers
/// an event's declared branches. It does NOT traverse ASTs or understand
/// control flow - it only matches branch names.
///
/// Design principles:
/// - Pure function: same inputs always produce same outputs
/// - No AST awareness: works on branch names, not node types
/// - No allocations in hot path: caller provides storage
/// - Easily unit-testable

pub const BranchChecker = struct {
    /// Branch kind: an effect (`!`) branch may be linked any number of times
    /// (each link fires during the event); a terminal (`|`) branch is a
    /// continuation and may have at most one UNGUARDED handler (a `when`-guard
    /// chain may add more, narrowing handlers, but only one unconditional one).
    pub const Kind = enum { effect, terminal };

    /// A declared branch from an event definition
    pub const DeclaredBranch = struct {
        name: []const u8,
        is_optional: bool = false,
        is_panic: bool = false,  // ?!-branch: unhandled => synthesized @panic (ignorable but UNSAFE to ignore)
        kind: Kind = .terminal,
    };

    /// A handled branch from user code (continuation)
    pub const HandledBranch = struct {
        name: []const u8,
        has_when_guard: bool = false,
        is_catchall: bool = false,
        /// `|` continuation (terminal) vs `!` continuation (effect). Only used
        /// by prototype mode, which relaxes undeclared TERMINAL arms but keeps
        /// undeclared EFFECT arms as errors (parity with the terminal-only
        /// missing-branch relaxation; effect arms lower to Handlers-struct fns).
        kind: Kind = .terminal,
    };

    /// Result of branch validation
    pub const ValidationResult = struct {
        is_valid: bool,
        missing_branches: []const []const u8,
        unknown_branches: []const []const u8,
        /// Terminal branches handled by more than one UNGUARDED handler —
        /// ambiguous, since a terminal continuation runs at most once.
        duplicate_terminal_branches: []const []const u8,
        /// Undeclared TERMINAL arms tolerated under `~[prototype]` — the "handled
        /// a branch the event doesn't declare yet" doodle (400_165). Kept OUT of
        /// `unknown_branches` (so they raise no KORU021) but recorded here so a
        /// lift-the-tag / readout step can list "thought about, not built yet."
        prototype_undeclared_branches: []const []const u8 = &.{},
    };

    /// Resolve a handled branch name to its declared branch (by index).
    /// Exact name match wins; failing that, a declared raw-name CLASS branch
    /// — a branch literally named `*` (spelled `| \`*\` *` in the event decl)
    /// — catches any remaining name. This is how a transform event like
    /// std/regex:match declares "any raw-name branch is legal here": the
    /// handled name IS data (a regex pattern, a route), not an identifier.
    pub fn resolveDeclared(declared: []const DeclaredBranch, name: []const u8) ?usize {
        for (declared, 0..) |decl, i| {
            if (std.mem.eql(u8, decl.name, name)) return i;
        }
        for (declared, 0..) |decl, i| {
            if (std.mem.eql(u8, decl.name, "*")) return i;
        }
        return null;
    }

    /// Check if handled branches correctly cover declared branches.
    ///
    /// Returns validation result with:
    /// - is_valid: true if all required branches are covered and no unknown branches exist
    /// - missing_branches: required branches that aren't handled
    /// - unknown_branches: handled branches that don't exist in declaration
    ///
    /// Rules:
    /// - Required branches MUST be covered by an UNGUARDED handler, an
    ///   engaging catchall, or a chain that ends in an unguarded fallback.
    /// - Optional branches MAY be handled. `when`-only handlers on optional
    ///   branches are fine because "no handler fires" is a legal trajectory
    ///   under the optional contract.
    /// - Unknown branches are ERRORS
    /// - Catchall (|?) covers all unhandled REQUIRED branches.
    /// - `when` guards NARROW a handler — they pick out a subset of fires.
    ///   They do NOT satisfy required-coverage on their own: a `when`-only
    ///   handler for a required branch leaves the false-guard case silently
    ///   uncovered, which is a coverage hole that looks like coverage in
    ///   source. See `docs/EFFECT_BRANCHES.md` "Exhaustiveness rules".
    pub fn validate(
        allocator: std.mem.Allocator,
        declared: []const DeclaredBranch,
        handled: []const HandledBranch,
    ) !ValidationResult {
        return validateWithMode(allocator, declared, handled, false);
    }

    /// Like `validate`, but `prototype_mode` relaxes TERMINAL-branch
    /// exhaustiveness. Under `~[prototype]`, an unhandled required terminal
    /// (`|`) branch is NOT reported missing — the auto-discharge pass
    /// synthesizes a loud `@panic` arm for it (an honest hole), exactly the way
    /// an unhandled `| ?!` panic branch is treated. Effect (`!`) branches keep
    /// full exhaustiveness even in prototype mode: they lower to Handlers-struct
    /// fns, not switch arms, and the presence-truth doctrine forbids synthesized
    /// stand-ins for them (400_146/147/154).
    pub fn validateWithMode(
        allocator: std.mem.Allocator,
        declared: []const DeclaredBranch,
        handled: []const HandledBranch,
        prototype_mode: bool,
    ) !ValidationResult {
        var missing = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        errdefer missing.deinit(allocator);
        var unknown = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        errdefer unknown.deinit(allocator);
        var proto_undeclared = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        errdefer proto_undeclared.deinit(allocator);

        // Check for catchall - if present, all required branches are covered
        var has_catchall = false;
        for (handled) |h| {
            if (h.is_catchall) {
                has_catchall = true;
                break;
            }
        }

        // Check that all required branches are handled by at least one
        // UNGUARDED handler (or by a catchall). Handled names resolve via
        // resolveDeclared, so a raw-name CLASS branch (`*`) is covered by any
        // handled name it catches.
        for (declared, 0..) |decl, di| {
            if (decl.is_optional) continue; // Optional branches don't need handling
            if (decl.is_panic) continue; // Panic branches are ignorable (unhandled => synthesized @panic)
            if (prototype_mode and decl.kind == .terminal) continue; // ~[prototype]: unhandled terminal => synthesized @panic hole (400_160)

            if (has_catchall) continue; // Catchall covers everything

            var found_unguarded = false;
            for (handled) |h| {
                if (h.is_catchall) continue; // Catchall doesn't count as specific handler
                if (resolveDeclared(declared, h.name) != di) continue;
                if (h.has_when_guard) continue; // Guards narrow; they don't cover
                found_unguarded = true;
                break;
            }

            if (!found_unguarded) {
                try missing.append(allocator, decl.name);
            }
        }

        // Check for unknown branches (handled but not declared — a raw-name
        // class branch `*` makes every name resolvable, so nothing is unknown).
        for (handled) |h| {
            if (h.is_catchall) continue; // Catchall is always valid

            if (resolveDeclared(declared, h.name) == null) {
                // ~[prototype]: an undeclared TERMINAL arm is the "handle a branch
                // the event doesn't declare yet" doodle (400_165) — let it slide
                // (no KORU021), but record it for the readout. Undeclared EFFECT
                // arms stay errors (parity with the terminal-only missing-branch
                // relaxation at line ~126).
                if (prototype_mode and h.kind == .terminal) {
                    try proto_undeclared.append(allocator, h.name);
                } else {
                    try unknown.append(allocator, h.name);
                }
            }
        }

        // Kind-aware cardinality: a terminal (`|`) branch is a continuation that
        // runs at most once, so it may have at most ONE unguarded handler. A
        // `when`-guard chain (many guarded + one unguarded fallback) is fine —
        // guards narrow, they don't duplicate. Effect (`!`) branches are exempt:
        // each link fires during the event, so any number is legal.
        var duplicate_terminals = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        errdefer duplicate_terminals.deinit(allocator);
        for (declared, 0..) |decl, di| {
            if (decl.kind != .terminal) continue;

            if (std.mem.eql(u8, decl.name, "*")) {
                // Raw-name CLASS branch: each distinct handled NAME caught by
                // the class is its own logical branch — two DIFFERENT names
                // are never duplicates of each other, but the SAME name twice
                // (unguarded) is dead code under first-match dispatch.
                for (handled, 0..) |h, i| {
                    if (h.is_catchall or h.has_when_guard) continue;
                    if (resolveDeclared(declared, h.name) != di) continue;
                    var seen_before = false;
                    for (handled[0..i]) |p| {
                        if (p.is_catchall or p.has_when_guard) continue;
                        if (std.mem.eql(u8, p.name, h.name)) {
                            seen_before = true;
                            break;
                        }
                    }
                    if (seen_before) {
                        try duplicate_terminals.append(allocator, h.name);
                    }
                }
                continue;
            }

            var unguarded_count: usize = 0;
            for (handled) |h| {
                if (h.is_catchall) continue;
                if (h.has_when_guard) continue;
                if (!std.mem.eql(u8, decl.name, h.name)) continue;
                unguarded_count += 1;
            }

            if (unguarded_count > 1) {
                try duplicate_terminals.append(allocator, decl.name);
            }
        }

        return ValidationResult{
            .is_valid = missing.items.len == 0 and unknown.items.len == 0 and
                duplicate_terminals.items.len == 0,
            .missing_branches = try missing.toOwnedSlice(allocator),
            .unknown_branches = try unknown.toOwnedSlice(allocator),
            .duplicate_terminal_branches = try duplicate_terminals.toOwnedSlice(allocator),
            .prototype_undeclared_branches = try proto_undeclared.toOwnedSlice(allocator),
        };
    }

    /// Free validation result memory
    pub fn freeResult(allocator: std.mem.Allocator, result: *ValidationResult) void {
        allocator.free(result.missing_branches);
        allocator.free(result.unknown_branches);
        allocator.free(result.duplicate_terminal_branches);
        allocator.free(result.prototype_undeclared_branches);
    }

    // ========================================================================
    // Sibling-level duplicate-handler rule — THE single source of truth.
    //
    // Both ShapeChecker and FlowChecker route their SHAPE002 duplicate-handler
    // walks through this rule (they only adapt AST continuations into
    // HandledBranch and report at the offending location). The rule is
    // kind-aware and declaration-free:
    //   - an effect (`!`) branch may be linked any number of times — every
    //     link fires during the event, so repetition is composition, never
    //     ambiguity;
    //   - a terminal (`|`) branch is a continuation that runs at most once, so
    //     at most ONE unguarded handler is legal at a level. A `when`-guard
    //     chain (many guarded + one unguarded fallback) is fine — guards
    //     narrow, they don't duplicate;
    //   - catch-alls never count toward duplication.
    // ========================================================================

    /// The offending handler of a sibling-level duplicate: `index` is the
    /// position of the SECOND unguarded handler of `name` in the slice handed
    /// to `firstDuplicateSibling` (so callers can point the diagnostic at the
    /// duplicate itself, not the level).
    pub const SiblingDuplicate = struct {
        index: usize,
        name: []const u8,
    };

    /// Find the first sibling-level duplicate under the kind-aware rule above.
    /// Returns null when the level is clean.
    pub fn firstDuplicateSibling(handled: []const HandledBranch) ?SiblingDuplicate {
        for (handled, 0..) |h, i| {
            if (h.is_catchall) continue;
            if (h.has_when_guard) continue;
            if (h.kind == .effect) continue; // effect links may repeat freely
            for (handled[0..i]) |p| {
                if (p.is_catchall) continue;
                if (p.has_when_guard) continue;
                if (p.kind == .effect) continue;
                if (std.mem.eql(u8, p.name, h.name)) {
                    return .{ .index = i, .name = h.name };
                }
            }
        }
        return null;
    }

    /// SHAPE002 message for a duplicated NAMED terminal branch. Single-sourced
    /// here so both checkers emit the identical diagnostic.
    pub const duplicate_terminal_fmt =
        "duplicate unguarded handler for branch '{s}' — a terminal '|' branch runs at most once, so at most one unguarded handler is allowed at a level; merge the handlers, or narrow all but one with 'when' guards (a guarded chain plus one unguarded fallback is legal)";

    /// SHAPE002 message for duplicated UNNAMED `|>` pipeline steps. The parser
    /// stitches consecutive line-start `|>` lines into one chain, so this only
    /// fires when something interrupted the chain (a handler line or dedent
    /// between steps) and left two loose steps at one level.
    pub const duplicate_unnamed_msg =
        "multiple unnamed '|>' steps at the same level — consecutive '|>' lines continue one chain only when nothing sits between them; write the steps as one '|>' chain (inline, or on consecutive '|>' continuation lines)";
};

// ============================================================================
// UNIT TESTS
// ============================================================================

test "empty event, empty continuations - valid" {
    const allocator = std.testing.allocator;
    const declared = [_]BranchChecker.DeclaredBranch{};
    const handled = [_]BranchChecker.HandledBranch{};

    var result = try BranchChecker.validate(allocator, &declared, &handled);
    defer BranchChecker.freeResult(allocator, &result);

    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(@as(usize, 0), result.missing_branches.len);
    try std.testing.expectEqual(@as(usize, 0), result.unknown_branches.len);
}

test "all required branches handled - valid" {
    const allocator = std.testing.allocator;
    const declared = [_]BranchChecker.DeclaredBranch{
        .{ .name = "success" },
        .{ .name = "failure" },
    };
    const handled = [_]BranchChecker.HandledBranch{
        .{ .name = "success" },
        .{ .name = "failure" },
    };

    var result = try BranchChecker.validate(allocator, &declared, &handled);
    defer BranchChecker.freeResult(allocator, &result);

    try std.testing.expect(result.is_valid);
}

test "required branch missing - invalid" {
    const allocator = std.testing.allocator;
    const declared = [_]BranchChecker.DeclaredBranch{
        .{ .name = "success" },
        .{ .name = "failure" },
    };
    const handled = [_]BranchChecker.HandledBranch{
        .{ .name = "success" },
        // failure is missing!
    };

    var result = try BranchChecker.validate(allocator, &declared, &handled);
    defer BranchChecker.freeResult(allocator, &result);

    try std.testing.expect(!result.is_valid);
    try std.testing.expectEqual(@as(usize, 1), result.missing_branches.len);
    try std.testing.expectEqualStrings("failure", result.missing_branches[0]);
}

test "optional branch missing - valid" {
    const allocator = std.testing.allocator;
    const declared = [_]BranchChecker.DeclaredBranch{
        .{ .name = "success" },
        .{ .name = "warning", .is_optional = true },
    };
    const handled = [_]BranchChecker.HandledBranch{
        .{ .name = "success" },
        // warning is optional, can be omitted
    };

    var result = try BranchChecker.validate(allocator, &declared, &handled);
    defer BranchChecker.freeResult(allocator, &result);

    try std.testing.expect(result.is_valid);
}

test "unknown branch - invalid" {
    const allocator = std.testing.allocator;
    const declared = [_]BranchChecker.DeclaredBranch{
        .{ .name = "success" },
    };
    const handled = [_]BranchChecker.HandledBranch{
        .{ .name = "success" },
        .{ .name = "donkey" }, // doesn't exist!
    };

    var result = try BranchChecker.validate(allocator, &declared, &handled);
    defer BranchChecker.freeResult(allocator, &result);

    try std.testing.expect(!result.is_valid);
    try std.testing.expectEqual(@as(usize, 1), result.unknown_branches.len);
    try std.testing.expectEqualStrings("donkey", result.unknown_branches[0]);
}

test "catchall covers all required branches - valid" {
    const allocator = std.testing.allocator;
    const declared = [_]BranchChecker.DeclaredBranch{
        .{ .name = "success" },
        .{ .name = "failure" },
        .{ .name = "timeout" },
    };
    const handled = [_]BranchChecker.HandledBranch{
        .{ .name = "", .is_catchall = true }, // |? covers everything
    };

    var result = try BranchChecker.validate(allocator, &declared, &handled);
    defer BranchChecker.freeResult(allocator, &result);

    try std.testing.expect(result.is_valid);
}

test "when-only handler does NOT cover a required continuation branch - invalid" {
    // RULING (Lars): for a continuation (terminal) branch, a `when`-guarded
    // handler with no unguarded fallback / catch-all does NOT cover it — the
    // false-guard trajectory is left silently uncovered. (This replaces the
    // stale "when guard still counts as handled - valid" intent.)
    const allocator = std.testing.allocator;
    const declared = [_]BranchChecker.DeclaredBranch{
        .{ .name = "value" }, // required, terminal
    };
    const handled = [_]BranchChecker.HandledBranch{
        .{ .name = "value", .has_when_guard = true }, // | value v when v > 10 |>
    };

    var result = try BranchChecker.validate(allocator, &declared, &handled);
    defer BranchChecker.freeResult(allocator, &result);

    try std.testing.expect(!result.is_valid);
    try std.testing.expectEqual(@as(usize, 1), result.missing_branches.len);
    try std.testing.expectEqualStrings("value", result.missing_branches[0]);
}

test "multiple handlers for same branch - valid" {
    const allocator = std.testing.allocator;
    const declared = [_]BranchChecker.DeclaredBranch{
        .{ .name = "value" },
    };
    const handled = [_]BranchChecker.HandledBranch{
        .{ .name = "value", .has_when_guard = true }, // | value v when v > 10 |>
        .{ .name = "value", .has_when_guard = true }, // | value v when v > 5 |>
        .{ .name = "value" }, // | value v |> (else case)
    };

    var result = try BranchChecker.validate(allocator, &declared, &handled);
    defer BranchChecker.freeResult(allocator, &result);

    try std.testing.expect(result.is_valid);
}

test "partial catchall with explicit handlers - valid" {
    const allocator = std.testing.allocator;
    const declared = [_]BranchChecker.DeclaredBranch{
        .{ .name = "success" },
        .{ .name = "failure" },
        .{ .name = "timeout" },
    };
    const handled = [_]BranchChecker.HandledBranch{
        .{ .name = "success" }, // Handle success explicitly
        .{ .name = "", .is_catchall = true }, // |? for the rest
    };

    var result = try BranchChecker.validate(allocator, &declared, &handled);
    defer BranchChecker.freeResult(allocator, &result);

    try std.testing.expect(result.is_valid);
}

test "only optional branches, none handled - valid" {
    const allocator = std.testing.allocator;
    const declared = [_]BranchChecker.DeclaredBranch{
        .{ .name = "warning", .is_optional = true },
        .{ .name = "info", .is_optional = true },
    };
    const handled = [_]BranchChecker.HandledBranch{
        // None handled - all optional
    };

    var result = try BranchChecker.validate(allocator, &declared, &handled);
    defer BranchChecker.freeResult(allocator, &result);

    try std.testing.expect(result.is_valid);
}

test "multiple missing branches - reports all" {
    const allocator = std.testing.allocator;
    const declared = [_]BranchChecker.DeclaredBranch{
        .{ .name = "a" },
        .{ .name = "b" },
        .{ .name = "c" },
    };
    const handled = [_]BranchChecker.HandledBranch{
        // None handled!
    };

    var result = try BranchChecker.validate(allocator, &declared, &handled);
    defer BranchChecker.freeResult(allocator, &result);

    try std.testing.expect(!result.is_valid);
    try std.testing.expectEqual(@as(usize, 3), result.missing_branches.len);
}

test "mixed valid and invalid - reports correctly" {
    const allocator = std.testing.allocator;
    const declared = [_]BranchChecker.DeclaredBranch{
        .{ .name = "success" },
        .{ .name = "failure" },
    };
    const handled = [_]BranchChecker.HandledBranch{
        .{ .name = "success" },
        .{ .name = "donkey" }, // unknown
        // failure missing
    };

    var result = try BranchChecker.validate(allocator, &declared, &handled);
    defer BranchChecker.freeResult(allocator, &result);

    try std.testing.expect(!result.is_valid);
    try std.testing.expectEqual(@as(usize, 1), result.missing_branches.len);
    try std.testing.expectEqual(@as(usize, 1), result.unknown_branches.len);
    try std.testing.expectEqualStrings("failure", result.missing_branches[0]);
    try std.testing.expectEqualStrings("donkey", result.unknown_branches[0]);
}

// ============================================================================
// `for` SHAPE CONTRACT
//
// `for` declares `! each *` (effect, required ≥1, may link any number of times)
// and `| ?done` (terminal, optional, at most one unguarded handler). These
// tests pin that contract at the pure-checker level. The kind-aware cardinality
// rule (terminal at-most-once-unguarded vs effect many) is what closes the
// "BranchChecker is kind-blind" gap.
// ============================================================================

const FOR_BRANCHES = [_]BranchChecker.DeclaredBranch{
    .{ .name = "each", .kind = .effect },
    .{ .name = "done", .kind = .terminal, .is_optional = true },
};

test "for: each handled, done omitted - valid" {
    const allocator = std.testing.allocator;
    const handled = [_]BranchChecker.HandledBranch{
        .{ .name = "each" },
    };
    var result = try BranchChecker.validate(allocator, &FOR_BRANCHES, &handled);
    defer BranchChecker.freeResult(allocator, &result);
    try std.testing.expect(result.is_valid);
}

test "for: each missing - invalid (at least one each required)" {
    const allocator = std.testing.allocator;
    const handled = [_]BranchChecker.HandledBranch{
        .{ .name = "done" },
    };
    var result = try BranchChecker.validate(allocator, &FOR_BRANCHES, &handled);
    defer BranchChecker.freeResult(allocator, &result);
    try std.testing.expect(!result.is_valid);
    try std.testing.expectEqual(@as(usize, 1), result.missing_branches.len);
    try std.testing.expectEqualStrings("each", result.missing_branches[0]);
}

test "for: multiple each handlers - valid (effect links any number of times)" {
    const allocator = std.testing.allocator;
    const handled = [_]BranchChecker.HandledBranch{
        .{ .name = "each" },
        .{ .name = "each" },
        .{ .name = "each" },
    };
    var result = try BranchChecker.validate(allocator, &FOR_BRANCHES, &handled);
    defer BranchChecker.freeResult(allocator, &result);
    try std.testing.expect(result.is_valid);
}

test "for: each plus single done - valid" {
    const allocator = std.testing.allocator;
    const handled = [_]BranchChecker.HandledBranch{
        .{ .name = "each" },
        .{ .name = "done" },
    };
    var result = try BranchChecker.validate(allocator, &FOR_BRANCHES, &handled);
    defer BranchChecker.freeResult(allocator, &result);
    try std.testing.expect(result.is_valid);
}

test "for: two unguarded done handlers - invalid (terminal at most once)" {
    // PIN of the kind-blind gap. A terminal branch may have at most one
    // UNGUARDED handler — two unconditional `| done` is ambiguous. RED until
    // the kind-aware cardinality rule lands in validate().
    const allocator = std.testing.allocator;
    const handled = [_]BranchChecker.HandledBranch{
        .{ .name = "each" },
        .{ .name = "done" },
        .{ .name = "done" },
    };
    var result = try BranchChecker.validate(allocator, &FOR_BRANCHES, &handled);
    defer BranchChecker.freeResult(allocator, &result);
    try std.testing.expect(!result.is_valid);
    try std.testing.expectEqual(@as(usize, 1), result.duplicate_terminal_branches.len);
    try std.testing.expectEqualStrings("done", result.duplicate_terminal_branches[0]);
}

test "for: unknown branch - invalid" {
    const allocator = std.testing.allocator;
    const handled = [_]BranchChecker.HandledBranch{
        .{ .name = "each" },
        .{ .name = "sideways" },
    };
    var result = try BranchChecker.validate(allocator, &FOR_BRANCHES, &handled);
    defer BranchChecker.freeResult(allocator, &result);
    try std.testing.expect(!result.is_valid);
    try std.testing.expectEqual(@as(usize, 1), result.unknown_branches.len);
    try std.testing.expectEqualStrings("sideways", result.unknown_branches[0]);
}

// ============================================================================
// SIBLING DUPLICATE RULE (firstDuplicateSibling)
//
// The shared sibling-level duplicate-handler rule both ShapeChecker and
// FlowChecker route through. Kind-aware: effect links repeat freely, terminal
// branches allow at most one unguarded handler per level.
// ============================================================================

test "sibling duplicates: two unguarded terminal handlers - duplicate" {
    const handled = [_]BranchChecker.HandledBranch{
        .{ .name = "done" },
        .{ .name = "done" },
    };
    const dup = BranchChecker.firstDuplicateSibling(&handled) orelse return error.TestExpectedDuplicate;
    try std.testing.expectEqual(@as(usize, 1), dup.index);
    try std.testing.expectEqualStrings("done", dup.name);
}

test "sibling duplicates: repeated effect links - clean" {
    const handled = [_]BranchChecker.HandledBranch{
        .{ .name = "v", .kind = .effect },
        .{ .name = "v", .kind = .effect },
        .{ .name = "v", .kind = .effect },
    };
    try std.testing.expect(BranchChecker.firstDuplicateSibling(&handled) == null);
}

test "sibling duplicates: guarded chain plus one unguarded fallback - clean" {
    const handled = [_]BranchChecker.HandledBranch{
        .{ .name = "value", .has_when_guard = true },
        .{ .name = "value", .has_when_guard = true },
        .{ .name = "value" },
    };
    try std.testing.expect(BranchChecker.firstDuplicateSibling(&handled) == null);
}

test "sibling duplicates: two unnamed pipeline steps - duplicate" {
    const handled = [_]BranchChecker.HandledBranch{
        .{ .name = "" },
        .{ .name = "" },
    };
    const dup = BranchChecker.firstDuplicateSibling(&handled) orelse return error.TestExpectedDuplicate;
    try std.testing.expectEqual(@as(usize, 1), dup.index);
    try std.testing.expectEqual(@as(usize, 0), dup.name.len);
}

test "sibling duplicates: catchall never counts - clean" {
    const handled = [_]BranchChecker.HandledBranch{
        .{ .name = "done" },
        .{ .name = "", .is_catchall = true },
        .{ .name = "err" },
    };
    try std.testing.expect(BranchChecker.firstDuplicateSibling(&handled) == null);
}

test "terminal: guarded chain plus one unguarded - valid" {
    // Counterpart to the duplicate-done pin: a `when` chain on a terminal
    // branch (many guarded + one unguarded) must stay valid.
    const allocator = std.testing.allocator;
    const declared = [_]BranchChecker.DeclaredBranch{
        .{ .name = "value", .kind = .terminal },
    };
    const handled = [_]BranchChecker.HandledBranch{
        .{ .name = "value", .has_when_guard = true },
        .{ .name = "value", .has_when_guard = true },
        .{ .name = "value" }, // single unguarded fallback
    };
    var result = try BranchChecker.validate(allocator, &declared, &handled);
    defer BranchChecker.freeResult(allocator, &result);
    try std.testing.expect(result.is_valid);
}
