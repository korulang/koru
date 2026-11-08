const std = @import("std");
const log = @import("log");
const DEBUG = false;  // Set to true for verbose logging
const ast = @import("ast");
const module_resolver_mod = @import("module_resolver");
const ModuleResolver = module_resolver_mod.ModuleResolver;

// Explicit error set to avoid circular inference with recursive foreach/conditional
const CanonicalizeError = error{OutOfMemory};

/// Canonicalize all DottedPaths in the AST by setting module_qualifier
/// This runs after import resolution, when all modules are loaded.
/// After this pass, ALL DottedPaths have a module_qualifier set.
///
/// Why canonicalize?
/// - Single source of truth for name resolution
/// - Simplifies all downstream passes (no need to track "current module")
/// - Enables reliable pattern matching (taps, type checking, etc.)
/// - Clear architectural boundary: Parse → Import → [CANONICALIZE] → Transform → Emit

/// `resolver` additionally enables ALIAS-IDENTITY normalization: a module is
/// emitted under ONE container name — the `logical_name` minted from whichever
/// import spelling the loader processed first — so any other spelling that
/// resolves to the same canonical file is rewritten to that logical name
/// (230_008: `b/pump:Payload` under an `a/pump` import; `koru/metal:KeyData`
/// under `libs/metal`). Without it, decl-carried qualified types dangle in
/// generated code while dedup still merges the modules — identity-keyed
/// dedup, spelling-keyed naming. Resolution that finds no module leaves the
/// spelling untouched (same behavior as before this pass).
pub fn canonicalize(program: *ast.Program, allocator: std.mem.Allocator, resolver: ?*ModuleResolver) !void {
    if (DEBUG) log.debug("CANONICALIZE: Starting full AST canonicalization\n", .{});
    if (DEBUG) log.debug("CANONICALIZE: Main module: '{s}'\n", .{program.main_module_name});

    var ctx = Context{
        .main_module = program.main_module_name,
        .current_module = program.main_module_name,
        .allocator = allocator,
        .resolver = resolver,
    };

    // canonical file path → materialized logical_name, for every module the
    // loader actually emitted. Directory modules key BOTH the dir path and
    // the index file resolveKoruFileIn picks — the two identities dedup
    // already treats as one (import_pipeline's moduleIdentity rule).
    if (resolver != null) {
        ctx.identity_map = std.StringHashMap([]const u8).init(allocator);
        ctx.spelling_cache = std.StringHashMap(?[]const u8).init(allocator);
        for (program.items) |*item| {
            if (item.* != .module_decl) continue;
            const md = &item.module_decl;
            try ctx.identity_map.?.put(try allocator.dupe(u8, md.canonical_path), md.logical_name);
            if (ModuleResolver.isDirectory(md.canonical_path)) {
                if (try module_resolver_mod.resolveKoruFileIn(allocator, md.canonical_path, "index")) |index_path| {
                    try ctx.identity_map.?.put(index_path, md.logical_name);
                }
            }
        }
    }
    defer if (ctx.identity_map) |*m| {
        var kit = m.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        m.deinit();
    };
    defer if (ctx.spelling_cache) |*c| {
        var kit = c.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        c.deinit();
    };

    // Walk all items and canonicalize their paths
    for (program.items) |*item| {
        try canonicalizeItem(&ctx, @constCast(item));
    }

    if (DEBUG) log.debug("CANONICALIZE: Completed successfully\n", .{});
}

const Context = struct {
    main_module: []const u8,      // The entry module name (e.g., "input")
    current_module: []const u8,   // Current module context as we walk
    allocator: std.mem.Allocator,
    resolver: ?*ModuleResolver = null,
    identity_map: ?std.StringHashMap([]const u8) = null,
    // spelling → logical_name-or-null — resolveBoth probes the filesystem, so
    // each unique spelling pays once per pass, not once per occurrence. Misses
    // are cached too (unresolvable spellings dominate in real programs).
    spelling_cache: ?std.StringHashMap(?[]const u8) = null,
    base_file: ?[]const u8 = null, // Containing module's canonical path — base for relative spellings
};

