const std = @import("std");
const errors = @import("errors");

// Core AST node types

// Expression types for when clauses and proc arguments
pub const Expression = struct {
    node: ExprNode,
    
    pub fn deinit(self: *Expression, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        allocator.destroy(self);
    }
};

pub const ExprNode = union(enum) {
    literal: Literal,
    identifier: []const u8,
    binary: BinaryOp,
    unary: UnaryOp,
    field_access: FieldAccess,
    grouped: *Expression,
    builtin_call: BuiltinCall,
    array_index: ArrayIndex,
    conditional: Conditional,
    function_call: FunctionCall,

    pub fn deinit(self: *ExprNode, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .literal => |*l| l.deinit(allocator),
            .identifier => |id| allocator.free(id),
            .binary => |*b| b.deinit(allocator),
            .unary => |*u| u.deinit(allocator),
            .field_access => |*f| f.deinit(allocator),
            .grouped => |g| {
                g.deinit(allocator);
            },
            .builtin_call => |*bc| bc.deinit(allocator),
            .array_index => |*ai| ai.deinit(allocator),
            .conditional => |*c| c.deinit(allocator),
            .function_call => |*fc| fc.deinit(allocator),
        }
    }
};

pub const Literal = union(enum) {
    number: []const u8,
    string: []const u8,
    boolean: bool,
    
    pub fn deinit(self: *Literal, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .number => |n| allocator.free(n),
            .string => |s| allocator.free(s),
            .boolean => {},
        }
    }
};

pub const BinaryOp = struct {
    op: BinaryOperator,
    left: *Expression,
    right: *Expression,
    
    pub fn deinit(self: *BinaryOp, allocator: std.mem.Allocator) void {
        self.left.deinit(allocator);
        self.right.deinit(allocator);
    }
};

pub const BinaryOperator = enum {
    add, subtract, multiply, divide, modulo,
    equal, not_equal, less, less_equal, greater, greater_equal,
    and_op, or_op,
    string_concat,
};

pub const UnaryOp = struct {
    op: UnaryOperator,
    operand: *Expression,
    
    pub fn deinit(self: *UnaryOp, allocator: std.mem.Allocator) void {
        self.operand.deinit(allocator);
    }
};

pub const UnaryOperator = enum {
    not, negate,
};

pub const FieldAccess = struct {
    object: *Expression,
    field: []const u8,

    pub fn deinit(self: *FieldAccess, allocator: std.mem.Allocator) void {
        self.object.deinit(allocator);
        allocator.free(self.field);
    }
};

pub const BuiltinCall = struct {
    name: []const u8, // "as", "intCast", etc.
    args: []const *Expression,

    pub fn deinit(self: *BuiltinCall, allocator: std.mem.Allocator) void {
        for (self.args) |arg| {
            arg.deinit(allocator);
        }
        allocator.free(self.args);
        allocator.free(self.name);
    }
};

pub const ArrayIndex = struct {
    object: *Expression,
    index: *Expression,

    pub fn deinit(self: *ArrayIndex, allocator: std.mem.Allocator) void {
        self.object.deinit(allocator);
        self.index.deinit(allocator);
    }
};

pub const Conditional = struct {
    condition: *Expression,
    then_expr: *Expression,
    else_expr: *Expression,

    pub fn deinit(self: *Conditional, allocator: std.mem.Allocator) void {
        self.condition.deinit(allocator);
        self.then_expr.deinit(allocator);
        self.else_expr.deinit(allocator);
    }
};

pub const FunctionCall = struct {
    callee: *Expression,
    args: []const *Expression,

    pub fn deinit(self: *FunctionCall, allocator: std.mem.Allocator) void {
        self.callee.deinit(allocator);
        for (self.args) |arg| {
            arg.deinit(allocator);
        }
        allocator.free(self.args);
    }
};

// EventRef represents a deferred event value
pub const EventRef = struct {
    // The finite set of possible events this ref could be
    candidates: []const DottedPath,
    // The input shape all candidates must accept
    input_shape: Shape,
    // The super-shape (union of all candidate outputs)
    output_shape: SuperShape,
};

// SuperShape represents the union of multiple event output shapes
pub const SuperShape = struct {
    branches: []const BranchVariant,
    
    pub const BranchVariant = struct {
        name: []const u8,
        payload: Shape,
        // Which candidate events have this branch
        sources: []const DottedPath,
    };
};

pub const Program = struct {
    items: []const Item,
    module_annotations: []const []const u8,  // Module-level annotations (e.g., ~[compiler])
    main_module_name: []const u8,  // Canonical name of the main module (e.g., "input" from input.kz)
    allocator: std.mem.Allocator,

    /// TypeRegistry for this program (opaque to avoid circular import with type_registry.zig)
    /// Cast to *TypeRegistry when needed. Enables transforms to do supplemental parsing.
    type_registry: ?*anyopaque = null,

    pub fn deinit(self: *Program) void {
        for (self.items) |*item| {
            var mutable_item = item.*;
            mutable_item.deinit(self.allocator);
        }
        self.allocator.free(@constCast(self.items));
        // Free module annotations
        for (self.module_annotations) |annotation| {
            self.allocator.free(annotation);
        }
        self.allocator.free(@constCast(self.module_annotations));
        // Free main module name
        self.allocator.free(@constCast(self.main_module_name));
    }

    /// Check if this AST contains any parse errors
    /// Used to determine if the AST can be compiled or is IDE-only
    pub fn hasParseErrors(self: *const Program) bool {
        for (self.items) |*item| {
            if (item.* == .parse_error) return true;
        }
        return false;
    }
};

pub const HostLine = struct {
    content: []const u8,

    // FOUNDATIONAL: Every item knows where it came from
    location: errors.SourceLocation = .{ .file = "generated", .line = 0, .column = 0 },
    module: []const u8,

    pub fn deinit(self: *HostLine, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        allocator.free(self.module);
    }
};

pub const ModuleDecl = struct {
    logical_name: []const u8,      // The name used in code (e.g., "io", "math")
    canonical_path: []const u8,    // Full resolved path to the module file
    items: []const Item,                 // All items in this module
    is_system: bool,                // True for compiler/stdlib modules (skip in user code generation)
    annotations: []const []const u8 = &[_][]const u8{},  // Module annotations (e.g., [comptime|runtime])

    // FOUNDATIONAL: Every item knows where it came from
    location: errors.SourceLocation = .{ .file = "generated", .line = 0, .column = 0 },
    // Note: ModuleDecl uses canonical_path as its "module" identifier

    pub fn deinit(self: *ModuleDecl, allocator: std.mem.Allocator) void {
        allocator.free(self.logical_name);
        allocator.free(self.canonical_path);
        for (self.items) |*item| {
            var mutable_item = item.*;
            mutable_item.deinit(allocator);
        }
        allocator.free(@constCast(self.items));
        // Free module annotations
        for (self.annotations) |annotation| {
            allocator.free(annotation);
        }
        allocator.free(@constCast(self.annotations));
    }
};

/// ParseErrorNode represents a parse error embedded in the AST
/// This allows lenient parsing mode to continue past errors while preserving
/// the error location and context for IDE tooling
pub const ParseErrorNode = struct {
    error_code: errors.ErrorCode,
    message: []const u8,
    location: errors.SourceLocation = .{ .file = "generated", .line = 0, .column = 0 },
    raw_text: []const u8,  // The source text that failed to parse
    hint: ?[]const u8,

    pub fn deinit(self: *ParseErrorNode, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        allocator.free(self.raw_text);
        if (self.hint) |h| allocator.free(h);
    }
};

