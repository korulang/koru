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
    /// A declared branch from an event definition
    pub const DeclaredBranch = struct {
        name: []const u8,
        is_optional: bool = false,
    };

    /// A handled branch from user code (continuation)
    pub const HandledBranch = struct {
        name: []const u8,
        has_when_guard: bool = false,
        is_catchall: bool = false,
    };

    /// Result of branch validation
    pub const ValidationResult = struct {
        is_valid: bool,
        missing_branches: []const []const u8,
        unknown_branches: []const []const u8,
    };

    /// Check if handled branches correctly cover declared branches.
    ///
    /// Returns validation result with:
    /// - is_valid: true if all required branches are covered and no unknown branches exist
    /// - missing_branches: required branches that aren't handled
    /// - unknown_branches: handled branches that don't exist in declaration
    ///
    /// Rules:
    /// - Required branches MUST be handled (or covered by catchall)
    /// - Optional branches MAY be handled
    /// - Unknown branches are ERRORS
    /// - Catchall (|?) covers all unhandled branches
    /// - When guards don't affect coverage (branch is still handled)
    pub fn validate(
        allocator: std.mem.Allocator,
        declared: []const DeclaredBranch,
        handled: []const HandledBranch,
    ) !ValidationResult {
        var missing = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        errdefer missing.deinit(allocator);
        var unknown = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        errdefer unknown.deinit(allocator);

        // Check for catchall - if present, all required branches are covered
        var has_catchall = false;
        for (handled) |h| {
            if (h.is_catchall) {
                has_catchall = true;
                break;
            }
        }

        // Check that all required branches are handled
        for (declared) |decl| {
            if (decl.is_optional) continue; // Optional branches don't need handling

            if (has_catchall) continue; // Catchall covers everything

            var found = false;
            for (handled) |h| {
                if (h.is_catchall) continue; // Catchall doesn't count as specific handler
                if (std.mem.eql(u8, decl.name, h.name)) {
                    found = true;
                    break;
                }
            }

            if (!found) {
                try missing.append(allocator, decl.name);
            }
        }

        // Check for unknown branches (handled but not declared)
        for (handled) |h| {
            if (h.is_catchall) continue; // Catchall is always valid

            // Pattern branches ([...]) are opaque - skip validation
            // They're meant for comptime transforms to interpret
            if (h.name.len > 0 and h.name[0] == '[') continue;

            var found = false;
            for (declared) |decl| {
                if (std.mem.eql(u8, decl.name, h.name)) {
                    found = true;
                    break;
                }
            }

            if (!found) {
                try unknown.append(allocator, h.name);
            }
        }

        return ValidationResult{
            .is_valid = missing.items.len == 0 and unknown.items.len == 0,
            .missing_branches = try missing.toOwnedSlice(allocator),
            .unknown_branches = try unknown.toOwnedSlice(allocator),
        };
    }

    /// Free validation result memory
    pub fn freeResult(allocator: std.mem.Allocator, result: *ValidationResult) void {
        allocator.free(result.missing_branches);
        allocator.free(result.unknown_branches);
    }
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

test "when guard still counts as handled - valid" {
    const allocator = std.testing.allocator;
    const declared = [_]BranchChecker.DeclaredBranch{
        .{ .name = "value" },
    };
    const handled = [_]BranchChecker.HandledBranch{
        .{ .name = "value", .has_when_guard = true }, // | value v when v > 10 |>
    };

    var result = try BranchChecker.validate(allocator, &declared, &handled);
    defer BranchChecker.freeResult(allocator, &result);

    try std.testing.expect(result.is_valid);
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