/// Resolve a module spelling (`b/pump`, `b.pump`) to the logical name of the
/// module it resolves to — the one container name that file is emitted under.
/// Null when no resolver/map is armed or the spelling resolves to nothing
/// imported (left verbatim, same as before).
fn resolveModuleSpelling(ctx: *Context, spelling: []const u8) ?[]const u8 {
    if (ctx.resolver == null or ctx.identity_map == null) return null;

    // Relative spellings depend on the declaring module's location — a flat
    // cache keyed on the spelling alone could cross-resolve them, so they
    // bypass the cache (they are also rare: qualifiers are almost always
    // alias-form).
    const cacheable = spelling.len == 0 or spelling[0] != '.';
    if (cacheable) {
        if (ctx.spelling_cache.?.get(spelling)) |cached| return cached;
    }
    const resolved_name = resolveModuleSpellingUncached(ctx, spelling);
    if (cacheable) {
        const key = ctx.allocator.dupe(u8, spelling) catch return resolved_name;
        ctx.spelling_cache.?.put(key, resolved_name) catch {};
    }
    return resolved_name;
}

fn resolveModuleSpellingUncached(ctx: *Context, spelling: []const u8) ?[]const u8 {
    const resolver = ctx.resolver orelse return null;
    const map = ctx.identity_map orelse return null;

    // The resolver speaks import paths (`b/pump`); a dotted qualifier is the
    // same spelling canonicalized — dots and slashes both mean segments here.
    var buf: [512]u8 = undefined;
    if (spelling.len >= buf.len) return null;
    const slash_spelling = buf[0..spelling.len];
    @memcpy(slash_spelling, spelling);
    for (slash_spelling) |*c| {
        if (c.* == '.') c.* = '/';
    }

    var resolved = resolver.resolveBoth(slash_spelling, ctx.base_file) catch return null;
    // resolveBoth allocates on the resolver's allocator, not ours — free with
    // the allocator that minted the paths or the free silently misses.
    defer resolved.deinit(resolver.allocator);

    if (resolved.file_path) |fp| {
        if (map.get(fp)) |ln| return ln;
    }
    if (resolved.dir_path) |dp| {
        if (map.get(dp)) |ln| return ln;
        if (module_resolver_mod.resolveKoruFileIn(ctx.allocator, dp, "index") catch null) |index_path| {
            defer ctx.allocator.free(index_path);
            if (map.get(index_path)) |ln| return ln;
        }
    }
    return null;
}

/// Rewrite a stored module spelling to the materialized logical_name in
/// place: frees the old spelling, dupes the resolved one. No-op when the
/// spelling resolves to nothing (or to the name it already carries).
fn normalizeSpelling(ctx: *Context, spelling_slot: *?[]const u8) !void {
    const old = spelling_slot.* orelse return;
    const resolved = resolveModuleSpelling(ctx, old) orelse return;
    if (std.mem.eql(u8, resolved, old)) return;
    ctx.allocator.free(old);
    spelling_slot.* = try ctx.allocator.dupe(u8, resolved);
}

/// A `mod.path:` qualifier embedded in a TYPE STRING (`*b/pump:Payload`,
/// `-> b/pump:Payload`, phantom `b/pump:taken!`) is the same spelling class —
/// the parser splits it into Field.module_path only on some paths, so the
/// string sites need the rewrite too. Finds the depth-0 `:` outside `[]`/`<>`,
/// takes the path token immediately before it, and rewrites it when it
/// resolves. Conservative: anything that doesn't resolve is left byte-exact.
fn normalizeTypeStringOpt(ctx: *Context, string_slot: *?[]const u8) !void {
    const old = string_slot.* orelse return;
    if (try normalizeTypeString(ctx, old)) |rewritten| {
        ctx.allocator.free(old);
        string_slot.* = rewritten;
    }
}

fn normalizeTypeString(ctx: *Context, old: []const u8) !?[]const u8 {
    var bracket_depth: i32 = 0;
    var angle_depth: i32 = 0;
    var colon_idx: ?usize = null;
    for (old, 0..) |c, i| {
        switch (c) {
            '[' => bracket_depth += 1,
            ']' => bracket_depth -= 1,
            '<' => angle_depth += 1,
            '>' => angle_depth -= 1,
            ':' => if (bracket_depth == 0 and angle_depth == 0) {
                colon_idx = i;
                break;
            },
            else => {},
        }
    }
    const ci = colon_idx orelse return null;
    // Walk back over the path token (ident chars + separators).
    var start = ci;
    while (start > 0) {
        const c = old[start - 1];
        const is_path_char = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-' or c == '/' or c == '.';
        if (!is_path_char) break;
        start -= 1;
    }
    if (start == ci) return null;
    const spelling = old[start..ci];
    const resolved = resolveModuleSpelling(ctx, spelling) orelse return null;
    if (std.mem.eql(u8, resolved, spelling)) return null;
    return try std.fmt.allocPrint(ctx.allocator, "{s}{s}{s}", .{ old[0..start], resolved, old[ci..] });
}