pub const Item = union(enum) {
    // === SOURCE-LEVEL NODES (created by parser) ===
    module_decl: ModuleDecl,
    event_decl: EventDecl,
    proc_decl: ProcDecl,
    flow: Flow,
    event_tap: EventTap,
    label_decl: LabelDecl,
    immediate_impl: ImmediateImpl,
    import_decl: ImportDecl,
    host_line: HostLine,
    host_type_decl: HostTypeDecl,
    parse_error: ParseErrorNode,

    // === IR NODES (created by optimizer/transforms - backend agnostic!) ===
    native_loop: NativeLoop,        // Recursive events → native for/while loops
    fused_event: FusedEvent,        // Pure event chains → single fused handler
    inlined_event: InlinedEvent,    // Small events → inlined at callsite
    inline_code: InlineCode,        // Template-generated code → emit verbatim at call site

    pub fn deinit(self: *Item, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .module_decl => |*m| m.deinit(allocator),
            .host_line => |*line| line.deinit(allocator),
            .event_decl => |*e| e.deinit(allocator),
            .proc_decl => |*p| p.deinit(allocator),
            .flow => |*f| f.deinit(allocator),
            .event_tap => |*t| t.deinit(allocator),
            .label_decl => |*l| l.deinit(allocator),
            .immediate_impl => |*ii| ii.deinit(allocator),
            .import_decl => |*i| i.deinit(allocator),
            .host_type_decl => |*h| h.deinit(allocator),
            .parse_error => |*pe| pe.deinit(allocator),

            // IR nodes
            .native_loop => |*nl| nl.deinit(allocator),
            .fused_event => |*fe| fe.deinit(allocator),
            .inlined_event => |*ie| ie.deinit(allocator),
            .inline_code => |*ic| ic.deinit(allocator),
        }
    }
};

pub const EventDecl = struct {
    path: DottedPath,
    input: Shape,
    branches: []const Branch,
    is_public: bool = false,  // Whether this event is public (can be imported)
    is_implicit_flow: bool = false,  // Whether this event uses implicit flow parameter
    annotations: []const []const u8 = &[_][]const u8{},  // Event annotations like [pure|fusible|abstract]

    // Purity tracking (computed from proc implementations)
    is_pure: bool = false,  // True if ALL proc implementations are pure
    is_transitively_pure: bool = false,  // True if ALL proc implementations are transitively pure

    // FOUNDATIONAL: Every item knows where it came from
    location: errors.SourceLocation = .{ .file = "generated", .line = 0, .column = 0 },
    module: []const u8,  // Canonical module path (e.g., "input", "lib/fs")

    /// Returns true if this event is comptime-only (should not be emitted to backend)
    /// Comptime-only events have Program, Source, or Expression parameters
    pub fn isComptimeOnly(self: *const EventDecl) bool {
        for (self.input.fields) |field| {
            if (field.is_source) {
                return true;
            }
            if (field.is_expression) {
                return true;
            }
            // Check for Program type (which is an alias for Program)
            if (std.mem.eql(u8, field.type, "Program") or
                std.mem.eql(u8, field.type, "Program")) {
                return true;
            }
        }
        return false;
    }

    /// Returns true if this event has a specific annotation
    /// Example: event.hasAnnotation("norun") checks for ~[norun] annotation
    pub fn hasAnnotation(self: *const EventDecl, annotation: []const u8) bool {
        for (self.annotations) |ann| {
            if (std.mem.eql(u8, ann, annotation)) return true;
        }
        return false;
    }

    pub fn deinit(self: *EventDecl, allocator: std.mem.Allocator) void {
        self.path.deinit(allocator);
        self.input.deinit(allocator);
        for (self.branches) |*branch| {
            var mutable_branch = branch.*;
            mutable_branch.deinit(allocator);
        }
        allocator.free(@constCast(self.branches));
        for (self.annotations) |ann| {
            allocator.free(ann);
        }
        allocator.free(@constCast(self.annotations));
        allocator.free(self.module);
    }
};

pub const HostTypeDecl = struct {
    name: []const u8,              // e.g., "Transition", "CustomMetrics"
    shape: Shape,                  // Fields of the type

    pub fn deinit(self: *HostTypeDecl, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.shape.deinit(allocator);
    }
};

pub const ProcDecl = struct {
    path: DottedPath,
    body: []const u8, // Opaque code (language determined by target)
    annotations: []const []const u8 = &[_][]const u8{}, // Proc annotations like [pure|async]
    target: ?[]const u8 = null, // Language target: "gpu", "js", "python", null = Zig
    is_impl: bool = false,  // True if event_path has module qualifier (cross-module implementation)
    is_public: bool = false, // True if declared with ~pub proc

    // Purity tracking
    is_pure: bool = false,  // True if marked ~[pure] or inline-only pattern
    is_transitively_pure: bool = false,  // True if pure AND all called events are transitively pure

    // FOUNDATIONAL: Every item knows where it came from
    location: errors.SourceLocation = .{ .file = "generated", .line = 0, .column = 0 },
    module: []const u8,

    pub fn deinit(self: *ProcDecl, allocator: std.mem.Allocator) void {
        self.path.deinit(allocator);
        allocator.free(self.body);
        for (self.annotations) |ann| {
            allocator.free(ann);
        }
        allocator.free(@constCast(self.annotations));
        if (self.target) |t| allocator.free(t);
        allocator.free(self.module);
    }
};

/// Source represents captured source code with location and scope
/// This is the foundation for universal metaprogramming in Koru
/// Used for tests, macros, templates, embedded DSLs, etc.
pub const Source = struct {
    text: []const u8,                // Raw source text
    location: errors.SourceLocation = .{ .file = "generated", .line = 0, .column = 0 },  // Where this Source started in original file
    scope: CapturedScope,             // Available bindings at invocation site
    phantom_type: ?[]const u8 = null, // Phantom type annotation from call site (e.g., "HTML", "SQL")

    pub fn deinit(self: *Source, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.scope.deinit(allocator);
        if (self.phantom_type) |pt| {
            allocator.free(pt);
        }
    }
};

/// InvocationMeta provides metadata about an invocation for comptime introspection
/// This allows comptime procs to inspect their call site (annotations, location, etc.)
/// Used for conditional compilation, build configurations, and meta-programming
pub const InvocationMeta = struct {
    path: []const u8,                    // Full path like "std.build:variants"
    module: ?[]const u8,                 // Module qualifier "std.build" or null
    event_name: []const u8,              // Just the event name "variants"
    annotations: []const []const u8,     // Flow annotations like ["release"], ["debug"]
    location: errors.SourceLocation,     // Where it was invoked

    pub fn deinit(self: *InvocationMeta, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.module) |m| allocator.free(m);
        allocator.free(self.event_name);
        for (self.annotations) |ann| {
            allocator.free(ann);
        }
        allocator.free(@constCast(self.annotations));
    }
};

/// CapturedExpression represents a captured Zig expression with its scope
/// Used for Expression parameters that need access to bindings at the call site
pub const CapturedExpression = struct {
    text: []const u8,                 // The expression text (e.g., "data.value > 10")
    location: errors.SourceLocation = .{ .file = "generated", .line = 0, .column = 0 },  // Where this expression appeared in source
    scope: CapturedScope,             // Available bindings at invocation site

    pub fn deinit(self: *CapturedExpression, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.scope.deinit(allocator);
    }
};

