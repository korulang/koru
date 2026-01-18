const std = @import("std");
const DEBUG = false;  // Set to true for verbose logging
const ast = @import("ast");
const errors = @import("errors");
const glob_pattern_matcher = @import("glob_pattern_matcher");

/// Represents a resolved tap entry in the registry
pub const TapEntry = struct {
    /// Source event pattern (e.g., "hello" or "std.io:file.*")
    source_pattern: []const u8,

    /// Destination event pattern (null for wildcard *)
    destination_pattern: ?[]const u8,

    /// Branch name to match (e.g., "done", "error")
    branch: []const u8,

    /// Tap's binding name (e.g., "d" in "| done d when ..."), null if no binding
    tap_binding: ?[]const u8,

    /// Optional when clause expression (AST form - may be null for serialized AST)
    when_expr: ?*const ast.Expression,

    /// Optional when clause condition (string form - fallback for serialized AST)
    when_condition_string: ?[]const u8,

    /// Single step to execute when tap fires (replaced pipeline array)
    step: ?ast.Step,

    /// Nested continuations after the tap's step (e.g., | done |> result { ... })
    continuations: []const ast.Continuation,

    /// True if source pattern has module qualifier (e.g., "std.io:file.*")
    source_is_qualified: bool,

    /// True if destination pattern has module qualifier
    dest_is_qualified: bool,

    /// Source module for resolving unqualified patterns
    source_module: []const u8,

    /// Annotations like [debug], [profiling], [opaque]
    annotations: []const []const u8,

    /// True if tap has [opaque] annotation (prevents other taps from observing its continuations)
    is_opaque: bool,

    /// For error reporting
    location: errors.SourceLocation,
};

