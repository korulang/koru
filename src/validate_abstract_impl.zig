const std = @import("std");
const log = @import("log");
const ast = @import("ast");

pub const ValidationError = error{
    DuplicateImplementation,
    ImplTargetNotFound,
    ImplTargetNotAbstract,
    OutOfMemory,
};

const ImplItem = union(enum) {
    subflow: *const ast.SubflowImpl,
    proc: *const ast.ProcDecl,
};

pub const AbstractImplValidator = struct {
    allocator: std.mem.Allocator,

    // Map canonical event path -> EventDecl (only abstract events)
    abstract_events: std.StringHashMap(*const ast.EventDecl),

    // Map canonical event path -> ImplItem (SubflowImpl or ProcDecl with is_impl=true)
    impls: std.StringHashMap(ImplItem),

    // Map canonical event path -> ProcDecl (for future delegation validation)
    procs: std.StringHashMap(*const ast.ProcDecl),

    pub fn init(allocator: std.mem.Allocator) AbstractImplValidator {
        return .{
            .allocator = allocator,
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
    pub fn validate(allocator: std.mem.Allocator, items: []const ast.Item) !void {
        var validator = AbstractImplValidator.init(allocator);
        defer validator.deinit();

        // First pass: collect abstract events, impls, and procs
        for (items) |item| {
            try validator.collectFromItem(item);
        }

        // Second pass: validate
        try validator.validateImplementations();
    }

    fn collectFromItem(self: *AbstractImplValidator, item: ast.Item) !void {
        switch (item) {
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
                            .subflow => |s| s.location,
                            .proc => |p| p.location,
                        };
                        log.debug("ERROR: Duplicate implementation for '{s}'\n", .{impl_name});
                        log.debug("  First impl at: {s}:{}:{}\n", .{
                            existing_location.file,
                            existing_location.line,
                            existing_location.column,
                        });
                        log.debug("  Second impl at: {s}:{}:{}\n", .{
                            proc.location.file,
                            proc.location.line,
                            proc.location.column,
                        });
                        self.allocator.free(impl_name);
                        return ValidationError.DuplicateImplementation;
                    }

                    try self.impls.put(impl_name, ImplItem{ .proc = proc });
                }
            },
            .subflow_impl => |*subflow| {
                // If this subflow is marked as impl, track it
                if (subflow.is_impl) {
                    const canonical_name = try self.buildCanonicalName(&subflow.event_path);
                    errdefer self.allocator.free(canonical_name);

                    // Check for duplicate implementation
                    if (self.impls.get(canonical_name)) |existing| {
                        const existing_location = switch (existing) {
                            .subflow => |s| s.location,
                            .proc => |p| p.location,
                        };
                        log.debug("ERROR: Duplicate implementation for '{s}'\n", .{canonical_name});
                        log.debug("  First impl at: {s}:{}:{}\n", .{
                            existing_location.file,
                            existing_location.line,
                            existing_location.column,
                        });
                        log.debug("  Second impl at: {s}:{}:{}\n", .{
                            subflow.location.file,
                            subflow.location.line,
                            subflow.location.column,
                        });
                        self.allocator.free(canonical_name);
                        return ValidationError.DuplicateImplementation;
                    }

                    try self.impls.put(canonical_name, ImplItem{ .subflow = subflow });
                }
            },
            .module_decl => |*module| {
                // Recursively process module items
                for (module.items) |module_item| {
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
                .subflow => |s| s.location,
                .proc => |p| p.location,
            };

            // Check if target exists and is abstract
            const target_event = self.abstract_events.get(target_path);
            if (target_event == null) {
                log.debug("ERROR: Implementation targets non-existent or non-abstract event '{s}'\n", .{target_path});
                log.debug("  Impl at: {s}:{}:{}\n", .{
                    impl_location.file,
                    impl_location.line,
                    impl_location.column,
                });
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