/// CapturedScope represents bindings available at a Source block invocation
/// Enables lexical capture for metaprogramming
pub const CapturedScope = struct {
    bindings: []const ScopeBinding,

    pub fn deinit(self: *CapturedScope, allocator: std.mem.Allocator) void {
        for (self.bindings) |*binding| {
            var mutable_binding = binding.*;
            mutable_binding.deinit(allocator);
        }
        allocator.free(@constCast(self.bindings));
    }
};

/// ScopeBinding represents a single captured variable/binding
///
/// IMPORTANT: The `type` field is set to "unknown" by the parser.
/// To resolve the actual type, use ast_functional.resolveBindingType()
/// which walks the AST to find the event+branch that produced this binding.
///
/// Type resolution must happen via AST-walking because:
/// 1. The type depends on what event+branch produced the value
/// 2. That event might itself be a transform that modifies the AST
/// 3. Transforms run in source order, so we see the transformed AST
///
/// Example:
///   ~getUserData() | data u |> renderHTML [HTML]{ $[u.name] }
///
///   The binding "u" has type="unknown" at parse time.
///   At transform time, call resolveBindingType() to discover:
///   - event_name: "getUserData"
///   - branch_name: "data"
///   - fields: [{ name: "name", type: "[]const u8" }, { name: "age", type: "i32" }]
pub const ScopeBinding = struct {
    name: []const u8,        // Variable name (e.g., "userName", "u")
    type: []const u8,        // Type string - set to "unknown" by parser, resolve via ast_functional.resolveBindingType()
    value_ref: []const u8,   // How to reference it (e.g., "userName", "u")

    pub fn deinit(self: *ScopeBinding, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.type);
        allocator.free(self.value_ref);
    }
};

pub const Flow = struct {
    invocation: Invocation,
    continuations: []const Continuation,
    annotations: []const []const u8 = &[_][]const u8{},  // Flow annotations like [depends_on("a", "b")]
    pre_label: ?[]const u8 = null,   // Label before invocation (#label event)
    post_label: ?[]const u8 = null,  // Label after invocation (event #label)
    super_shape: ?SuperShape = null, // For inline flows with branch constructors

    // Zero-overhead control flow support:
    // If set, emitter outputs this code directly instead of generating handler call + switch.
    // Used by ~if, ~for transforms to emit literal Zig control flow.
    // The invocation/continuations are still present for metadata but not used for emission.
    inline_body: ?[]const u8 = null,

    // Preamble code: emitted BEFORE processing continuations (does NOT skip continuations)
    // Used by ~const to emit declaration while letting continuations be processed normally.
    // Unlike inline_body which replaces everything, preamble_code is additive.
    preamble_code: ?[]const u8 = null,

    // Purity tracking
    is_pure: bool = true,  // Flows are always locally pure (just composition)
    is_transitively_pure: bool = false,  // Default false until purity checker walks and verifies

    // Subflow implementation context (null for top-level flows)
    // When set, this flow implements the named event.
    impl_of: ?DottedPath = null,

    // True if the source syntax had a colon (cross-module override: ~mod:event = ...).
    // MUST be stored at parse time, before canonicalize_names adds module qualifiers
    // to all paths (which would make impl_of.module_qualifier non-null for locals too).
    is_impl: bool = false,

    // FOUNDATIONAL: Every item knows where it came from
    location: errors.SourceLocation = .{ .file = "generated", .line = 0, .column = 0 },
    module: []const u8,

    /// Returns true if this flow is a cross-module implementation override.
    /// Uses the stored is_impl flag set at parse time (pre-canonicalization).
    pub fn isImpl(self: *const Flow) bool {
        return self.is_impl;
    }

    pub fn deinit(self: *Flow, allocator: std.mem.Allocator) void {
        self.invocation.deinit(allocator);
        for (self.continuations) |*cont| {
            var mutable_cont = cont.*;
            mutable_cont.deinit(allocator);
        }
        allocator.free(@constCast(self.continuations));
        for (self.annotations) |ann| {
            allocator.free(ann);
        }
        allocator.free(@constCast(self.annotations));
        if (self.pre_label) |l| allocator.free(l);
        if (self.post_label) |l| allocator.free(l);
        if (self.inline_body) |ib| allocator.free(ib);
        if (self.super_shape) |*ss| {
            for (ss.branches) |*branch| {
                allocator.free(branch.name);
                var mutable_payload = branch.payload;
                mutable_payload.deinit(allocator);
                for (branch.sources) |source| {
                    var mutable_source = source;
                    mutable_source.deinit(allocator);
                }
                allocator.free(@constCast(branch.sources));
            }
            allocator.free(@constCast(ss.branches));
        }
        if (self.impl_of) |*io| {
            var mutable_io = io.*;
            mutable_io.deinit(allocator);
        }
        allocator.free(self.module);
    }
};

pub const EventTap = struct {
    source: ?DottedPath,      // null = wildcard (*)
    destination: ?DottedPath,  // null = wildcard (*)
    continuations: []const Continuation,
    is_input_tap: bool,       // true = before event (input tap), false = after event (output tap)
    annotations: []const []const u8 = &.{},  // Annotations like [debug], [trace], etc.

    // FOUNDATIONAL: Every item knows where it came from
    location: errors.SourceLocation = .{ .file = "generated", .line = 0, .column = 0 },
    module: []const u8,

    pub fn deinit(self: *EventTap, allocator: std.mem.Allocator) void {
        if (self.source) |*s| {
            var mutable_s = s.*;
            mutable_s.deinit(allocator);
        }
        if (self.destination) |*d| {
            var mutable_d = d.*;
            mutable_d.deinit(allocator);
        }
        for (self.continuations) |*cont| {
            var mutable_cont = cont.*;
            mutable_cont.deinit(allocator);
        }
        allocator.free(@constCast(self.continuations));
        for (self.annotations) |ann| {
            allocator.free(ann);
        }
        allocator.free(@constCast(self.annotations));
        allocator.free(self.module);
    }
};

pub const LabelDecl = struct {
    name: []const u8,
    continuations: []const Continuation,

    pub fn deinit(self: *LabelDecl, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.continuations) |*cont| {
            var mutable_cont = cont.*;
            mutable_cont.deinit(allocator);
        }
        allocator.free(@constCast(self.continuations));
    }
};

// Immediate branch return for a subflow implementation (no flow body).
// Used for constants, stubs, defaults — e.g. ~player:load = loaded { id: id, gold: 100 }
// The flow-based case is now handled by Flow with impl_of set.
pub const ImmediateImpl = struct {
    event_path: DottedPath,          // Which event this implements
    value: BranchConstructor,        // The immediate branch return value
    annotations: []const []const u8 = &[_][]const u8{},

    // FOUNDATIONAL: Every item knows where it came from
    location: errors.SourceLocation = .{ .file = "generated", .line = 0, .column = 0 },
    module: []const u8,

    // Stored at parse time: true if event_path had module qualifier before canonicalization
    is_impl: bool = false,

    pub fn isImpl(self: *const ImmediateImpl) bool {
        return self.is_impl;
    }

    pub fn deinit(self: *ImmediateImpl, allocator: std.mem.Allocator) void {
        self.event_path.deinit(allocator);
        var mutable_value = self.value;
        mutable_value.deinit(allocator);
        for (self.annotations) |ann| {
            allocator.free(ann);
        }
        allocator.free(@constCast(self.annotations));
        allocator.free(self.module);
    }
};

pub const ImportDecl = struct {
    path: []const u8,  // The path to import (e.g., "koru_std/io" or "lib/events")
    local_name: ?[]const u8,  // Optional local name/alias (e.g., "calc" in ~import calc = "math")

    // FOUNDATIONAL: Every item knows where it came from
    location: errors.SourceLocation = .{ .file = "generated", .line = 0, .column = 0 },
    module: []const u8,

    pub fn deinit(self: *ImportDecl, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.local_name) |n| allocator.free(n);
        allocator.free(self.module);
    }
};