/// Field.module_path is a stored spelling (`b/pump` from `b/pump:Payload`);
/// normalize it the same as a path qualifier, plus the string-typed carries.
fn normalizeShapeFields(ctx: *Context, shape: *ast.Shape) !void {
    if (ctx.resolver == null) return;
    for (shape.fields) |*field| {
        const f = @constCast(field);
        try normalizeSpelling(ctx, &f.module_path);
        if (try normalizeTypeString(ctx, f.type)) |rewritten| {
            ctx.allocator.free(f.type);
            f.type = rewritten;
        }
        try normalizeTypeStringOpt(ctx, &f.phantom);
    }
}

fn canonicalizeItem(ctx: *Context, item: *ast.Item) !void {
    switch (item.*) {
        .module_decl => |*module| {
            if (DEBUG) log.debug("CANONICALIZE: Entering module '{s}' (logical: '{s}')\n", .{module.canonical_path, module.logical_name});

            // Save previous module context
            const prev_module = ctx.current_module;
            const prev_base = ctx.base_file;
            // Use logical_name for module qualifier to match emitted code structure
            ctx.current_module = module.logical_name;
            ctx.base_file = module.canonical_path;

            // Recursively canonicalize module items
            for (module.items) |*module_item| {
                try canonicalizeItem(ctx, @constCast(module_item));
            }

            // Restore previous context
            ctx.current_module = prev_module;
            ctx.base_file = prev_base;
        },
        .event_decl => |*event| {
            try canonicalizePath(ctx, @constCast(&event.path));
            try normalizeShapeFields(ctx, @constCast(&event.input));
            for (event.branches) |*branch| {
                const b = @constCast(branch);
                try normalizeShapeFields(ctx, &b.payload);
                try normalizeTypeStringOpt(ctx, &b.resume_type);
                try normalizeTypeStringOpt(ctx, &b.resume_phantom);
                if (b.resume_arms) |arms| {
                    for (arms) |*arm| {
                        const a = @constCast(arm);
                        try normalizeTypeStringOpt(ctx, &a.type);
                        try normalizeTypeStringOpt(ctx, &a.phantom);
                    }
                }
            }
            try normalizeTypeStringOpt(ctx, &event.return_type);
            try normalizeTypeStringOpt(ctx, &event.return_phantom);
        },
        .proc_decl => |*proc| {
            try canonicalizePath(ctx, @constCast(&proc.path));
        },
        .flow => |*flow| {
            if (flow.impl_of) |*impl_path| {
                try canonicalizePath(ctx, @constCast(impl_path));
            }
            try canonicalizeFlow(ctx, @constCast(flow));
        },
        .immediate_impl => |*ii| {
            try canonicalizePath(ctx, @constCast(&ii.event_path));
            try canonicalizeBranchConstructor(ctx, @constCast(&ii.value));
        },
        .event_tap => |*tap| {
            // Update tap's module to use logical name for consistency with event paths
            tap.module = ctx.current_module;

            if (tap.source) |*source| {
                try canonicalizePath(ctx, @constCast(source));
            }
            if (tap.destination) |*dest| {
                try canonicalizePath(ctx, @constCast(dest));
            }

            // Canonicalize continuations
            for (tap.continuations) |*cont| {
                try canonicalizeContinuation(ctx, @constCast(cont));
            }
        },
        .label_decl => |*label| {
            for (label.continuations) |*cont| {
                try canonicalizeContinuation(ctx, @constCast(cont));
            }
        },
        .import_decl, .host_line, .comment, .host_type_decl, .parse_error => {
            // No paths to canonicalize
        },
        .native_loop => |*loop| {
            try canonicalizePath(ctx, @constCast(&loop.event_path));
            if (loop.body_source) |*bs| {
                try canonicalizePath(ctx, @constCast(bs));
            }
            if (loop.optimized_from) |*of| {
                try canonicalizePath(ctx, @constCast(of));
            }
        },
        .fused_event => |*fused| {
            try canonicalizePath(ctx, @constCast(&fused.event_path));
            for (fused.source_events) |*se| {
                try canonicalizePath(ctx, @constCast(se));
            }
        },
        .inlined_event => |*inlined| {
            try canonicalizePath(ctx, @constCast(&inlined.event_path));
            try canonicalizePath(ctx, @constCast(&inlined.inlined_from));
        },
        .inline_code, .facet_decl => {
            // No paths to canonicalize - raw code string / transform-produced
            // declaration whose name+module are already canonical
        },
    }
}