/// Registry of all event taps in the program
pub const TapRegistry = struct {
    entries: std.ArrayList(TapEntry),
    allocator: std.mem.Allocator,

    /// Track concrete events referenced in tap matches (for selective enum generation)
    referenced_events: std.StringHashMap(void),

    /// Track concrete branches referenced in tap matches (for selective enum generation)
    referenced_branches: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) TapRegistry {
        return .{
            .entries = std.ArrayList(TapEntry).initCapacity(allocator, 0) catch unreachable,
            .allocator = allocator,
            .referenced_events = std.StringHashMap(void).init(allocator),
            .referenced_branches = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *TapRegistry) void {
        // TapEntry fields point to AST data (owned by parser)
        // Only clean up our data structures
        self.entries.deinit(self.allocator);
        self.referenced_events.deinit();
        self.referenced_branches.deinit();
    }

    /// Get all taps matching a given transition
    /// Also tracks the concrete events/branches for selective enum generation
    pub fn getMatchingTaps(
        self: *TapRegistry,
        source: []const u8,       // canonical: "module:event.path"
        branch: []const u8,
        destination: ?[]const u8, // canonical, or null for terminal
    ) ![]const TapEntry {
        var matches = try std.ArrayList(TapEntry).initCapacity(self.allocator, 0);
        errdefer matches.deinit(self.allocator);

        if (DEBUG) std.debug.print("TAP REGISTRY: getMatchingTaps: source='{s}' branch='{s}' dest='{s}'\n", .{
            source,
            branch,
            destination orelse "(null)",
        });

        for (self.entries.items) |entry| {
            if (DEBUG) std.debug.print("TAP REGISTRY:   Checking entry: source_pattern='{s}' branch='{s}'\n", .{
                entry.source_pattern,
                entry.branch,
            });

            // Check branch match - metatypes (Transition/Profile/Audit) match any branch
            const is_metatype = std.mem.eql(u8, entry.branch, "Transition") or
                               std.mem.eql(u8, entry.branch, "Profile") or
                               std.mem.eql(u8, entry.branch, "Audit");
            if (!is_metatype and !std.mem.eql(u8, entry.branch, branch)) {
                if (DEBUG) std.debug.print("TAP REGISTRY:     ❌ Branch mismatch\n", .{});
                continue;
            }

            // Check source pattern match
            if (!std.mem.eql(u8, entry.source_pattern, "*")) {
                const source_matches = try matchesPattern(
                    entry.source_pattern,
                    source,
                    entry.source_is_qualified,
                );
                if (!source_matches) {
                    if (DEBUG) std.debug.print("TAP REGISTRY:     ❌ Source pattern mismatch\n", .{});
                    continue;
                }
            }

            // Check destination pattern match
            if (entry.destination_pattern) |dest_pattern| {
                if (!std.mem.eql(u8, dest_pattern, "*")) {
                    if (destination) |dest| {
                        const matches_dest = try matchesPattern(
                            dest_pattern,
                            dest,
                            entry.dest_is_qualified,
                        );
                        if (!matches_dest) {
                            if (DEBUG) std.debug.print("TAP REGISTRY:     ❌ Destination pattern mismatch\n", .{});
                            continue;
                        }
                    } else {
                        // Pattern expects destination but transition is terminal
                        if (DEBUG) std.debug.print("TAP REGISTRY:     ❌ Pattern expects destination but transition is terminal\n", .{});
                        continue;
                    }
                }
            }

            if (DEBUG) std.debug.print("TAP REGISTRY:     ✅ MATCH!\n", .{});
            try matches.append(self.allocator, entry);
        }

        // If we have any matches, track the concrete events/branches used
        if (matches.items.len > 0) {
            // Track source event (extract event name from canonical)
            const source_event = extractEventName(source);
            try self.referenced_events.put(try self.allocator.dupe(u8, source_event), {});

            // Track destination event (if not terminal)
            if (destination) |dest| {
                const dest_event = extractEventName(dest);
                try self.referenced_events.put(try self.allocator.dupe(u8, dest_event), {});
            }

            // Track branch
            try self.referenced_branches.put(try self.allocator.dupe(u8, branch), {});
        }

        return try matches.toOwnedSlice(self.allocator);
    }

    /// Get sorted list of referenced events (for enum generation)
    pub fn getReferencedEvents(self: *const TapRegistry) ![]const []const u8 {
        var events = try std.ArrayList([]const u8).initCapacity(self.allocator, self.referenced_events.count());
        defer events.deinit(self.allocator);

        var it = self.referenced_events.keyIterator();
        while (it.next()) |key| {
            try events.append(self.allocator, key.*);
        }

        // Sort for deterministic output
        std.sort.block([]const u8, events.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        return try events.toOwnedSlice(self.allocator);
    }

    /// Get sorted list of referenced branches (for enum generation)
    pub fn getReferencedBranches(self: *const TapRegistry) ![]const []const u8 {
        var branches = try std.ArrayList([]const u8).initCapacity(self.allocator, self.referenced_branches.count());
        defer branches.deinit(self.allocator);

        var it = self.referenced_branches.keyIterator();
        while (it.next()) |key| {
            try branches.append(self.allocator, key.*);
        }

        // Sort for deterministic output
        std.sort.block([]const u8, branches.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        return try branches.toOwnedSlice(self.allocator);
    }

    /// Check if any taps use the Transition metatype
    pub fn hasTransitionTaps(self: *const TapRegistry) bool {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.branch, "Transition")) {
                return true;
            }
        }
        return false;
    }

    /// Check if any taps use the Profile metatype
    pub fn hasProfileTaps(self: *const TapRegistry) bool {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.branch, "Profile")) {
                return true;
            }
        }
        return false;
    }

    /// Check if any taps use the Audit metatype
    pub fn hasAuditTaps(self: *const TapRegistry) bool {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.branch, "Audit")) {
                return true;
            }
        }
        return false;
    }

    /// Check if a module has any opaque taps
    /// Used to detect modules that need tap-inserted steps skipped during emission
    pub fn moduleHasOpaqueTaps(self: *const TapRegistry, module_name: []const u8) bool {
        for (self.entries.items) |entry| {
            // Check if this tap is from the specified module and is opaque
            if (entry.is_opaque and std.mem.eql(u8, entry.source_module, module_name)) {
                return true;
            }
        }
        return false;
    }
};