pub const DottedPath = struct {
    module_qualifier: ?[]const u8 = null,  // "http" if http:foo, null if local
    segments: []const []const u8,

    pub fn deinit(self: *DottedPath, allocator: std.mem.Allocator) void {
        if (self.module_qualifier) |mq| {
            allocator.free(mq);
        }
        for (self.segments) |seg| {
            allocator.free(seg);
        }
        allocator.free(@constCast(self.segments));
    }

    pub fn format(
        self: DottedPath,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        if (self.module_qualifier) |mq| {
            try writer.writeAll(mq);
            try writer.writeAll(":");
        }
        for (self.segments, 0..) |seg, i| {
            if (i > 0) try writer.writeAll(".");
            try writer.writeAll(seg);
        }
    }
};

pub const Shape = struct {
    fields: []const Field,
    is_wildcard: bool = false, // { * } - has bindable payload, shape unspecified

    pub fn deinit(self: *Shape, allocator: std.mem.Allocator) void {
        // Deinit individual fields (they're heap-allocated even in const arrays)
        for (self.fields) |*field| {
            var mutable_field = field.*;
            mutable_field.deinit(allocator);
        }
        // Free the fields array (cast away const - safe because we allocated it)
        // Note: For PROGRAM_AST, this will be called via ast_functional.maybeDeinit()
        // which checks if this is the stack-allocated AST before calling deinit
        allocator.free(@constCast(self.fields));
    }
};

pub const Field = struct {
    name: []const u8,
    type: []const u8, // Zig type as string (phantom states/tags stripped)
    module_path: ?[]const u8 = null, // Module path for cross-module types (e.g., "test_lib.user" from "test_lib.user:User")
    phantom: ?[]const u8 = null, // Opaque phantom string - analyzers interpret
    is_source: bool = false, // For Source type - captures raw syntax
    is_file: bool = false, // For File type - compile-time file read (not embedded)
    is_embed_file: bool = false, // For EmbedFile type - embeds file contents in binary
    is_expression: bool = false, // For Expression type - captures Zig expressions verbatim
    is_invocation_meta: bool = false, // For InvocationMeta type - provides call site metadata
    expression: ?*Expression = null, // For branch constructors in procs - parsed expression value
    expression_str: ?[]const u8 = null, // Raw expression string (before parsing)
    owns_expression: bool = false, // Whether this field owns and should free the expression

    pub fn deinit(self: *Field, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.type);
        if (self.module_path) |mp| allocator.free(mp);
        if (self.phantom) |p| allocator.free(p);
        if (self.expression) |expr| {
            if (self.owns_expression) {
                expr.deinit(allocator);
                allocator.destroy(expr);
            }
        }
        if (self.expression_str) |expr_str| allocator.free(expr_str);
    }
};

pub const Branch = struct {
    name: []const u8,
    payload: Shape,
    is_deferred: bool = false,  // Marks &-branches that return event refs
    is_optional: bool = false,  // Marks ?-branches that don't need to be handled
    annotations: []const []const u8 = &[_][]const u8{},  // Branch annotations like [mutable]

    pub fn deinit(self: *Branch, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.payload.deinit(allocator);
        for (self.annotations) |annotation| {
            allocator.free(annotation);
        }
        allocator.free(self.annotations);
    }
};

/// NamedBranch - uniform structure for control flow branches in AST nodes
///
/// This type enables the shape checker to validate branches uniformly without
/// node-type awareness. Instead of specialized fields like `then_body`, `else_body`,
/// control flow nodes use `branches: []const NamedBranch` where the branch name
/// is preserved and visible to validation.
///
/// Examples:
///   - Conditional: branches = [{ name: "then", body: [...] }, { name: "else", body: [...] }]
///   - Foreach: branches = [{ name: "each", body: [...] }, { name: "done", body: [...] }]
///   - Capture: branches = [{ name: "as", body: [...] }, { name: "captured", body: [...] }]
pub const NamedBranch = struct {
    name: []const u8,              // Branch name: "then", "else", "each", "done", "as", etc.
    body: []const Continuation,    // The continuations in this branch
    binding: ?[]const u8 = null,   // Optional binding for the branch (e.g., "item" in | each item |>)
    is_optional: bool = false,     // Marks branches that don't need to be handled (like `for`'s `done`)
    annotations: []const []const u8 = &.{}, // Branch annotations (e.g., [@scope] for loop bodies)

    pub fn deinit(self: *NamedBranch, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.body) |*cont| {
            var mutable_cont = cont.*;
            mutable_cont.deinit(allocator);
        }
        allocator.free(@constCast(self.body));
        if (self.binding) |b| allocator.free(b);
        for (self.annotations) |ann| allocator.free(ann);
        if (self.annotations.len > 0) allocator.free(@constCast(self.annotations));
    }

    /// Check if this branch has a specific annotation
    pub fn hasAnnotation(self: *const NamedBranch, annotation: []const u8) bool {
        for (self.annotations) |ann| {
            if (std.mem.eql(u8, ann, annotation)) return true;
        }
        return false;
    }

    /// Find a branch by name in a slice of NamedBranch
    pub fn find(branches: []const NamedBranch, name: []const u8) ?*const NamedBranch {
        for (branches) |*branch| {
            if (std.mem.eql(u8, branch.name, name)) {
                return branch;
            }
        }
        return null;
    }

    /// Get the body of a named branch, or empty slice if not found
    pub fn getBody(branches: []const NamedBranch, name: []const u8) []const Continuation {
        if (find(branches, name)) |branch| {
            return branch.body;
        }
        return &[_]Continuation{};
    }

    /// Get the binding of a named branch, or null if not found
    pub fn getBinding(branches: []const NamedBranch, name: []const u8) ?[]const u8 {
        if (find(branches, name)) |branch| {
            return branch.binding;
        }
        return null;
    }
};

pub const Invocation = struct {
    path: DottedPath,
    args: []const Arg,
    annotations: []const []const u8 = &[_][]const u8{},  // Compiler pass tracking (e.g., @pass_ran("transform"))
    inserted_by_tap: bool = false,  // Marks invocations inserted by tap transformation
    from_opaque_tap: bool = false,  // Marks steps from opaque taps (to skip nested tap observations)
    source_module: []const u8 = "", // Module where this invocation appears
    variant: ?[]const u8 = null,  // Variant selector: "gpu", "naive", etc. for ~event|variant() calls

    // Transform replacement: if set, emitter outputs this code instead of calling the handler.
    // The path is kept for shape validation (the shape checker uses it to verify branch coverage).
    // This is the canonical location — Flow.inline_body delegates here.
    inline_body: ?[]const u8 = null,

    pub fn deinit(self: *Invocation, allocator: std.mem.Allocator) void {
        var mutable_path = self.path;
        mutable_path.deinit(allocator);
        for (self.args) |*arg| {
            var mutable_arg = arg.*;
            mutable_arg.deinit(allocator);
        }
        allocator.free(@constCast(self.args));
        for (self.annotations) |annotation| {
            allocator.free(@constCast(annotation));
        }
        allocator.free(@constCast(self.annotations));
        if (self.source_module.len > 0) {
            allocator.free(@constCast(self.source_module));
        }
        if (self.variant) |v| {
            allocator.free(@constCast(v));
        }
        if (self.inline_body) |ib| {
            allocator.free(ib);
        }
    }
};