fn canonicalizeFlow(ctx: *Context, flow: *ast.Flow) !void {
    try canonicalizeInvocation(ctx, @constCast(flow.inv()));

    for (flow.body.continuations) |*cont| {
        try canonicalizeContinuation(ctx, @constCast(cont));
    }
}

fn canonicalizeContinuation(ctx: *Context, cont: *ast.Continuation) CanonicalizeError!void {
    // Canonicalize step if present
    if (cont.node) |*step| {
        try canonicalizeStep(ctx, @constCast(step));
    }

    // Recursively canonicalize nested continuations
    for (cont.continuations) |*nested| {
        try canonicalizeContinuation(ctx, @constCast(nested));
    }
}

fn canonicalizeStep(ctx: *Context, step: *ast.Step) CanonicalizeError!void {
    switch (step.*) {
        .invocation => |*inv| {
            try canonicalizeInvocation(ctx, @constCast(inv));
        },
        .label_with_invocation => |*lwi| {
            try canonicalizeInvocation(ctx, @constCast(&lwi.invocation));
        },
        .branch_constructor => |*bc| {
            try canonicalizeBranchConstructor(ctx, @constCast(bc));
        },
        .conditional_block => |*cb| {
            for (cb.nodes) |*inner_step| {
                try canonicalizeStep(ctx, @constCast(inner_step));
            }
        },
        .label_apply, .label_jump, .terminal, .metatype_binding, .inline_code, .expression => {
            // No paths to canonicalize
            // metatype_binding contains canonical event names as strings, not DottedPaths
            // inline_code and expression are raw Zig source, no Koru paths
        },
        .foreach => |*fe| {
            // Recursively canonicalize all branches
            for (fe.branches) |*branch| {
                for (branch.body) |*cont| {
                    try canonicalizeContinuation(ctx, @constCast(cont));
                }
            }
        },
        .conditional => |*cond| {
            // Recursively canonicalize all branches
            for (cond.branches) |*branch| {
                for (branch.body) |*cont| {
                    try canonicalizeContinuation(ctx, @constCast(cont));
                }
            }
        },
        .switch_result => |*sr| {
            // Recursively canonicalize all branches
            for (sr.branches) |*branch| {
                for (branch.body) |*cont| {
                    try canonicalizeContinuation(ctx, @constCast(cont));
                }
            }
        },
        .assignment => {
            // Assignment contains field names and expressions as strings
            // No paths to canonicalize
        },
    }
}

fn canonicalizeInvocation(ctx: *Context, inv: *ast.Invocation) !void {
    try canonicalizePath(ctx, @constCast(&inv.path));

    for (inv.args) |*arg| {
        try canonicalizeArg(ctx, @constCast(arg));
    }
}

fn canonicalizeArg(ctx: *Context, arg: *ast.Arg) !void {
    _ = ctx;
    _ = arg;
    // Args contain string values, not paths
}

fn canonicalizeBranchConstructor(ctx: *Context, bc: *ast.BranchConstructor) !void {
    _ = ctx;
    _ = bc;
    // Branch constructors contain fields with string types
    // No paths to canonicalize currently
}

/// The core canonicalization logic - qualify a DottedPath if needed
fn canonicalizePath(ctx: *Context, path: *ast.DottedPath) !void {
    // If already qualified, first try to rewrite the spelling to the ONE
    // logical name its module is emitted under (identity, not spelling —
    // 230_008). Unresolved qualifiers fall through to the `/` -> `.`
    // separator normalize, the central safety net: every path flows through
    // here, so a `/` qualifier left by any parse path (subflow-impl RHS,
    // continuations, nested module refs) is caught.
    if (path.module_qualifier) |mq| {
        if (resolveModuleSpelling(ctx, mq)) |logical| {
            if (!std.mem.eql(u8, logical, mq)) {
                ctx.allocator.free(mq);
                path.module_qualifier = try ctx.allocator.dupe(u8, logical);
            }
            return;
        }
        for (@constCast(mq)) |*c| {
            if (c.* == '/') c.* = '.';
        }
        return;
    }

    // Use the current module name as qualifier
    // ALL modules use their actual filename-derived name (e.g., "input", "std.compiler")
    // This enables circular imports and consistent naming across the codebase
    const qualifier = ctx.current_module;

    // Allocate and set the qualifier
    path.module_qualifier = try ctx.allocator.dupe(u8, qualifier);

    if (DEBUG) log.debug("CANONICALIZE: Qualified path '{s}' → '{s}:{s}'\n", .{
        path.segments[0],
        qualifier,
        path.segments[0],
    });
}