/// Check if canonical name matches pattern with scoping rules
/// Now uses glob_pattern_matcher for module-qualified wildcard support
fn matchesPattern(
    pattern: []const u8,
    canonical: []const u8,
    pattern_is_qualified: bool,
) !bool {
    // Split canonical into module and event
    const colon_idx = std.mem.indexOfScalar(u8, canonical, ':');
    const module = if (colon_idx) |idx| canonical[0..idx] else "";
    const event = if (colon_idx) |idx| canonical[idx + 1 ..] else canonical;

    if (pattern_is_qualified) {
        // Pattern is qualified: split it and use our pattern matcher
        const pattern_colon = std.mem.indexOfScalar(u8, pattern, ':');
        const pattern_module = if (pattern_colon) |idx| pattern[0..idx] else "*";
        const pattern_event = if (pattern_colon) |idx| pattern[idx + 1 ..] else pattern;

        // Use glob_pattern_matcher's matchSegment for both module and event
        return glob_pattern_matcher.matchSegment(pattern_module, module) and
               glob_pattern_matcher.matchSegment(pattern_event, event);
    } else {
        // Pattern is unqualified: only match event name with wildcards
        return glob_pattern_matcher.matchSegment(pattern, event);
    }
}

/// Extract event name from canonical name (e.g., "module:event.path" -> "event.path")
fn extractEventName(canonical: []const u8) []const u8 {
    // Find the colon separator
    if (std.mem.indexOfScalar(u8, canonical, ':')) |colon_idx| {
        return canonical[colon_idx + 1 ..];
    }
    // No module qualifier, return as-is
    return canonical;
}

/// Simple glob matching supporting * wildcards
fn globMatch(pattern: []const u8, text: []const u8) bool {
    var p_idx: usize = 0;
    var t_idx: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (t_idx < text.len) {
        if (p_idx < pattern.len and (pattern[p_idx] == text[t_idx] or pattern[p_idx] == '?')) {
            // Character match or '?' wildcard
            p_idx += 1;
            t_idx += 1;
        } else if (p_idx < pattern.len and pattern[p_idx] == '*') {
            // Star wildcard - remember position
            star_idx = p_idx;
            match_idx = t_idx;
            p_idx += 1;
        } else if (star_idx) |si| {
            // No match, but we have a star - backtrack
            p_idx = si + 1;
            match_idx += 1;
            t_idx = match_idx;
        } else {
            // No match and no star to backtrack
            return false;
        }
    }

    // Consume remaining stars in pattern
    while (p_idx < pattern.len and pattern[p_idx] == '*') {
        p_idx += 1;
    }

    // Match succeeds if we consumed entire pattern
    return p_idx == pattern.len;
}

/// Check if annotation list contains a specific annotation
fn hasAnnotation(annotations: []const []const u8, name: []const u8) bool {
    for (annotations) |ann| {
        if (std.mem.eql(u8, ann, name)) {
            return true;
        }
    }
    return false;
}

/// Build tap registry from AST items (backend compiler pass)
pub fn buildTapRegistry(
    items: []const ast.Item,
    allocator: std.mem.Allocator,
) !TapRegistry {
    std.debug.print("BUILD TAP REGISTRY: Starting...\n", .{});
    var registry = TapRegistry.init(allocator);
    errdefer registry.deinit();

    // Recursively collect taps from all items (including nested modules)
    try collectTapsRecursive(items, allocator, &registry);

    std.debug.print("BUILD TAP REGISTRY: Complete. Found {} taps\n", .{registry.entries.items.len});
    return registry;
}