pub const BindingType = enum {
    branch_payload,  // Normal: | ok o |> (o is branch payload)
    transition,      // Meta: | transition t |> (t is Transition struct)
};

pub const Continuation = struct {
    branch: []const u8,
    binding: ?[]const u8,
    binding_annotations: []const []const u8 = &[_][]const u8{}, // Annotations on binding (e.g., [mutable])
    binding_type: BindingType = .branch_payload,
    is_catchall: bool = false,  // True for |? catch-all continuations
    catchall_metatype: ?[]const u8 = null,  // "Transition", "Profile", or "Audit" for |? Transition t
    condition: ?[]const u8, // When clause condition (e.g., "o.status == 200")
    condition_expr: ?*Expression = null, // Parsed expression tree for when clause
    node: ?Node,  // The single node in this continuation (null for empty branches like | done |> _)
    indent: usize, // Track indentation level
    continuations: []const Continuation, // This node's branch continuations (e.g., | then |>, | else |>)

    // FOUNDATIONAL: Every item knows where it came from
    location: errors.SourceLocation = .{ .file = "generated", .line = 0, .column = 0 },

    pub fn deinit(self: *Continuation, allocator: std.mem.Allocator) void {
        allocator.free(self.branch);
        if (self.binding) |b| allocator.free(b);
        for (self.binding_annotations) |ann| {
            allocator.free(ann);
        }
        if (self.binding_annotations.len > 0) {
            allocator.free(self.binding_annotations);
        }
        if (self.catchall_metatype) |m| allocator.free(m);
        if (self.condition) |c| allocator.free(c);
        if (self.condition_expr) |e| e.deinit(allocator);
        if (self.node) |*n| {
            var mutable_node = n.*;
            mutable_node.deinit(allocator);
        }
        for (self.continuations) |*cont| {
            var mutable_cont = cont.*;
            mutable_cont.deinit(allocator);
        }
        allocator.free(@constCast(self.continuations));
    }
};

// =============================================================================
// Node - Unified execution type (formerly Step)
// =============================================================================
// All executable code in Koru flows through Node. This includes:
// - Event invocations
// - Control flow (foreach, conditional) with proper AST bodies
// - Label jumps and anchors
// - Branch constructors
//
// The key insight: Node represents "something that executes", while
// declarations (events, procs, modules) are separate static structure.
// =============================================================================
pub const Node = union(enum) {
    invocation: Invocation,
    label_apply: []const u8,  // Simple label without args (rare - mostly for compatibility)
    label_with_invocation: struct {  // Pattern: #label event(args) - DECLARATION ONLY
        label: []const u8,
        invocation: Invocation,
        is_declaration: bool = false,  // true for #label (anchor), false for @label (jump)
    },
    label_jump: struct {  // Pattern: @label(args) - JUMP with args
        label: []const u8,
        args: []const Arg,
    },
    terminal,  // The _ marker - flow terminates here
    deref: struct {
        target: []const u8,  // Variable name or branch name to dereference
        args: ?[]const Arg,        // Optional override arguments
    },
    branch_constructor: BranchConstructor,  // Inline branch construction
    conditional_block: struct {  // Conditional execution (for tap when clauses) - LEGACY
        condition: ?[]const u8,  // Condition string (e.g., "d.result > 50")
        condition_expr: ?*Expression,  // Parsed expression tree
        nodes: []const Node,  // Nodes to execute if condition is true
        inserted_by_tap: bool = false,  // Marks nodes inserted by tap transformation
        from_opaque_tap: bool = false,  // Marks nodes from opaque taps (to skip nested tap observations)
    },
    metatype_binding: struct {  // Binds a metatype (Profile/Transition/Audit) with transition metadata
        metatype: []const u8,   // "Profile", "Transition", or "Audit"
        binding: []const u8,    // Variable name to bind to (e.g., "p" in "| Profile p |>")
        source_event: []const u8,       // Canonical source event (e.g., "main:http.request")
        dest_event: ?[]const u8,        // Canonical dest event (null for terminal)
        branch: []const u8,             // Branch name (e.g., "done")
        inserted_by_tap: bool = false,  // Marks nodes inserted by tap transformation
        from_opaque_tap: bool = false,  // Marks nodes from opaque taps (to skip nested tap observations)
    },
    inline_code: []const u8,  // Verbatim Zig code to emit (from transforms like ~if, ~for) - LEGACY

    // ==========================================================================
    // NEW: Control flow nodes with proper AST bodies
    // These replace inline_code for ~if, ~for, ~each etc.
    // ==========================================================================

    /// Foreach iteration over a collection
    /// Used by std.seq:each and similar iteration constructs
    /// Uses uniform branches structure: [{ name: "each", body: [...], binding: "item" }, { name: "done", body: [...] }]
    foreach: struct {
        iterable: []const u8,           // Expression being iterated (e.g., "lines")
        element_type: ?[]const u8,      // Inferred element type (e.g., "[]const u8"), null if unknown
        branches: []const NamedBranch,  // Uniform branch structure ("each" with binding, optionally "done")
    },

    /// Conditional execution with proper AST bodies
    /// Replaces inline_code for ~if construct
    /// Uses uniform branches structure: [{ name: "then", body: [...] }, { name: "else", body: [...] }]
    conditional: struct {
        condition: []const u8,          // Condition expression string
        condition_expr: ?*Expression,   // Parsed expression tree (optional)
        branches: []const NamedBranch,  // Uniform branch structure (typically "then" and optionally "else")
    },

    /// State capture/accumulator with proper AST bodies
    /// Used by ~capture for pure state threading
    /// Uses uniform branches structure: [{ name: "as", body: [...], binding: "acc" }, { name: "done", body: [...], binding: "result" }]
    capture: struct {
        init_expr: []const u8,            // Initialization expression "{ sum: 0, max: 0 }"
        branches: []const NamedBranch,    // Uniform branch structure ("as" with current binding, "done" with final binding)
    },

    /// Union/result switch with proper AST bodies
    /// Used by transforms like query for switching on union result types
    /// Uses uniform branches structure: [{ name: "row", body: [...], binding: "r" }, { name: "empty", body: [...] }, ...]
    switch_result: struct {
        expression: []const u8,           // Inline code block that produces the union value
        branches: []const NamedBranch,    // Uniform branch structure (one per union variant)
    },

    /// Assignment node - generated by capture transform from `captured { }` blocks
    /// Represents "target = .{ .field1 = expr1, .field2 = expr2 }"
    assignment: struct {
        target: []const u8,       // The capture binding being assigned to
        fields: []const Field,    // Fields and their expression values
    },

    // Backwards compatibility alias - will be removed after full migration
    pub const Step = Node;

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .invocation => |*i| i.deinit(allocator),
            .label_apply => |l| allocator.free(l),
            .label_with_invocation => |*lwi| {
                allocator.free(lwi.label);
                lwi.invocation.deinit(allocator);
            },
            .label_jump => |*lj| {
                allocator.free(lj.label);
                for (lj.args) |*arg| {
                    var mutable_arg = arg.*;
                    mutable_arg.deinit(allocator);
                }
                allocator.free(@constCast(lj.args));
            },
            .terminal => {},  // Nothing to free
            .deref => |*d| {
                allocator.free(d.target);
                if (d.args) |args| {
                    for (args) |*arg| {
                        var mutable_arg = arg.*;
                        mutable_arg.deinit(allocator);
                    }
                    allocator.free(@constCast(args));
                }
            },
            .branch_constructor => |*bc| bc.deinit(allocator),
            .conditional_block => |*cb| {
                if (cb.condition) |c| allocator.free(c);
                if (cb.condition_expr) |e| e.deinit(allocator);
                for (cb.nodes) |*node| {
                    var mutable_node = node.*;
                    mutable_node.deinit(allocator);
                }
                allocator.free(@constCast(cb.nodes));
            },
            .metatype_binding => |*mb| {
                allocator.free(mb.metatype);
                allocator.free(mb.binding);
                allocator.free(mb.source_event);
                if (mb.dest_event) |dest| allocator.free(dest);
                allocator.free(mb.branch);
            },
            .inline_code => |code| allocator.free(code),
            .foreach => |*fe| {
                allocator.free(fe.iterable);
                if (fe.element_type) |et| allocator.free(et);
                for (fe.branches) |*branch| {
                    var mutable_branch = branch.*;
                    mutable_branch.deinit(allocator);
                }
                allocator.free(@constCast(fe.branches));
            },
            .conditional => |*cond| {
                allocator.free(cond.condition);
                if (cond.condition_expr) |e| e.deinit(allocator);
                for (cond.branches) |*branch| {
                    var mutable_branch = branch.*;
                    mutable_branch.deinit(allocator);
                }
                allocator.free(@constCast(cond.branches));
            },
            .capture => |*cap| {
                allocator.free(cap.init_expr);
                for (cap.branches) |*branch| {
                    var mutable_branch = branch.*;
                    mutable_branch.deinit(allocator);
                }
                allocator.free(@constCast(cap.branches));
            },
            .switch_result => |*sr| {
                allocator.free(sr.expression);
                for (sr.branches) |*branch| {
                    var mutable_branch = branch.*;
                    mutable_branch.deinit(allocator);
                }
                allocator.free(@constCast(sr.branches));
            },
            .assignment => |*asgn| {
                allocator.free(asgn.target);
                for (asgn.fields) |*field| {
                    var mutable_field = field.*;
                    mutable_field.deinit(allocator);
                }
                allocator.free(@constCast(asgn.fields));
            },
        }
    }
};

