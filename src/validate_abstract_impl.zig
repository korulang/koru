const std = @import("std");
const ast = @import("ast");
const errors = @import("errors");

/// The pass still fails with a Zig error so the driver's control flow is
/// unchanged, but the SENTENCE the user reads is now a koru diagnostic on the
/// compilation's reporter (KORU113/KORU114). The error value is the signal to
/// stop, never the message: `main` prints the reporter and exits before the
/// value can reach stderr as a bare `error: ImplTargetNotAbstract` under a
/// koruc stack trace.
pub const ValidationError = error{
    DuplicateImplementation,
    ImplTargetNotAbstract,
    OutOfMemory,
};

const ImplItem = union(enum) {
    flow: *const ast.Flow,
    immediate_impl: *const ast.ImmediateImpl,
    proc: *const ast.ProcDecl,
};

pub const AbstractImplValidator = struct {
    allocator: std.mem.Allocator,
    reporter: *errors.ErrorReporter,

    // Map canonical event path -> EventDecl (only abstract events)
    abstract_events: std.StringHashMap(*const ast.EventDecl),

    // Map canonical event path -> ImplItem (Flow with impl_of, ImmediateImpl, or ProcDecl with is_impl=true)
    impls: std.StringHashMap(ImplItem),

    // Map canonical event path -> ProcDecl (for future delegation validation)
    procs: std.StringHashMap(*const ast.ProcDecl),

    pub fn init(allocator: std.mem.Allocator, reporter: *errors.ErrorReporter) AbstractImplValidator {
        return .{
            .allocator = allocator,
            .reporter = reporter,
            .abstract_events = std.StringHashMap(*const ast.EventDecl).init(allocator),
            .impls = std.StringHashMap(ImplItem).init(allocator),
            .procs = std.StringHashMap(*const ast.ProcDecl).init(allocator),
        };
    }

    pub fn deinit(self: *AbstractImplValidator) void {
        // Free keys from abstract_events
        var abs_iter = self.abstract_events.iterator();
        while (abs_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.abstract_events.deinit();

        // Free keys from impls
        var impl_iter = self.impls.iterator();
        while (impl_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.impls.deinit();

        // Free keys from procs
        var proc_iter = self.procs.iterator();
        while (proc_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.procs.deinit();
    }

    /// Validate abstract events and implementations in the AST
    /// MUST be called AFTER canonicalization - uses module_qualifier from paths
    pub fn validate(allocator: std.mem.Allocator, reporter: *errors.ErrorReporter, items: []const ast.Item) !void {
        var validator = AbstractImplValidator.init(allocator, reporter);
        defer validator.deinit();

        // First pass: collect abstract events, impls, and procs.
        // BY POINTER, not by value: the maps below store `*const` pointers INTO
        // these items and read their locations in the second pass. Iterating by
        // value would capture the loop's own copy, so every stored pointer
        // would dangle the moment collectFromItem returned — which is exactly
        // what made this pass's locations read as undefined-memory poison.
        for (items) |*item| {
            try validator.collectFromItem(item);
        }

        // Second pass: validate
        try validator.validateImplementations();
    }

    /// The one place a duplicate implementation becomes a sentence. All three
    /// collection sites (proc, flow, immediate impl) reach the same condition,
    /// so they report through here rather than each spelling their own prose.
    ///
    /// The caret goes on the SECOND implementation — the one the author just
    /// added — and the prose names the first. That second line number is a
    /// parser coordinate like any other, so it goes through `userLineIn`; a
    /// number interpolated straight into the message would disagree with its
    /// own caret by the height of the injected prelude.
    fn reportDuplicate(
        self: *AbstractImplValidator,
        name: []const u8,
        first: errors.SourceLocation,
        second: errors.SourceLocation,
    ) !void {
        try self.reporter.addErrorAtLocationWithHint(
            .KORU113,
            second,
            "two implementations claim the tor '{s}' — it was already implemented at {s}:{}",
            .{ name, first.file, self.reporter.userLineIn(first) },
            "a tor pairs with exactly one implementation; delete one of them, or give this one its own tor to implement",
            .{},
        );
    }

    fn collectFromItem(self: *AbstractImplValidator, item: *const ast.Item) !void {
        switch (item.*) {
            .event_decl => |*event| {
                if (event.hasAnnotation("abstract")) {
                    const canonical_name = try self.buildCanonicalName(&event.path);
                    errdefer self.allocator.free(canonical_name);
                    try self.abstract_events.put(canonical_name, event);
                }
            },
            .proc_decl => |*proc| {
                const canonical_name = try self.buildCanonicalName(&proc.path);
                errdefer self.allocator.free(canonical_name);
                try self.procs.put(canonical_name, proc);

                // If this proc is marked as impl, also track it
                if (proc.is_impl) {
                    const impl_name = try self.buildCanonicalName(&proc.path);
                    errdefer self.allocator.free(impl_name);

                    // Check for duplicate implementation
                    if (self.impls.get(impl_name)) |existing| {
                        const existing_location = switch (existing) {
                            .flow => |f| f.location,
                            .immediate_impl => |ii| ii.location,
                            .proc => |p| p.location,
                        };
                        try self.reportDuplicate(impl_name, existing_location, proc.location);
                        self.allocator.free(impl_name);
                        return ValidationError.DuplicateImplementation;
                    }

                    try self.impls.put(impl_name, ImplItem{ .proc = proc });
                }
            },
            .flow => |*flow| {
                // If this flow implements an event, track it
                if (flow.impl_of) |impl_path| {
                    if (flow.isImpl()) {
                        const canonical_name = try self.buildCanonicalName(&impl_path);
                        errdefer self.allocator.free(canonical_name);

                        // Check for duplicate implementation
                        if (self.impls.get(canonical_name)) |existing| {
                            const existing_location = switch (existing) {
                                .flow => |f| f.location,
                                .immediate_impl => |ii| ii.location,
                                .proc => |p| p.location,
                            };
                            try self.reportDuplicate(canonical_name, existing_location, flow.location);
                            self.allocator.free(canonical_name);
                            return ValidationError.DuplicateImplementation;
                        }

                        try self.impls.put(canonical_name, ImplItem{ .flow = flow });
                    }
                }
            },
            .immediate_impl => |*ii| {
                // If this immediate impl is a cross-module override, track it
                if (ii.isImpl()) {
                    const canonical_name = try self.buildCanonicalName(&ii.event_path);
                    errdefer self.allocator.free(canonical_name);

                    // Check for duplicate implementation
                    if (self.impls.get(canonical_name)) |existing| {
                        const existing_location = switch (existing) {
                            .flow => |f| f.location,
                            .immediate_impl => |existing_ii| existing_ii.location,
                            .proc => |p| p.location,
                        };
                        try self.reportDuplicate(canonical_name, existing_location, ii.location);
                        self.allocator.free(canonical_name);
                        return ValidationError.DuplicateImplementation;
                    }

                    try self.impls.put(canonical_name, ImplItem{ .immediate_impl = ii });
                }
            },
            .module_decl => |*module| {
                // Recursively process module items
                for (module.items) |*module_item| {
                    try self.collectFromItem(module_item);
                }
            },
            else => {
                // Other items don't matter for abstract/impl validation
            },
        }
    }

    fn validateImplementations(self: *AbstractImplValidator) !void {
        // Check each impl targets an abstract event
        var impl_iter = self.impls.iterator();
        while (impl_iter.next()) |entry| {
            const target_path = entry.key_ptr.*;
            const impl_item = entry.value_ptr.*;

            const impl_location = switch (impl_item) {
                .flow => |f| f.location,
                .immediate_impl => |ii| ii.location,
                .proc => |p| p.location,
            };

            // Check if target exists and is abstract
            const target_event = self.abstract_events.get(target_path);
            if (target_event == null) {
                // `abstract_events` holds ONLY tors annotated `~[abstract]`, so a
                // miss here cannot distinguish "no such tor" from "that tor is not
                // abstract". The sentence says both rather than picking one and
                // being confidently wrong half the time.
                try self.reporter.addErrorAtLocationWithHint(
                    .KORU114,
                    impl_location,
                    "this implements '{s}', which is not an abstract tor — no `~[abstract]` tor by that name is in scope",
                    .{target_path},
                    "only a tor declared `~[abstract]` can be implemented; check the spelling and the module qualifier, or add the annotation to its declaration",
                    .{},
                );
                return ValidationError.ImplTargetNotAbstract;
            }
        }
    }

    /// Build canonical name from a DottedPath (after canonicalization)
    /// Format: "module:segment.segment.segment"
    fn buildCanonicalName(self: *AbstractImplValidator, path: *const ast.DottedPath) ![]const u8 {
        const module = path.module_qualifier orelse {
            @panic("validate_abstract_impl must be called AFTER canonicalization!");
        };

        // Calculate total length needed
        var total_len: usize = module.len + 1; // module + ':'
        for (path.segments, 0..) |seg, i| {
            total_len += seg.len;
            if (i > 0) total_len += 1; // for '.'
        }

        // Build the canonical name
        var buf = try self.allocator.alloc(u8, total_len);
        var pos: usize = 0;

        // Add module qualifier
        @memcpy(buf[pos..pos + module.len], module);
        pos += module.len;
        buf[pos] = ':';
        pos += 1;

        // Add segments with dots
        for (path.segments, 0..) |seg, i| {
            if (i > 0) {
                buf[pos] = '.';
                pos += 1;
            }
            @memcpy(buf[pos..pos + seg.len], seg);
            pos += seg.len;
        }

        return buf;
    }
};
