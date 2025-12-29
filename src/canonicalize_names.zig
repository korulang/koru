const std = @import("std");
const DEBUG = false;  // Set to true for verbose logging
const ast = @import("ast");

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

pub fn canonicalize(program: *ast.Program, allocator: std.mem.Allocator) !void {
    if (DEBUG) std.debug.print("CANONICALIZE: Starting full AST canonicalization\n", .{});
    if (DEBUG) std.debug.print("CANONICALIZE: Main module: '{s}'\n", .{program.main_module_name});

    var ctx = Context{
        .main_module = program.main_module_name,
        .current_module = program.main_module_name,
        .allocator = allocator,
    };

    // Walk all items and canonicalize their paths
    for (program.items) |*item| {
        try canonicalizeItem(&ctx, @constCast(item));
    }

    if (DEBUG) std.debug.print("CANONICALIZE: Completed successfully\n", .{});
}

const Context = struct {
    main_module: []const u8,      // The entry module name (e.g., "input")
    current_module: []const u8,   // Current module context as we walk
    allocator: std.mem.Allocator,
};

fn canonicalizeItem(ctx: *Context, item: *ast.Item) !void {
    switch (item.*) {
        .module_decl => |*module| {
            if (DEBUG) std.debug.print("CANONICALIZE: Entering module '{s}' (logical: '{s}')\n", .{module.canonical_path, module.logical_name});

            // Save previous module context
            const prev_module = ctx.current_module;
            // Use logical_name for module qualifier to match emitted code structure
            ctx.current_module = module.logical_name;

            // Recursively canonicalize module items
            for (module.items) |*module_item| {
                try canonicalizeItem(ctx, @constCast(module_item));
            }

            // Restore previous context
            ctx.current_module = prev_module;
        },
        .event_decl => |*event| {
            try canonicalizePath(ctx, @constCast(&event.path));
        },
        .proc_decl => |*proc| {
            try canonicalizePath(ctx, @constCast(&proc.path));

            // Canonicalize inline flows
            for (proc.inline_flows) |*flow| {
                try canonicalizeFlow(ctx, @constCast(flow));
            }
        },
        .flow => |*flow| {
            try canonicalizeFlow(ctx, @constCast(flow));
        },
        .subflow_impl => |*subflow| {
            try canonicalizePath(ctx, @constCast(&subflow.event_path));

            switch (subflow.body) {
                .flow => |*flow| {
                    try canonicalizeFlow(ctx, @constCast(flow));
                },
                .immediate => |*bc| {
                    try canonicalizeBranchConstructor(ctx, @constCast(bc));
                },
            }
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
        .import_decl, .host_line, .host_type_decl, .parse_error => {
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
        .inline_code => {
            // No paths to canonicalize - just raw code string
        },
    }
}

fn canonicalizeFlow(ctx: *Context, flow: *ast.Flow) !void {
    try canonicalizeInvocation(ctx, @constCast(&flow.invocation));

    for (flow.continuations) |*cont| {
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
        .deref => |*d| {
            // Deref might have args with nested invocations
            if (d.args) |args| {
                for (args) |*arg| {
                    try canonicalizeArg(ctx, @constCast(arg));
                }
            }
        },
        .label_apply, .label_jump, .terminal, .metatype_binding, .inline_code => {
            // No paths to canonicalize
            // metatype_binding contains canonical event names as strings, not DottedPaths
            // inline_code is raw Zig code, no Koru paths
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
        .capture => |*cap| {
            // Recursively canonicalize all branches
            for (cap.branches) |*branch| {
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
    // If already qualified, nothing to do
    if (path.module_qualifier != null) {
        return;
    }

    // Use the current module name as qualifier
    // ALL modules use their actual filename-derived name (e.g., "input", "std.compiler")
    // This enables circular imports and consistent naming across the codebase
    const qualifier = ctx.current_module;

    // Allocate and set the qualifier
    path.module_qualifier = try ctx.allocator.dupe(u8, qualifier);

    if (DEBUG) std.debug.print("CANONICALIZE: Qualified path '{s}' → '{s}:{s}'\n", .{
        path.segments[0],
        qualifier,
        path.segments[0],
    });
}