// Backwards compatibility alias - will be removed after full migration
pub const Step = Node;

pub const Arg = struct {
    name: []const u8,
    value: []const u8,
    source_value: ?*const Source = null,  // For Source arguments - holds text + location + scope (const in PROGRAM_AST)
    expression_value: ?*const CapturedExpression = null,  // For Expression arguments - holds text + location + scope

    pub fn deinit(self: *Arg, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
        if (self.source_value) |source| {
            // Cast away const for deallocation - safe because we allocated it
            var mutable_source = @constCast(source);
            mutable_source.deinit(allocator);
            allocator.destroy(mutable_source);
        }
        if (self.expression_value) |expr| {
            var mutable_expr = @constCast(expr);
            mutable_expr.deinit(allocator);
            allocator.destroy(mutable_expr);
        }
    }
};

pub const BranchConstructor = struct {
    branch_name: []const u8,
    fields: []const Field,  // Reuse Field type from Shape
    plain_value: ?[]const u8 = null, // For branches with a single plain value (not a struct)
    has_expressions: bool = false, // True if any field contains an expression (for procs)

    pub fn deinit(self: *BranchConstructor, allocator: std.mem.Allocator) void {
        allocator.free(self.branch_name);
        if (self.plain_value) |pv| {
            allocator.free(pv);
        }
        for (self.fields) |*field| {
            var mutable_field = field.*;
            mutable_field.deinit(allocator);
        }
        allocator.free(@constCast(self.fields));
    }
};

// ============================================================
// IR (Intermediate Representation) Nodes
// ============================================================
// These nodes are created by optimization passes and represent
// backend-agnostic semantic constructs. They sit between the
// source-level AST and target code generation.
//
// Why IR nodes?
// - Backend agnostic: Same IR emits to Zig, GLSL, JS, Python, etc.
// - Composable: Multiple optimization passes can operate on IR
// - Debuggable: Can inspect what optimizations were applied
// - Future-proof: New backends just need to emit IR nodes
//
// IR nodes are created by optimizer passes in koru_std/optimizations/

/// NativeLoop - IR node for loops
/// Represents a counted loop that can emit to any backend's loop syntax.
/// Created by detecting recursive event patterns (checker + label jumps).
pub const NativeLoop = struct {
    event_path: DottedPath,        // Which event does this implement?

    // Loop structure (semantic, not syntax-specific)
    variable: []const u8,          // Loop variable name (e.g., "i")
    start_expr: []const u8,        // Start value (e.g., "0")
    end_expr: []const u8,          // End condition (e.g., "bodies.len")
    step_expr: ?[]const u8 = null, // Step (e.g., "1", null = default increment)

    // Loop body
    body_code: []const u8,         // Inlined body code (backend-specific for now)
    body_source: ?DottedPath = null, // Original event/proc this was inlined from

    // Done/exit branch information (for continuation emission)
    // The branch name for the exit condition (e.g., "done", "finished", "complete")
    exit_branch_name: []const u8,
    // Maps exit branch fields to their values from the proc body
    // Example: [{field_name: "result", value_expr: "sum"}]
    done_field_values: []const FieldValue,

    // Loop style hints for backend
    style: LoopStyle,

    // Provenance tracking
    optimized_from: ?DottedPath = null,  // Original subflow that was transformed (event name)
    optimized_from_flow: ?*Flow = null,  // THE ACTUAL FLOW that was optimized (full context!)

    // FOUNDATIONAL: Every item knows where it came from
    location: errors.SourceLocation = .{ .file = "generated", .line = 0, .column = 0 },
    module: []const u8,

    pub const FieldValue = struct {
        field_name: []const u8,
        value_expr: []const u8,

        pub fn deinit(self: *FieldValue, allocator: std.mem.Allocator) void {
            allocator.free(self.field_name);
            allocator.free(self.value_expr);
        }
    };

    pub fn deinit(self: *NativeLoop, allocator: std.mem.Allocator) void {
        self.event_path.deinit(allocator);
        allocator.free(self.variable);
        allocator.free(self.start_expr);
        allocator.free(self.end_expr);
        if (self.step_expr) |step| allocator.free(step);
        allocator.free(self.body_code);
        if (self.body_source) |*bs| {
            var mutable_bs = bs.*;
            mutable_bs.deinit(allocator);
        }
        // Free exit_branch_name
        allocator.free(self.exit_branch_name);
        // Free done_field_values
        for (self.done_field_values) |*fv| {
            var mutable_fv = fv.*;
            mutable_fv.deinit(allocator);
        }
        allocator.free(@constCast(self.done_field_values));
        if (self.optimized_from) |*of| {
            var mutable_of = of.*;
            mutable_of.deinit(allocator);
        }
        // Free the original Flow if we own it
        if (self.optimized_from_flow) |flow_ptr| {
            flow_ptr.deinit(allocator);
            allocator.destroy(flow_ptr);
        }
        allocator.free(self.module);
    }
};

/// Loop style hints for code generation
pub const LoopStyle = enum {
    counted_up,      // for (start..end) |var|  (Zig) / for (int i = start; i < end; i++) (C)
    counted_down,    // Reverse iteration
    triangular,      // Nested loops with dependent bounds: for (i) for (i+1..n)
    while_style,     // Complex condition - emit as while loop
};