/// Recursive helper to collect taps from items and nested modules
fn collectTapsRecursive(
    items: []const ast.Item,
    allocator: std.mem.Allocator,
    registry: *TapRegistry,
) !void {
    for (items) |item| {
        switch (item) {
            .event_tap => |tap| {
                // Skip input taps for now (we're implementing output taps first)
                if (tap.is_input_tap) continue;

                // Convert source pattern to string
                const source_pattern = if (tap.source) |src|
                    try dottedPathToString(src, allocator)
                else
                    "*"; // wildcard

                const source_is_qualified = if (tap.source) |src|
                    src.module_qualifier != null
                else
                    false;

                // Convert destination pattern to string
                const dest_pattern = if (tap.destination) |dest|
                    try dottedPathToString(dest, allocator)
                else
                    null; // wildcard

                const dest_is_qualified = if (tap.destination) |dest|
                    dest.module_qualifier != null
                else
                    false;

                // Create entry for each continuation (branch)
                for (tap.continuations) |cont| {
                    // Validate: ANY wildcard source pattern can ONLY use metatype branches
                    // This prevents type errors like ~main:* -> * | result r |> where
                    // not all events have a .result branch
                    // Also prevents ~*:event -> * | result |> because different modules
                    // might define the same event name with different branch shapes
                    const has_wildcard = std.mem.indexOf(u8, source_pattern, "*") != null;
                    const is_metatype = std.mem.eql(u8, cont.branch, "Transition") or
                                       std.mem.eql(u8, cont.branch, "Profile") or
                                       std.mem.eql(u8, cont.branch, "Audit");

                    if (has_wildcard and !is_metatype) {
                        std.debug.print("\n", .{});
                        std.debug.print("ERROR: Invalid tap pattern in module '{s}'\n", .{tap.module});
                        std.debug.print("  Pattern: {s} -> * | {s}\n", .{source_pattern, cont.branch});
                        std.debug.print("\n", .{});
                        std.debug.print("  Problem: Cannot use concrete branch '{s}' with wildcard source pattern '{s}'\n",
                                       .{cont.branch, source_pattern});
                        std.debug.print("           Wildcard sources match multiple events with different branch shapes.\n", .{});
                        std.debug.print("\n", .{});
                        std.debug.print("  Solution: Use metatypes for wildcard sources:\n", .{});
                        std.debug.print("    ~{s} -> * | Transition t |>  // Transition metadata\n", .{source_pattern});
                        std.debug.print("    ~{s} -> * | Profile p |>     // Profiling\n", .{source_pattern});
                        std.debug.print("    ~{s} -> * | Audit a |>       // Auditing\n", .{source_pattern});
                        std.debug.print("\n", .{});
                        std.debug.print("  Or use a concrete source:\n", .{});
                        std.debug.print("    ~main:compute -> * | {s} r |>  // Type safe!\n", .{cont.branch});
                        std.debug.print("\n", .{});
                        return error.InvalidTapPattern;
                    }

                    const entry = TapEntry{
                        .source_pattern = source_pattern,
                        .destination_pattern = dest_pattern,
                        .branch = cont.branch,
                        .tap_binding = cont.binding,
                        .when_expr = cont.condition_expr,
                        .when_condition_string = cont.condition,  // Fallback for serialized AST
                        .step = cont.node,
                        .continuations = cont.continuations,  // Store tap's nested continuations
                        .source_is_qualified = source_is_qualified,
                        .dest_is_qualified = dest_is_qualified,
                        .source_module = tap.module,
                        .annotations = tap.annotations,
                        .is_opaque = hasAnnotation(tap.annotations, "opaque"),
                        .location = tap.location,
                    };

                    if (DEBUG) std.debug.print("TAP REGISTRY: Registered tap: source='{s}' (qualified={}) dest='{s}' (qualified={}) branch='{s}' source_module='{s}' is_opaque={}\n", .{
                        source_pattern,
                        source_is_qualified,
                        dest_pattern orelse "(null)",
                        dest_is_qualified,
                        cont.branch,
                        tap.module,
                        entry.is_opaque,
                    });

                    try registry.entries.append(allocator, entry);
                }
            },
            .module_decl => |module| {
                // Recursively collect taps from module items
                try collectTapsRecursive(module.items, allocator, registry);
            },
            else => {},
        }
    }
}

/// Convert DottedPath to string representation
fn dottedPathToString(path: ast.DottedPath, allocator: std.mem.Allocator) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer result.deinit(allocator);

    // Add module qualifier if present (e.g., "std.io:")
    if (path.module_qualifier) |mq| {
        try result.appendSlice(allocator, mq);
        try result.append(allocator, ':');
    }

    // Add segments joined by dots (e.g., "file.write")
    for (path.segments, 0..) |seg, i| {
        if (i > 0) try result.append(allocator, '.');
        try result.appendSlice(allocator, seg);
    }

    return try result.toOwnedSlice(allocator);
}