/// FusedEvent - IR node for event chain fusion
/// Represents multiple pure events fused into a single handler.
/// Created by detecting chains of pure event invocations.
pub const FusedEvent = struct {
    event_path: DottedPath,         // The fused event name

    // Fusion info
    source_events: []DottedPath,    // Original events that were fused [foo, bar, baz]
    fused_body: []const u8,         // The combined handler body

    // Input/output shapes (same as original event)
    input: Shape,
    branches: []const Branch,

    // Provenance
    provenance: []const u8,         // Human-readable: "fused from foo → bar → baz"

    // FOUNDATIONAL: Every item knows where it came from
    location: errors.SourceLocation = .{ .file = "generated", .line = 0, .column = 0 },
    module: []const u8,

    pub fn deinit(self: *FusedEvent, allocator: std.mem.Allocator) void {
        self.event_path.deinit(allocator);
        for (self.source_events) |*se| {
            var mutable_se = se.*;
            mutable_se.deinit(allocator);
        }
        allocator.free(self.source_events);
        allocator.free(self.fused_body);
        self.input.deinit(allocator);
        for (self.branches) |*branch| {
            var mutable_branch = branch.*;
            mutable_branch.deinit(allocator);
        }
        allocator.free(@constCast(self.branches));
        allocator.free(self.provenance);
        allocator.free(self.module);
    }
};

/// InlinedEvent - IR node for inlined events
/// Represents a small event that should be inlined at callsites.
/// Created by detecting small, pure events called from hot paths.
pub const InlinedEvent = struct {
    event_path: DottedPath,         // The event being inlined

    // Inline info
    inline_body: []const u8,        // The inlined code
    original_proc: ?*const ProcDecl = null,  // Pointer to original proc (if available)

    // Provenance
    inlined_from: DottedPath,       // Original event that was inlined

    // FOUNDATIONAL: Every item knows where it came from
    location: errors.SourceLocation = .{ .file = "generated", .line = 0, .column = 0 },
    module: []const u8,

    pub fn deinit(self: *InlinedEvent, allocator: std.mem.Allocator) void {
        self.event_path.deinit(allocator);
        allocator.free(self.inline_body);
        self.inlined_from.deinit(allocator);
        allocator.free(self.module);
    }
};

/// InlineCode - IR node for template-generated inline code
/// Represents code that should be emitted verbatim at the call site.
/// Created by transforms using template interpolation (e.g., ~if, ~for).
/// This is the foundation for zero-overhead control flow and aggressive inlining.
pub const InlineCode = struct {
    code: []const u8,               // The generated code to emit verbatim

    // FOUNDATIONAL: Every item knows where it came from
    location: errors.SourceLocation = .{ .file = "generated", .line = 0, .column = 0 },
    module: []const u8,

    pub fn deinit(self: *InlineCode, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.module);
    }
};

// ============================================================
// Build System Types (Polyglot Multi-Target Coordination)
// ============================================================
// These types allow compiler passes to declare their build requirements.
// See docs/KORU-BUILD.md for complete architecture documentation.

/// BuildStep represents a single step in the build process that the Koru
/// coordinator needs to execute. Compiler passes return these to declare
/// their build requirements (external compilers, libraries, runtime files).
pub const BuildStep = union(enum) {
    /// Execute an external command (e.g., glslangValidator for GPU shaders)
    system_command: SystemCommand,

    /// Link a system library (e.g., Vulkan, V8)
    link_library: LinkLibrary,

    /// Bundle a runtime file with the executable (e.g., .spv shaders, .wasm modules)
    runtime_file: RuntimeFile,

    /// Add an include path for C headers
    include_path: IncludePath,

    /// Add a compile flag to the Zig compiler
    compile_flag: CompileFlag,

    pub fn deinit(self: *BuildStep, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .system_command => |*cmd| cmd.deinit(allocator),
            .link_library => |*lib| lib.deinit(allocator),
            .runtime_file => |*file| file.deinit(allocator),
            .include_path => |*path| path.deinit(allocator),
            .compile_flag => |*flag| flag.deinit(allocator),
        }
    }
};

/// Execute an external program as part of the build
/// Example: glslangValidator -V shader.glsl -o shader.spv
pub const SystemCommand = struct {
    /// Program name or path (e.g., "glslangValidator", "/usr/bin/tsc")
    program: []const u8,

    /// Arguments to pass (e.g., ["-V", "-O", "shader.glsl"])
    args: []const []const u8,

    /// Optional working directory (null = inherit from build)
    cwd: ?[]const u8 = null,

    pub fn deinit(self: *SystemCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.program);
        for (self.args) |arg| {
            allocator.free(arg);
        }
        allocator.free(self.args);
        if (self.cwd) |cwd| {
            allocator.free(cwd);
        }
    }
};

/// Link a system library into the final executable
/// Example: Vulkan, CUDA, V8, QuickJS
pub const LinkLibrary = struct {
    /// Library name (e.g., "vulkan", "v8", "sqlite3")
    name: []const u8,

    /// If true, build succeeds even if library isn't available (graceful degradation)
    /// If false, build fails if library is missing
    optional: bool = false,

    pub fn deinit(self: *LinkLibrary, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// Bundle a runtime file with the executable
/// Example: Compiled shaders (.spv), WASM modules (.wasm), JavaScript bundles (.js)
pub const RuntimeFile = struct {
    /// Source path (usually in zig-cache after external compilation)
    source: []const u8,

    /// Destination path relative to installation directory
    /// Example: "shaders/" means installed to <install-dir>/shaders/
    dest: []const u8,

    pub fn deinit(self: *RuntimeFile, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        allocator.free(self.dest);
    }
};

/// Add an include path for C headers
/// Example: vendor/vulkan/include
pub const IncludePath = struct {
    /// Path to include directory
    path: []const u8,

    /// If true, use -isystem (system headers) instead of -I
    system: bool = false,

    pub fn deinit(self: *IncludePath, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

/// Add a compiler flag
/// Example: -DGPU_ENABLED, -march=native
pub const CompileFlag = struct {
    /// The flag to add (e.g., "-DGPU_ENABLED")
    flag: []const u8,

    pub fn deinit(self: *CompileFlag, allocator: std.mem.Allocator) void {
        allocator.free(self.flag);
    }
};

// ============================================================
// Unified AST Node Type
// ============================================================
// ASTNode provides a unified way to reference any node in the AST.
// This enables generic traversal, transforms that work on any node,
// and a clean interface for comptime AST manipulation.
//
// Every major compiler has this: Go's ast.Node, Rust's NodeId,
// TypeScript's ESTree Node, Python's AST base class, etc.

/// ASTNode - unified type for any node in the AST
/// Enables generic traversal and transformation without specialized code
/// for each nesting level.
pub const ASTNode = union(enum) {
    program: *Program,
    item: *Item,
    flow: *Flow,
    continuation: *Continuation,
    node: *Node,
    invocation: *Invocation,

    /// Returns child nodes for traversal.
    /// Caller is responsible for freeing the returned slice.
    pub fn children(self: ASTNode, allocator: std.mem.Allocator) ![]ASTNode {
        return switch (self) {
            .program => |p| blk: {
                var result = try allocator.alloc(ASTNode, p.items.len);
                for (p.items, 0..) |*item, i| {
                    result[i] = .{ .item = @constCast(item) };
                }
                break :blk result;
            },
            .item => |i| blk: {
                switch (i.*) {
                    .flow => |*f| {
                        var result = try allocator.alloc(ASTNode, 1);
                        result[0] = .{ .flow = @constCast(f) };
                        break :blk result;
                    },
                    .module_decl => |*m| {
                        var result = try allocator.alloc(ASTNode, m.items.len);
                        for (m.items, 0..) |*item, idx| {
                            result[idx] = .{ .item = @constCast(item) };
                        }
                        break :blk result;
                    },
                    // Leaf nodes (no children to traverse for transforms)
                    .event_decl, .proc_decl, .event_tap, .label_decl, .immediate_impl, .import_decl,
                    .host_line, .host_type_decl, .parse_error,
                    .native_loop, .fused_event, .inlined_event, .inline_code => {
                        break :blk try allocator.alloc(ASTNode, 0);
                    },
                }
            },
            .flow => |f| blk: {
                // Flow has: invocation + continuations
                // CRITICAL: Visit continuations FIRST for proper depth-first ordering!
                // Inner transforms (in continuations) must run before the outer transform (the flow itself).
                const count = 1 + f.continuations.len;
                var result = try allocator.alloc(ASTNode, count);
                for (f.continuations, 0..) |*cont, i| {
                    result[i] = .{ .continuation = @constCast(cont) };
                }
                result[f.continuations.len] = .{ .invocation = @constCast(&f.invocation) };
                break :blk result;
            },
            .continuation => |c| blk: {
                // Continuation has: optional step + branch continuations
                // CRITICAL: Visit continuations FIRST for proper depth-first ordering!
                // Branch continuations (| then |>, | else |>) may have inner transforms
                // that must run BEFORE outer transforms.
                const step_count: usize = if (c.node != null) 1 else 0;
                const count = c.continuations.len + step_count;
                var result = try allocator.alloc(ASTNode, count);
                var idx: usize = 0;
                // Visit branch continuations FIRST (inner transforms before outer)
                for (c.continuations) |*cont| {
                    result[idx] = .{ .continuation = @constCast(cont) };
                    idx += 1;
                }
                // Then visit the step (if present)
                if (c.node) |*s| {
                    result[idx] = .{ .node = @constCast(s) };
                }
                break :blk result;
            },
            .node => |s| blk: {
                switch (s.*) {
                    .invocation => |*inv| {
                        var result = try allocator.alloc(ASTNode, 1);
                        result[0] = .{ .invocation = @constCast(inv) };
                        break :blk result;
                    },
                    .conditional_block => |*cb| {
                        var result = try allocator.alloc(ASTNode, cb.nodes.len);
                        for (cb.nodes, 0..) |*step, i| {
                            result[i] = .{ .node = @constCast(step) };
                        }
                        break :blk result;
                    },
                    // Leaf step types
                    .label_apply, .label_with_invocation, .label_jump,
                    .terminal, .deref, .branch_constructor, .metatype_binding, .inline_code => {
                        break :blk try allocator.alloc(ASTNode, 0);
                    },
                    // Foreach, conditional, capture, switch_result have bodies handled via continuation traversal
                    // Assignment is a leaf node
                    .foreach, .conditional, .capture, .switch_result, .assignment => {
                        break :blk try allocator.alloc(ASTNode, 0);
                    },
                }
            },
            .invocation => |_| blk: {
                // Invocation is a leaf node (args are data, not traversable nodes)
                break :blk try allocator.alloc(ASTNode, 0);
            },
        };
    }

    /// Returns true if this node matches the given invocation path.
    /// Used by transform system to find transforms to apply.
    /// Supports glob patterns: log.* matches log.info, log.error, etc.
    pub fn matchesTransform(self: ASTNode, transform_name: []const u8) bool {
        if (self != .invocation) return false;
        const inv = self.invocation;

        // Join path segments
        if (inv.path.segments.len == 0) return false;

        // Build invocation path from segments
        var buf: [256]u8 = undefined;
        var pos: usize = 0;
        for (inv.path.segments, 0..) |seg, i| {
            if (i > 0) {
                buf[pos] = '.';
                pos += 1;
            }
            if (pos + seg.len > buf.len) return false;
            @memcpy(buf[pos..][0..seg.len], seg);
            pos += seg.len;
        }
        const invocation_path = buf[0..pos];

        // Check if pattern contains wildcard - if so, use glob matching
        if (std.mem.indexOfScalar(u8, transform_name, '*') != null) {
            return matchGlob(transform_name, invocation_path);
        }

        // Exact match for non-glob patterns
        return std.mem.eql(u8, invocation_path, transform_name);
    }

    /// Simple glob matching for transform patterns
    /// Supports: *, prefix.*, *.suffix, prefix*, *suffix, prefix.*.suffix
    fn matchGlob(pattern: []const u8, value: []const u8) bool {
        // Full wildcard matches anything
        if (std.mem.eql(u8, pattern, "*")) return true;

        // Prefix wildcard: *.suffix
        if (pattern.len > 2 and pattern[0] == '*' and pattern[1] == '.') {
            const suffix = pattern[1..]; // includes the dot
            return std.mem.endsWith(u8, value, suffix);
        }

        // Suffix wildcard with dot: prefix.*
        if (pattern.len > 2 and pattern[pattern.len - 2] == '.' and pattern[pattern.len - 1] == '*') {
            const prefix = pattern[0 .. pattern.len - 2]; // excludes the .*
            return std.mem.startsWith(u8, value, prefix) and
                value.len > prefix.len and value[prefix.len] == '.';
        }

        // Bare suffix wildcard: prefix*
        if (pattern.len > 1 and pattern[pattern.len - 1] == '*') {
            const prefix = pattern[0 .. pattern.len - 1];
            return std.mem.startsWith(u8, value, prefix);
        }

        // Bare prefix wildcard: *suffix
        if (pattern.len > 1 and pattern[0] == '*') {
            const suffix = pattern[1..];
            return std.mem.endsWith(u8, value, suffix);
        }

        // Middle wildcard: prefix.*.suffix
        if (std.mem.indexOfScalar(u8, pattern, '*')) |star_idx| {
            const prefix = pattern[0..star_idx];
            const suffix = pattern[star_idx + 1 ..];
            return std.mem.startsWith(u8, value, prefix) and std.mem.endsWith(u8, value, suffix) and
                value.len >= prefix.len + suffix.len;
        }

        return false;
    }

    /// Check if this invocation has already been transformed
    pub fn isAlreadyTransformed(self: ASTNode) bool {
        if (self != .invocation) return false;
        const inv = self.invocation;
        for (inv.annotations) |ann| {
            if (std.mem.eql(u8, ann, "@pass_ran(\"transform\")")) {
                return true;
            }
        }
        return false;
    }

    /// Find the containing Item for an invocation by walking the program.
    /// Returns the Item that contains this invocation (either as a flow's
    /// top-level invocation or in a continuation pipeline).
    /// This is needed by transform handlers that need access to continuations.
    pub fn findContainingItem(program: *const Program, target_inv: *const Invocation) ?*const Item {
        return findInItems(std.heap.page_allocator, program.items, target_inv);
    }

    fn findInItems(allocator: std.mem.Allocator, items: []const Item, target_inv: *const Invocation) ?*const Item {
        for (items) |*item| {
            switch (item.*) {
                .flow => |*f| {
                    // Check if this flow's invocation IS the target
                    if (&f.invocation == target_inv) {
                        return item;
                    }
                    // Check in continuations — return the original flow item
                    // so transform handlers can search the full continuation tree
                    if (findInContinuations(f.continuations, target_inv)) {
                        return item;
                    }
                },
                .immediate_impl => {},
                .module_decl => |*m| {
                    // Recursively search in module items
                    if (findInItems(allocator, m.items, target_inv)) |found| {
                        return found;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn findInContinuations(conts: []const Continuation, target_inv: *const Invocation) bool {
        for (conts) |*cont| {
            if (cont.node) |*node| {
                if (node.* == .invocation) {
                    if (&node.invocation == target_inv) {
                        return true;
                    }
                }
            }
            if (findInContinuations(cont.continuations, target_inv)) {
                return true;
            }
        }
        return false;
    }
};
