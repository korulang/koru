// Auto-Dispose Inserter - Inserts disposal calls before flow terminators
const log = @import("log");
//
// This pass runs BEFORE phantom_semantic_checker. It:
// 1. Tracks binding contexts and their phantom obligations
// 2. At flow terminators, checks for unsatisfied obligations
// 3. For exactly 1 auto-insertable disposal option: inserts the call
// 4. For 0 or >1 options: produces an error
//
// Auto-INSERT (not error hints) is constrained by what the pass can supply at
// scope exit: the obligation binding for the matching parameter. Any other
// **user-required** input (e.g. tx.exec's `sql`) has no value here and makes
// the event non-insertable. Optional parameters (?T) and future defaults may
// widen insert eligibility; see eventCanBeAutoInserted.
//
// The checker then validates normally (acts as safety net).

const std = @import("std");
const ast = @import("ast");
const ast_functional = @import("ast_functional");
const errors = @import("errors");
const phantom_parser = @import("phantom_parser");

/// Does this event carry `[!]`, the preferred-discharge annotation? The way an
/// author breaks a tie between several legal disposers.
pub fn hasPreferredDischarge(event_decl: *const ast.EventDecl) bool {
    for (event_decl.annotations) |ann| {
        if (std.mem.eql(u8, ann, "!")) return true;
    }
    return false;
}

/// Can this event be called UNATTENDED — appended at a scope exit with no
/// caller to take a return and no arm to answer a branch? Only a void tor can:
/// non-void comes in two spellings (named branches, and the single-return
/// `-> T`), and neither can be spliced as a bare call because the inserter
/// cannot synthesize the bind either output form requires.
pub fn isUnattendedDischarge(event_decl: *const ast.EventDecl) bool {
    return event_decl.branches.len == 0 and event_decl.return_type == null;
}

/// THE auto-discharge policy, over anything that can name its candidates.
/// One disposer is the answer; several are settled by `[!]`; zero, or a tie
/// among defaults, means nobody can act unattended and a human must say what
/// happens. `null` is therefore not "no disposer" — it is "not auto-
/// dischargeable", which is the only question a caller ever actually has.
///
/// Two callers, one policy: the inserter asks it to pick what to splice at a
/// scope exit, and std/store asks it to decide whether a column needs a
/// `! discharge` arm. Re-deriving it on either side is how the two drift.
pub fn pickUnattendedDischarge(
    comptime T: type,
    candidates: []const T,
    comptime declOf: fn (T) *const ast.EventDecl,
) ?T {
    if (candidates.len == 0) return null;
    if (candidates.len == 1) return candidates[0];

    var default_count: usize = 0;
    var chosen: ?T = null;
    for (candidates) |c| {
        if (hasPreferredDischarge(declOf(c))) {
            default_count += 1;
            chosen = c;
        }
    }
    if (default_count == 1) return chosen;
    return null;
}

pub const AutoDischargeInserter = struct {
    allocator: std.mem.Allocator,
    reporter: *errors.ErrorReporter,
    event_map: std.StringHashMap(EventInfo),
    /// label name -> the fold's seed invocation. A back-edge `@label(args)`
    /// routes its args into the SAME event's consuming params as the seed —
    /// jump args must credit discharges exactly like invocation args, or the
    /// carried obligation reads as live after the jump and a spurious (double-
    /// free) disposal gets inserted under the back edge (330_076).
    label_seed_map: std.StringHashMap(*const ast.Invocation),
    synthetic_binding_counter: u32,
    /// Monotonic acquisition sequence for LIFO auto-discharge unwind order.
    /// Stamped onto each new obligation; preserved across BindingContext.clone
    /// so nested-scope copies keep their original acquisition order.
    acq_seq_counter: u32,
    warn_mode: bool, // When true, emit warnings about auto-inserted disposals
    strict_panic_branches: bool, // When true (--panic-branches=strict), unhandled panic branches are compile errors (the crash-surface map, loud)
    prototype_mode: bool = false, // When true (~[prototype]), an unhandled required TERMINAL branch is synthesized as a @panic hole instead of a KORU022 error — same body as an unhandled | ?! panic branch (400_160)

    /// Error set for recursive functions that need explicit error types
    pub const RecursiveError = std.mem.Allocator.Error || error{ ValidationFailed, NoSpaceLeft };

    /// Information about an event's phantom annotations
    const EventInfo = struct {
        decl: *const ast.EventDecl,
        module_name: []const u8,
    };

    /// A disposal event that can satisfy an obligation
    const DisposalEvent = struct {
        qualified_name: []const u8,
        event_decl: *const ast.EventDecl,
        field_name: []const u8,
        is_default: bool, // Has [!] annotation - preferred for auto-discharge
    };

    /// Check if a continuation has @scope annotation (marks scope boundary)
    fn hasScope(cont: *const ast.Continuation) bool {
        for (cont.binding_annotations) |ann| {
            if (std.mem.eql(u8, ann, "@scope")) return true;
        }
        return false;
    }

    /// A NAMED LABEL continuation with a real binding on a bare-return head
    /// (`create() | made c |> ...`) binds the head result — the label is
    /// binding sugar for `: c`, and the emitter lowers both spellings to the
    /// same direct bind. Returns that binding, or null when no continuation
    /// binds the result (a `_`-bound label stays a discard and keeps the
    /// unbound-head discard materialization).
    fn headLabelBinding(flow: *const ast.Flow) ?[]const u8 {
        if (flow.inv().return_binding != null) return null;
        for (flow.body.continuations) |*cont| {
            if (cont.kind == .effect) continue;
            if (cont.is_catchall) continue;
            if (cont.branch.len == 0) continue;
            if (cont.binding) |b| {
                if (!std.mem.eql(u8, b, "_")) return b;
            }
        }
        return null;
    }

    /// Check if a NamedBranch has @scope annotation (marks scope boundary)
    fn branchHasScope(branch: *const ast.NamedBranch) bool {
        for (branch.annotations) |ann| {
            if (std.mem.eql(u8, ann, "@scope")) return true;
        }
        return false;
    }

    /// Is `conts[i]` a sequential-prefix step? An unnamed (`branch=''`) continuation
    /// followed by at least one more unnamed sibling is one of several SEQUENTIAL
    /// steps under a single site (the emitter concatenates them; the capture
    /// lowering produces the `! as` body chain and the `| captured` after-read chain
    /// this way). All but the LAST such sibling are sequential prefixes: the flow
    /// continues into the next sibling, so their tails are not flow exits and must
    /// not trigger terminator auto-discharge. (Named branches are alternatives, not
    /// a sequence — they are unaffected.)
    fn isSequentialPrefix(conts: []const ast.Continuation, i: usize) bool {
        if (conts[i].branch.len != 0) return false;
        var j = i + 1;
        while (j < conts.len) : (j += 1) {
            if (conts[j].branch.len == 0) return true;
        }
        return false;
    }

    /// Check if a binding escapes via a branch constructor field
    /// Returns true if the binding (or binding.field) appears in any field value
    fn bindingEscapesViaBranchConstructor(bc: *const ast.BranchConstructor, binding_name: []const u8) bool {
        // Identity branch constructors use plain_value instead of fields
        if (bc.plain_value) |plain| {
            if (std.mem.eql(u8, plain, binding_name)) {
                return true;
            }
            // Also match binding.field pattern on plain value
            if (std.mem.startsWith(u8, plain, binding_name)) {
                if (plain.len > binding_name.len and plain[binding_name.len] == '.') {
                    return true;
                }
            }
            return false;
        }
        for (bc.fields) |field| {
            // Check if field expression_str references the binding
            // e.g., binding "f" matches field expression "f.file" or just "f"
            const value = field.expression_str orelse continue;
            if (std.mem.startsWith(u8, value, binding_name)) {
                // Make sure it's the actual binding, not a prefix match
                // "f.file" starts with "f", and next char is '.' or end of string
                if (value.len == binding_name.len) {
                    return true; // Exact match
                }
                if (value.len > binding_name.len and value[binding_name.len] == '.') {
                    return true; // Binding.field pattern
                }
            }
        }
        return false;
    }

    /// Binding context tracks phantom states of variables in scope
    const BindingContext = struct {
        bindings: std.StringHashMap([]const u8), // variable name → phantom state
        cleanup_obligations: std.StringHashMap(BindingInfo), // binding → obligation info
        disposed_fields: std.StringHashMap(void), // field-path keys (`s.h`) already discharged, for double-discharge detection (330_109)
        allocator: std.mem.Allocator,
        scope_depth: u32, // Current scope depth (increments when entering loop body)
        is_repeating: bool, // True if we're inside a loop's `each` branch
        loop_entry_scope: ?u32, // Scope depth when we entered current @scope boundary (null if not in scope)
        // True while walking a `branch=''` continuation that has a LATER `branch=''`
        // sibling. Multiple unnamed continuations of one site are SEQUENTIAL steps,
        // not alternative branches — the emitter concatenates them. The capture
        // lowering produces exactly this (the `! as` body chain + the `| captured`
        // after-read chain, as sibling void-chains). An inherited obligation must
        // therefore flow THROUGH the chain and be discharged once at the final
        // step — not at the tail of each step (which would double-free / use after
        // free). When set, the tail of this step is NOT a flow exit, so terminator
        // auto-discharge is suppressed; the obligation is discharged by the last
        // sibling (processed with this flag clear). Cleared on entering a real
        // nested scope (effect/loop), where normal scope rules take over.
        in_sequential_prefix: bool,

        const BindingInfo = struct {
            phantom_state: []const u8,
            field_name: []const u8, // e.g., "file" for f.file
            base_type: []const u8, // e.g., "*Connection" - used to filter disposal events by type
            scope_depth: u32, // Scope where obligation was created
            acq_seq: u32, // Monotonic acquisition order (LIFO unwind uses descending)
            // An obligation the inserter must NOT auto-discharge: it presents no
            // disposal candidate and falls to the "was not discharged" wall
            // (KORU030), guiding manual discharge. Two origins:
            // - A record-RETURN field (`-> { h: *H<owned!>, n }`, 330_096). Unlike
            //   a whole-value bare-return obligation (auto-dischargeable) or a
            //   branch-payload field (phantom-checker-tracked, so an inserted
            //   disposer type-checks), a return-record field is NOT tracked by the
            //   phantom checker, so an auto-inserted `dispose(r.h)` fails
            //   validation. Per the ruling that record fields follow the SAME
            //   rules as event-payload fields (error when undischarged — 690_024).
            // - A terminal UNBOUND mid-chain return (`make(): h |> bump(h)` where
            //   bump returns a fresh `<owned!>`, 330_097). The value has no name,
            //   so no `dispose(...)` can be synthesized — the only honest move is
            //   the wall.
            not_auto_dischargeable: bool = false,
        };

        fn init(allocator: std.mem.Allocator) BindingContext {
            return .{
                .bindings = std.StringHashMap([]const u8).init(allocator),
                .cleanup_obligations = std.StringHashMap(BindingInfo).init(allocator),
                .disposed_fields = std.StringHashMap(void).init(allocator),
                .allocator = allocator,
                .scope_depth = 0,
                .is_repeating = false,
                .loop_entry_scope = null,
                .in_sequential_prefix = false,
            };
        }

        fn deinit(self: *BindingContext) void {
            var iter = self.bindings.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.bindings.deinit();

            var obl_iter = self.cleanup_obligations.iterator();
            while (obl_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.phantom_state);
                self.allocator.free(entry.value_ptr.field_name);
                self.allocator.free(entry.value_ptr.base_type);
            }
            self.cleanup_obligations.deinit();

            var disp_iter = self.disposed_fields.keyIterator();
            while (disp_iter.next()) |key| self.allocator.free(key.*);
            self.disposed_fields.deinit();
        }

        /// Add a binding with its phantom state and base type.
        /// `acq_seq` is the caller's stamped acquisition order (from the inserter
        /// counter) — only used when the phantom carries a cleanup obligation.
        fn addBinding(self: *BindingContext, name: []const u8, phantom_state: []const u8, field_name: []const u8, base_type: []const u8, acq_seq: u32) !void {
            const name_copy = try self.allocator.dupe(u8, name);
            const phantom_copy = try self.allocator.dupe(u8, phantom_state);

            try self.bindings.put(name_copy, phantom_copy);

            // Check if this has a cleanup obligation (! suffix)
            if (std.mem.endsWith(u8, phantom_state, "!")) {
                const field_copy = try self.allocator.dupe(u8, field_name);
                const type_copy = try self.allocator.dupe(u8, base_type);
                const obl_key = try self.allocator.dupe(u8, name);
                try self.cleanup_obligations.put(obl_key, .{
                    .phantom_state = try self.allocator.dupe(u8, phantom_state),
                    .field_name = field_copy,
                    .base_type = type_copy,
                    .scope_depth = self.scope_depth, // Record which scope created this obligation
                    .acq_seq = acq_seq,
                });
            }
        }

        /// Clear a cleanup obligation (when it's been satisfied)
        fn clearObligation(self: *BindingContext, name: []const u8) void {
            if (self.cleanup_obligations.fetchRemove(name)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value.phantom_state);
                self.allocator.free(kv.value.field_name);
                self.allocator.free(kv.value.base_type);
            }
        }

        /// Check if there are unsatisfied obligations
        fn hasObligations(self: *BindingContext) bool {
            return self.cleanup_obligations.count() > 0;
        }

        /// Get iterator over obligations
        fn obligations(self: *BindingContext) std.StringHashMap(BindingInfo).Iterator {
            return self.cleanup_obligations.iterator();
        }

        /// Clone context for branch exploration
        fn clone(self: *const BindingContext, allocator: std.mem.Allocator) !BindingContext {
            var new_ctx = BindingContext.init(allocator);
            new_ctx.scope_depth = self.scope_depth;
            new_ctx.is_repeating = self.is_repeating;
            new_ctx.loop_entry_scope = self.loop_entry_scope;
            new_ctx.in_sequential_prefix = self.in_sequential_prefix;

            var bind_iter = self.bindings.iterator();
            while (bind_iter.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try allocator.dupe(u8, entry.value_ptr.*);
                try new_ctx.bindings.put(key, val);
            }

            var obl_iter = self.cleanup_obligations.iterator();
            while (obl_iter.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                try new_ctx.cleanup_obligations.put(key, .{
                    .phantom_state = try allocator.dupe(u8, entry.value_ptr.phantom_state),
                    .field_name = try allocator.dupe(u8, entry.value_ptr.field_name),
                    .base_type = try allocator.dupe(u8, entry.value_ptr.base_type),
                    .scope_depth = entry.value_ptr.scope_depth,
                    // Preserve original acquisition order — do not re-stamp.
                    .acq_seq = entry.value_ptr.acq_seq,
                    .not_auto_dischargeable = entry.value_ptr.not_auto_dischargeable,
                });
            }

            var disp_iter = self.disposed_fields.keyIterator();
            while (disp_iter.next()) |key| {
                try new_ctx.disposed_fields.put(try allocator.dupe(u8, key.*), {});
            }

            return new_ctx;
        }

        /// Enter a loop construct (records scope at loop entry)
        fn enterLoop(self: *BindingContext) void {
            if (self.loop_entry_scope == null) {
                self.loop_entry_scope = self.scope_depth;
            }
        }

        /// Enter a new scope (for @scope boundaries - loops, taps, custom constructs)
        fn enterScope(self: *BindingContext, is_scoped: bool) void {
            self.scope_depth += 1;
            // is_scoped means we're inside a @scope boundary - outer resources cannot be discharged here
            self.is_repeating = is_scoped;
            // A real nested scope (effect/loop body) supersedes the sequential-prefix
            // suppression: inside it, the normal scope rules (is_repeating / scope_depth)
            // govern discharge. The prefix flag only governs the step's own flat tail.
            self.in_sequential_prefix = false;
            // Record scope entry point when entering a @scope boundary
            if (is_scoped and self.loop_entry_scope == null) {
                self.loop_entry_scope = self.scope_depth;
            }
        }

        /// Check if there are obligations from before we entered the current loop
        fn hasPreLoopObligations(self: *BindingContext) bool {
            const entry_scope = self.loop_entry_scope orelse return false;
            var iter = self.cleanup_obligations.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.scope_depth < entry_scope) return true;
            }
            return false;
        }

        /// Get first pre-loop obligation for error message
        fn getFirstPreLoopObligation(self: *BindingContext) ?struct { name: []const u8, state: []const u8 } {
            const entry_scope = self.loop_entry_scope orelse return null;
            var iter = self.cleanup_obligations.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.scope_depth < entry_scope) {
                    return .{ .name = entry.key_ptr.*, .state = entry.value_ptr.phantom_state };
                }
            }
            return null;
        }

        /// Check if there are obligations from outer scopes that would need disposal
        fn hasOuterScopeObligations(self: *BindingContext) bool {
            var iter = self.cleanup_obligations.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.scope_depth < self.scope_depth) {
                    return true;
                }
            }
            return false;
        }

        /// Get obligations from current scope only
        fn currentScopeObligations(self: *BindingContext) std.StringHashMap(BindingInfo).Iterator {
            // Note: Caller must filter by scope_depth
            return self.cleanup_obligations.iterator();
        }
    };

    pub fn init(allocator: std.mem.Allocator, reporter: *errors.ErrorReporter, warn_mode: bool, strict_panic_branches: bool, prototype_mode: bool) !AutoDischargeInserter {
        return .{
            .allocator = allocator,
            .reporter = reporter,
            .event_map = std.StringHashMap(EventInfo).init(allocator),
            .label_seed_map = std.StringHashMap(*const ast.Invocation).init(allocator),
            .synthetic_binding_counter = 0,
            .acq_seq_counter = 0,
            .warn_mode = warn_mode,
            .strict_panic_branches = strict_panic_branches,
            .prototype_mode = prototype_mode,
        };
    }

    /// Stamp the next acquisition sequence number for a newly created obligation.
    fn nextAcqSeq(self: *AutoDischargeInserter) u32 {
        const seq = self.acq_seq_counter;
        self.acq_seq_counter += 1;
        return seq;
    }

    /// Obligation entry for LIFO-ordered disposal emission.
    const OrderedObligation = struct {
        binding_path: []const u8,
        info: BindingContext.BindingInfo,
    };

    /// Collect cleanup obligations sorted by acq_seq descending (last-acquired first).
    fn obligationsInLifoOrder(self: *AutoDischargeInserter, context: *BindingContext) ![]OrderedObligation {
        var list = try std.ArrayList(OrderedObligation).initCapacity(self.allocator, context.cleanup_obligations.count());
        var obl_iter = context.obligations();
        while (obl_iter.next()) |entry| {
            try list.append(self.allocator, .{
                .binding_path = entry.key_ptr.*,
                .info = entry.value_ptr.*,
            });
        }
        std.sort.block(OrderedObligation, list.items, {}, struct {
            fn lessThan(_: void, a: OrderedObligation, b: OrderedObligation) bool {
                return a.info.acq_seq > b.info.acq_seq;
            }
        }.lessThan);
        return try list.toOwnedSlice(self.allocator);
    }

    pub fn deinit(self: *AutoDischargeInserter) void {
        var iter = self.event_map.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.event_map.deinit();
        self.label_seed_map.deinit();
    }

    /// Main entry point - run the auto-discharge pass on a program
    // =========================================================================
    // Label loop scope annotation
    // =========================================================================
    // For #label flows, continuations that jump back (@label) are scoped
    // (like `each` in a for-loop). Continuations that don't jump back are
    // exit paths (like `done`). This adds @scope to the looping ones so
    // the auto-discharge logic treats them correctly.
    // =========================================================================

    /// Check if a continuation tree contains a label_jump or label_apply matching the given label name
    fn continuationContainsLabelJump(cont: *const ast.Continuation, label_name: []const u8) bool {
        // Check the node in this continuation
        if (cont.node) |node| {
            switch (node) {
                .label_jump => |lj| {
                    if (std.mem.eql(u8, lj.label, label_name)) return true;
                },
                .label_apply => |la| {
                    if (std.mem.eql(u8, la, label_name)) return true;
                },
                .label_with_invocation => |lwi| {
                    if (!lwi.is_declaration and std.mem.eql(u8, lwi.label, label_name)) return true;
                },
                else => {},
            }
        }
        // Recurse into nested continuations
        for (cont.continuations) |*nested| {
            if (continuationContainsLabelJump(nested, label_name)) return true;
        }
        return false;
    }

    /// Add @scope to binding_annotations of a continuation
    fn addScopeAnnotation(self: *AutoDischargeInserter, cont: *const ast.Continuation) !ast.Continuation {
        const old_anns = cont.binding_annotations;
        const new_anns = try self.allocator.alloc([]const u8, old_anns.len + 1);
        for (old_anns, 0..) |ann, ai| {
            new_anns[ai] = try self.allocator.dupe(u8, ann);
        }
        new_anns[old_anns.len] = try self.allocator.dupe(u8, "@scope");

        var new_cont = cont.*;
        new_cont.binding_annotations = new_anns;
        return new_cont;
    }

    /// Recursively walk a continuation tree, annotating label loop branches with @scope.
    /// Returns new continuations array if modified, null if unchanged.
    fn annotateContTree(self: *AutoDischargeInserter, conts: []const ast.Continuation) !?[]const ast.Continuation {
        var modified = false;
        const new_conts = try self.allocator.alloc(ast.Continuation, conts.len);
        @memcpy(new_conts, conts);

        for (new_conts, 0..) |*cont, ci| {
            // Check if this continuation's node is a label declaration (#label event(...))
            if (cont.node) |node| {
                if (node == .label_with_invocation) {
                    const lwi = node.label_with_invocation;
                    if (lwi.is_declaration) {
                        // This is a #label — annotate its sub-continuations
                        const label_name = lwi.label;
                        var branch_modified = false;
                        const new_sub = try self.allocator.alloc(ast.Continuation, cont.continuations.len);
                        @memcpy(new_sub, cont.continuations);

                        for (new_sub, 0..) |*sub, si| {
                            if (!hasScope(sub) and continuationContainsLabelJump(sub, label_name)) {
                                new_sub[si] = try self.addScopeAnnotation(sub);
                                branch_modified = true;
                            }
                        }

                        if (branch_modified) {
                            new_conts[ci].continuations = new_sub;
                            modified = true;
                        }
                    }
                }
            }

            // Recurse into sub-continuations regardless
            if (cont.continuations.len > 0) {
                if (try self.annotateContTree(cont.continuations)) |new_sub| {
                    new_conts[ci].continuations = new_sub;
                    modified = true;
                }
            }
        }

        if (modified) return new_conts;
        return null;
    }

    /// Annotate label loop scopes across the entire program.
    fn annotateLabelLoopScopes(self: *AutoDischargeInserter, program: *const ast.Program) !*const ast.Program {
        var modified = false;
        const new_items = try self.allocator.alloc(ast.Item, program.items.len);
        @memcpy(new_items, program.items);

        for (new_items) |*item| {
            switch (item.*) {
                .flow => |*flow| {
                    // Handle top-level flows with pre_label
                    if (flow.pre_label) |label_name| {
                        var branch_modified = false;
                        const new_conts = try self.allocator.alloc(ast.Continuation, flow.body.continuations.len);
                        @memcpy(new_conts, flow.body.continuations);

                        for (new_conts, 0..) |*cont, ci| {
                            if (!hasScope(cont) and continuationContainsLabelJump(cont, label_name)) {
                                new_conts[ci] = try self.addScopeAnnotation(cont);
                                branch_modified = true;
                            }
                        }

                        if (branch_modified) {
                            flow.body.continuations = new_conts;
                            modified = true;
                        }
                    }

                    // Also recurse into continuation tree for nested #label nodes
                    if (try self.annotateContTree(flow.body.continuations)) |new_conts| {
                        flow.body.continuations = new_conts;
                        modified = true;
                    }
                },
                else => {},
            }
        }

        if (modified) {
            const new_program = try self.allocator.create(ast.Program);
            new_program.* = program.*;
            new_program.items = new_items;
            return new_program;
        }
        return program;
    }

    /// Net brace depth change of one host line, ignoring braces inside string
    /// literals and after a line comment. Local to this module because the
    /// inserter's module graph does not include the lexer; same rule as
    /// `lexer.countBraceDepthChange`.
    fn braceDepthChange(text: []const u8) i32 {
        var depth: i32 = 0;
        var in_string = false;
        var string_char: u8 = 0;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const ch = text[i];
            if (!in_string and ch == '/' and i + 1 < text.len and text[i + 1] == '/') break;
            if (!in_string and (ch == '"' or ch == '\'')) {
                in_string = true;
                string_char = ch;
            } else if (in_string) {
                if (ch == '\\') i += 1 else if (ch == string_char) in_string = false;
            } else if (ch == '{') {
                depth += 1;
            } else if (ch == '}') {
                depth -= 1;
            }
        }
        return depth;
    }

    /// Names a module declares at host level: `const X`, `pub const X`,
    /// `fn X`, `pub fn X`, `var X`, `pub var X`. Null when the line declares
    /// nothing. Also used to spot a body-local of the same name.
    fn hostDeclName(content: []const u8) ?[]const u8 {
        var rest = std.mem.trim(u8, content, " \t");
        if (std.mem.startsWith(u8, rest, "pub ")) rest = std.mem.trim(u8, rest[4..], " \t");

        const kw: []const u8 = for ([_][]const u8{ "const ", "fn ", "var " }) |k| {
            if (std.mem.startsWith(u8, rest, k)) break k;
        } else return null;

        rest = std.mem.trim(u8, rest[kw.len..], " \t");
        var end: usize = 0;
        while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) end += 1;
        if (end == 0) return null;
        return rest[0..end];
    }

    /// True when `name` occurs in `body` as a bare identifier: at token
    /// boundaries, never after a `.` (so `$mod.NAME` and `x.NAME` are fine),
    /// not inside a string or comment, and not shadowed by a body-local of the
    /// same name.
    fn bodyUsesBare(body: []const u8, name: []const u8) bool {
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            const decl = hostDeclName(line) orelse continue;
            if (std.mem.eql(u8, decl, name)) return false; // shadowed locally
        }

        var in_string = false;
        var string_char: u8 = 0;
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            const ch = body[i];

            if (!in_string and ch == '/' and i + 1 < body.len and body[i + 1] == '/') {
                while (i < body.len and body[i] != '\n') i += 1;
                continue;
            }
            if (!in_string and (ch == '"' or ch == '\'')) {
                in_string = true;
                string_char = ch;
                continue;
            }
            if (in_string) {
                if (ch == '\\') i += 1 else if (ch == string_char) in_string = false;
                continue;
            }

            if (!std.ascii.isAlphabetic(ch) and ch != '_') continue;
            var end = i;
            while (end < body.len and (std.ascii.isAlphanumeric(body[end]) or body[end] == '_')) end += 1;

            if (std.mem.eql(u8, body[i..end], name) and !(i > 0 and body[i - 1] == '.')) return true;
            i = end - 1;
        }
        return false;
    }

    /// KORU112 — an effect-branch proc body is spliced into the CONSUMER's
    /// frame (cut-1 inlining), where the declaring module's names do not
    /// exist. `$mod.` is the sanctioned spelling for reaching module scope
    /// from such a body; 400_155 holds it green, 400_157 is this wall.
    ///
    /// Without it the mistake arrives as a Zig "use of undeclared identifier"
    /// pointing into `output_emitted.zig` — a file the author never wrote,
    /// about a rule stated only in a comment inside another library.
    ///
    /// `std` is exempt: the inliner rewrites `std.` to an explicit import, so
    /// a bare `std` is correct in these bodies.
    fn checkEffectProcModuleScope(self: *AutoDischargeInserter, program: *const ast.Program) !void {
        // Only IMPORTED modules. A proc declared in the entry module splices
        // into a frame that is already in that module's namespace, so its bare
        // names resolve and `$mod.` is not required there (400_080, 400_105,
        // 400_108 are all this shape and must stay green).
        for (program.items) |*it| {
            if (it.* == .module_decl) try self.checkModuleScope(it.module_decl.items);
        }
    }

    /// KORU080 — every REQUIRED input of a callee is supplied at the call site.
    ///
    /// Ten months without this. What stood in for it was ZIG: an omitted
    /// argument the impl reads becomes `use of undeclared identifier` in
    /// generated code, and on the proc path `missing struct field`. Both are
    /// loud, neither is ours, and neither fires when the parameter is declared
    /// and never read — which compiled clean and RAN (400_183). An `Expression`
    /// param was more silent still: captured source text is not a struct field,
    /// so the host had nothing to miss (400_184).
    ///
    /// It lives here, beside KORU112, for the same reason: this pass runs AFTER
    /// the import fold and has a reporter. A frontend checker is handed the
    /// entry file's items only, and a callee's declaration routinely lives in
    /// another module.
    fn checkCallSiteArity(self: *AutoDischargeInserter, items: []const ast.Item, home: []const u8) anyerror!void {
        for (items) |*it| {
            switch (it.*) {
                .module_decl => |*m| try self.checkCallSiteArity(m.items, m.logical_name),
                .flow => |*f| {
                    const mod = if (f.module.len > 0) f.module else home;
                    try self.checkArityInInvocation(f.inv(), f.location, mod);
                    for (f.body.continuations) |*c| try self.checkArityInContinuation(c, f.location, mod);
                },
                else => {},
            }
        }
    }

    fn checkArityInContinuation(self: *AutoDischargeInserter, cont: *const ast.Continuation, loc: errors.SourceLocation, home: []const u8) anyerror!void {
        if (cont.node) |*n| {
            if (n.* == .invocation) {
                const at = if (cont.location.line > 0) cont.location else loc;
                try self.checkArityInInvocation(&n.invocation, at, home);
            }
        }
        for (cont.continuations) |*c| try self.checkArityInContinuation(c, loc, home);
    }

    fn checkArityInInvocation(self: *AutoDischargeInserter, inv: *const ast.Invocation, loc: errors.SourceLocation, home: []const u8) !void {
        if (inv.path.segments.len == 0) return;
        // A site carrying `inline_body` is NOT a call. Its transform already
        // lowered the whole thing into the enclosing scope and left the
        // invocation behind as a path the emitter reads — with the ORIGINAL
        // args, which do not match the `.impl` shape it now points at
        // (`std/io:print.blk` → `print.blk.impl { text: string }`, never
        // supplied because nothing ever calls it). The return-switch fast path
        // bails on exactly this condition for the same reason.
        if (inv.inline_body != null) return;
        const name = try self.pathToString(inv.path);
        defer self.allocator.free(name);
        const mod = inv.path.module_qualifier orelse home;
        const qualified = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ mod, name });
        defer self.allocator.free(qualified);
        const info = self.event_map.get(qualified) orelse return;

        // A `[norun]` tor is a SHAPE, not something anyone calls: the vocabulary
        // verbs a transform reads off the tree (`std/parser:match`,
        // `std/trellis:define`) and the `.impl` residues transforms point their
        // consumed sites at. Nothing supplies their inputs because nothing
        // invokes them.
        for (info.decl.annotations) |ann| {
            if (std.mem.eql(u8, ann, "norun")) return;
        }

        for (info.decl.input.fields) |field| {
            if (!callSiteMustSupply(field)) continue;
            var supplied = false;
            for (inv.args, 0..) |arg, i| {
                const resolved = if (std.mem.eql(u8, arg.name, arg.value) and i < info.decl.input.fields.len)
                    info.decl.input.fields[i].name
                else
                    arg.name;
                if (std.mem.eql(u8, resolved, field.name)) {
                    supplied = true;
                    break;
                }
            }
            if (supplied) continue;
            try self.reporter.addErrorAtLocation(.KORU080, loc, "'{s}' requires input '{s}' — it is declared with no default and no `?`, and this call does not supply it", .{ name, field.name });
        }
    }

    /// Is this an input the AUTHOR writes at the call site?
    ///
    /// The exemptions are the risky half of this wall, not the check: a comptime
    /// transform's shape declares parameters the COMPILER injects — the
    /// invocation, the containing item, the program, an allocator, a reporter —
    /// and the author writes none of them. Getting the list wrong turns one
    /// diagnostic into a flood across the whole stdlib, so this errs toward
    /// silence: anything not recognisably an ordinary value parameter is exempt.
    fn callSiteMustSupply(field: ast.Field) bool {
        if (field.default != null) return false;
        if (field.type.len > 0 and field.type[0] == '?') return false;
        // A source BLOCK is written as `{ ... }` after the args, never as an arg.
        if (field.is_source) return false;
        // Call-site metadata the compiler synthesizes.
        if (field.is_invocation_meta) return false;
        // Comptime-transform machinery, recognised by type. These are the
        // parameters `~[comptime|transform]` shapes declare and the walker fills.
        const injected = [_][]const u8{
            "*const Invocation", "*const Item",       "*const Program",
            "Invocation",        "Item",              "Program",
            "ErrorReporter",     "*ErrorReporter",    "Allocator",
        };
        for (injected) |t| {
            if (std.mem.eql(u8, field.type, t)) return false;
        }
        if (std.mem.endsWith(u8, field.type, "ErrorReporter")) return false;
        if (std.mem.endsWith(u8, field.type, "mem.Allocator")) return false;
        return true;
    }

    /// One module's item scope. An imported module arrives as a `module_decl`
    /// holding its own items, so membership is structural here rather than a
    /// `.module` string match — a proc and the host lines it may reach bare are
    /// exactly the ones in the same slice.
    fn checkModuleScope(self: *AutoDischargeInserter, items: []const ast.Item) anyerror!void {
        for (items) |*it| {
            if (it.* == .module_decl) try self.checkModuleScope(it.module_decl.items);
        }

        for (items) |*item| {
            const proc = switch (item.*) {
                .proc_decl => |*p| p,
                else => continue,
            };
            if (proc.body.text.len == 0) continue;

            var has_effect = false;
            for (items) |*other| {
                const ev = switch (other.*) {
                    .event_decl => |*e| e,
                    else => continue,
                };
                if (ev.path.segments.len != proc.path.segments.len) continue;
                var same = true;
                for (ev.path.segments, proc.path.segments) |a, b| {
                    if (!std.mem.eql(u8, a, b)) {
                        same = false;
                        break;
                    }
                }
                if (!same) continue;
                for (ev.branches) |*b| {
                    if (b.kind == .effect) {
                        has_effect = true;
                        break;
                    }
                }
                break;
            }
            if (!has_effect) continue;

            // Host lines include the BODIES of host-level `fn`s, so a local
            // inside one reads as a module declaration unless depth is tracked.
            // Only names at brace depth 0 are module scope. (Found by the curl
            // lift: `const msg` inside `curlError` is not a module name.)
            var depth: i32 = 0;
            for (items) |*hl_item| {
                const hl = switch (hl_item.*) {
                    .host_line => |*h| h,
                    else => continue,
                };
                const at_module_scope = depth == 0;
                depth += braceDepthChange(hl.content);
                if (!at_module_scope) continue;

                const name = hostDeclName(hl.content) orelse continue;
                if (std.mem.eql(u8, name, "std")) continue;
                if (!bodyUsesBare(proc.body.text, name)) continue;

                try self.reporter.addErrorAtLocation(
                    .KORU112,
                    proc.location,
                    "'{s}' is declared by this module and reached bare from a proc body that carries effect branches — such a body splices into the CALLER, where module scope is gone. Write `$mod.{s}`.",
                    .{ name, name },
                );
            }
        }
    }

    pub fn run(self: *AutoDischargeInserter, program: *const ast.Program) !*const ast.Program {
        // Step 0: Annotate label loop scopes
        // For #label flows, add @scope to continuations that jump back (@label).
        // This must happen before auto-discharge so it sees the correct scope boundaries.
        const annotated_program = try self.annotateLabelLoopScopes(program);

        // Step 1: Build event map
        try self.buildEventMap(annotated_program);

        // Step 1a: KORU112 — decl-level, and it lives here rather than in a
        // checker because this pass runs AFTER the import fold. The frontend
        // checkers are handed the entry file's items only, so an imported
        // module's proc bodies are invisible to them.
        try self.checkEffectProcModuleScope(annotated_program);

        // Step 1b: KORU080 — call-site arity, same home and the same reason.
        try self.checkCallSiteArity(annotated_program.items, annotated_program.main_module_name);

        // Check for validation errors (e.g., [!] on branched events)
        if (self.reporter.hasErrors()) {
            const stderr_writer = std.debug.lockStderrWriter(&.{});
            defer std.debug.unlockStderrWriter();
            try self.reporter.printErrors(stderr_writer);
            return error.ValidationFailed;
        }

        // Step 2: Transform all flows (structural + terminator disposals)
        var current_program = annotated_program;
        var iteration: u32 = 0;
        const max_iterations: u32 = 100000;

        while (iteration < max_iterations) : (iteration += 1) {
            const result = try self.transformOneFlow(current_program, .full);
            if (result.transformed) {
                current_program = result.program;
            } else {
                // No more transformations needed
                break;
            }
        }

        // Step 3: Scope-exit insertion pass on a stable tree
        iteration = 0;
        while (iteration < max_iterations) : (iteration += 1) {
            const result = try self.transformOneFlow(current_program, .scope_exit_only);
            if (result.transformed) {
                current_program = result.program;
            } else {
                break;
            }
        }

        return current_program;
    }

    /// The `--auto-discharge=disable` / `~[strict]` entry point: those modes opt
    /// out of INSERTING discharges, not out of the language seeing a discard.
    /// Runs declaration validation ([!] must be void — a malformed declaration
    /// is a declaration error regardless of insertion mode) and the head-discard
    /// normalization ONLY, so the phantom checker downstream sees the implicit
    /// `: _ |> _` of an obligation-carrying bare call and fires KORU030 on the
    /// leak. Deliberately skips label-loop @scope annotation and every insertion
    /// path — nothing here adds a disposal call.
    pub fn runNormalizeOnly(self: *AutoDischargeInserter, program: *const ast.Program) !*const ast.Program {
        try self.buildEventMap(program);

        if (self.reporter.hasErrors()) {
            const stderr_writer = std.debug.lockStderrWriter(&.{});
            defer std.debug.unlockStderrWriter();
            try self.reporter.printErrors(stderr_writer);
            return error.ValidationFailed;
        }

        var current_program = program;
        var iteration: u32 = 0;
        const max_iterations: u32 = 100000;

        while (iteration < max_iterations) : (iteration += 1) {
            const result = try self.transformOneFlow(current_program, .normalize_only);
            if (result.transformed) {
                current_program = result.program;
            } else {
                break;
            }
        }

        return current_program;
    }

    /// Build map of all events and their phantom annotations
    pub fn buildEventMap(self: *AutoDischargeInserter, program: *const ast.Program) !void {
        // IMPORTANT: Use |*item| to get pointers into the actual slice, not copies!
        for (program.items) |*item| {
            switch (item.*) {
                .event_decl => {
                    const event_decl = &item.event_decl;
                    const event_name = try self.pathToString(event_decl.path);
                    defer self.allocator.free(event_name);

                    try self.validateDefaultDischargeEvent(event_decl);

                    const qualified_name = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}:{s}",
                        .{ event_decl.module, event_name },
                    );
                    try self.event_map.put(qualified_name, .{
                        .decl = event_decl,
                        .module_name = event_decl.module,
                    });
                },
                .module_decl => {
                    const module = &item.module_decl;
                    // Also need pointers here!
                    for (module.items) |*mod_item| {
                        if (mod_item.* == .event_decl) {
                            const event_decl = &mod_item.event_decl;
                            const event_name = try self.pathToString(event_decl.path);
                            defer self.allocator.free(event_name);

                            try self.validateDefaultDischargeEvent(event_decl);

                            const qualified_name = try std.fmt.allocPrint(
                                self.allocator,
                                "{s}:{s}",
                                .{ module.logical_name, event_name },
                            );
                            try self.event_map.put(qualified_name, .{
                                .decl = event_decl,
                                .module_name = module.logical_name,
                            });
                        }
                    }
                },
                else => {},
            }
        }
    }

    /// Result of attempting to transform a flow
    const TransformResult = struct {
        transformed: bool,
        program: *const ast.Program,
    };

    const TransformMode = enum {
        full,
        scope_exit_only,
        /// Head-discard normalization ONLY — no disposal insertion, no
        /// terminator validation. Materializes the implicit discard of an
        /// obligation-carrying bare call (`~open()` where open returns
        /// `-> T<state!>` is the fully-discarded form of `~open(): _ |> _`)
        /// so the ENFORCEMENT side (phantom checker) sees the obligation and
        /// its flow exit. This is what pass-auto-discharge runs under
        /// `--auto-discharge=disable` and `~[strict]`: those modes opt out of
        /// INSERTING discharges, never out of the discard being visible.
        normalize_only,
    };

    /// Try to find and transform one flow that needs auto-discharge
    fn transformOneFlow(
        self: *AutoDischargeInserter,
        program: *const ast.Program,
        mode: TransformMode,
    ) !TransformResult {
        // Walk all items looking for flows with unsatisfied obligations at terminators
        // IMPORTANT: Use |*item| to get pointers into the actual slice!
        for (program.items, 0..) |*item, item_idx| {
            switch (item.*) {
                .flow => {
                    const flow = &item.flow;
                    const result = try self.checkAndTransformFlow(flow, program, item_idx, mode);
                    if (result.transformed) return result;
                },
                .immediate_impl => {},
                .module_decl => {
                    const module = &item.module_decl;
                    for (module.items, 0..) |*mod_item, mod_item_idx| {
                        _ = mod_item_idx;
                        if (mod_item.* == .flow) {
                            const flow = &mod_item.flow;
                            const result = try self.checkAndTransformFlow(flow, program, item_idx, mode);
                            if (result.transformed) return result;
                        }
                    }
                },
                else => {},
            }
        }

        return .{ .transformed = false, .program = program };
    }

    /// Check a flow for obligations at terminators and transform if needed
    fn checkAndTransformFlow(
        self: *AutoDischargeInserter,
        flow: *const ast.Flow,
        program: *const ast.Program,
        _: usize,
        mode: TransformMode,
    ) !TransformResult {

        // Get event info for this flow
        const event_name = try self.pathToString(flow.inv().path);
        defer self.allocator.free(event_name);

        const module_name = flow.inv().path.module_qualifier orelse flow.module;
        const qualified_name = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ module_name, event_name });
        defer self.allocator.free(qualified_name);

        const event_info = self.event_map.get(qualified_name) orelse {
            return .{ .transformed = false, .program = program };
        };

        // A pre-label fold head (`~spin = #loop step(h)`): the flow's own
        // invocation is the fold's seed; register it so back-edge jump args
        // credit against the round event's consuming params.
        if (flow.pre_label) |pre_label| {
            try self.label_seed_map.put(pre_label, flow.inv());
        }

        // Synthesize continuations for unhandled optional branches
        // This ensures all optional branches get switch cases and auto-discharge can handle them
        if (mode == .full) {
            if (try self.synthesizeOptionalBranches(flow, event_info.decl)) |new_flow| {
                // Replace the flow in the program with the synthesized version
                const new_program = try ast_functional.replaceFlowRecursive(
                    self.allocator,
                    program,
                    flow,
                    .{ .flow = new_flow.* },
                ) orelse {
                    return .{ .transformed = false, .program = program };
                };

                const result_ptr = try self.allocator.create(ast.Program);
                result_ptr.* = new_program;
                return .{ .transformed = true, .program = result_ptr };
            }
        }

        // UNBOUND flow head whose event returns a phantom obligation: a bare
        // call (`~open()` with `open -> *File<opened!>`) is the fully-discarded
        // form of `~open(): _` — the single-return migration made the dead bind
        // droppable (a consumer that fully discards a bare-return result is
        // just a bare call), so the obligation machinery must read the unbound
        // head as the discard it is. Materialize the implicit `: _` bind here;
        // the existing discard paths below (the `_`-rename and the
        // continuation-less terminal synthesis) then handle it exactly like the
        // spelled-out discard (330_094). Without this, the obligation is never
        // minted and enforcement is silently OFF for the whole bare-call shape
        // (330_011/025/028/036/043/070). Runs in normalize_only too — that is
        // the entire point of that mode.
        // …except when a NAMED LABEL continuation binds the head result
        // (`create() | made c |> ...` on a bare-return callee): the label is
        // binding sugar for `: c` — the emitter lowers both spellings to the
        // same direct bind — so the head is BOUND, not discarded. The binding
        // is seeded per-continuation in checkContinuation (the label twin of
        // the `: name` seeding below); materializing `: _` here would mint a
        // second, anonymous obligation for the same value.
        if (mode != .scope_exit_only and flow.inv().return_binding == null and
            event_info.decl.return_phantom != null and headLabelBinding(flow) == null)
        {
            const rebuilt = try self.materializeHeadDiscardBind(flow);
            const new_program = try ast_functional.replaceFlowRecursive(
                self.allocator,
                program,
                flow,
                .{ .flow = rebuilt },
            ) orelse return .{ .transformed = false, .program = program };
            const result_ptr = try self.allocator.create(ast.Program);
            result_ptr.* = new_program;
            return .{ .transformed = true, .program = result_ptr };
        }

        // Flow-head `_` bind that carries a return obligation AND has
        // continuations: rename `_` to a synthetic so the eventual auto-inserted
        // disposal can reference the value (a bare `_` leaks into generated Zig
        // as `.field = _`). The has-continuations twin of the continuation-less
        // giveContinuationlessHeadTerminal path below and of the flat-form
        // continuation discard (`call(): _ |> ...`) handled in checkContinuation.
        // Fires only when the head event returns a phantom obligation; a plain
        // `_` head with no obligation stays a genuine discard.
        if (mode != .scope_exit_only and flow.body.continuations.len > 0) {
            if (flow.inv().return_binding) |rb| {
                if (std.mem.eql(u8, rb, "_") and event_info.decl.return_phantom != null) {
                    const rebuilt = try self.renameHeadDiscardBinding(flow);
                    const new_program = try ast_functional.replaceFlowRecursive(
                        self.allocator,
                        program,
                        flow,
                        .{ .flow = rebuilt },
                    ) orelse return .{ .transformed = false, .program = program };
                    const result_ptr = try self.allocator.create(ast.Program);
                    result_ptr.* = new_program;
                    return .{ .transformed = true, .program = result_ptr };
                }
            }
        }

        // Walk continuations looking for terminators with obligations
        var context = BindingContext.init(self.allocator);
        defer context.deinit();

        // Flow-head bare-return bind: `~make(): h0 |> ...` binds `h0` to the head
        // event's `-> T<phantom>` return. Seed its obligation at scope 0 so it is
        // tracked for disposal/scope exactly like a `| branch h0` payload bind —
        // the head twin of the continuation-level bare-return recording below,
        // and the auto-discharge counterpart of the phantom checker's flow-head
        // threading. This makes the bare-return head form enforce the same
        // obligation discharge the NAMED-BRANCH head form already does: an
        // undischarged head obligation is a leak in both spellings (caught at
        // flow exit, KORU030), and a discharge of it inside a loop `@scope` is an
        // outer-scope violation in both (KORU032, 330_077/082). The two head
        // spellings are the same program; they must type the same.
        if (flow.inv().return_binding) |rb| {
            if (event_info.decl.return_phantom) |rp| {
                const canonical = try self.canonicalizePhantom(rp, module_name);
                defer self.allocator.free(canonical);
                try context.addBinding(rb, canonical, "__type_ref", event_info.decl.return_type orelse "", self.nextAcqSeq());
            } else if (event_info.decl.return_type) |rt| {
                // No whole-value phantom, but a record return may carry per-field
                // obligations (`-> { h: *Handle<owned!>, n }`). Descend and seed.
                try self.seedRecordFieldObligations(rb, rt, module_name, flow.inv().return_destructure, &context);
            }
        }

        for (flow.body.continuations, 0..) |*cont, cont_idx| {
            // Normalization never walks into continuations — no insertion, no
            // terminator validation. The head materialization above is the whole
            // job; enforcement stays with the phantom checker.
            if (mode == .normalize_only) break;
            // Capture at flow-head lowers to sibling `branch=''` continuations (the
            // `! as` body chain + the `| captured` after-read chain) directly under
            // the flow body. All but the last are sequential prefixes — not flow
            // exits — so their inherited obligations flow to the final sibling.
            const seq_prefix = isSequentialPrefix(flow.body.continuations, cont_idx);
            // If this continuation has @scope annotation, enter a new scope
            // The @scope annotation is the source of truth - not the event name
            if (hasScope(cont)) {
                var scoped_context = try context.clone(self.allocator);
                defer scoped_context.deinit();
                scoped_context.enterScope(true); // @scope means we're in a scoped boundary

                const result = try self.checkContinuation(cont, event_info.decl, module_name, &scoped_context, program, flow, mode, true);
                if (result.transformed) return result;

                if (mode == .scope_exit_only) {
                    // SCOPE EXIT: Check for remaining obligations in this scoped continuation
                    if (scoped_context.hasObligations()) {
                        const ordered = try self.obligationsInLifoOrder(&scoped_context);
                        defer self.allocator.free(ordered);
                        for (ordered) |entry| {
                            const binding_name = entry.binding_path;
                            const info = entry.info;

                            const disposals = if (info.not_auto_dischargeable)
                try self.allocator.alloc(DisposalEvent, 0)
            else
                try self.findDisposalEvents(info.phantom_state, info.base_type);
                            defer self.allocator.free(disposals);

                            const disposal = selectDisposal(disposals) orelse {
                                const display_name = formatBindingForError(binding_name, info.field_name, info.base_type);
                                const display_state = formatStateForError(info.phantom_state);
                                if (disposals.len == 0) {
                                    // Check for multi-branch events that could dispose this
                                    const all_disposals = try self.findAllDisposalEvents(info.phantom_state, info.base_type);
                                    defer self.allocator.free(all_disposals);
                                    if (all_disposals.len > 0) {
                                        var options_buf: [512]u8 = undefined;
                                        var fbs = std.io.fixedBufferStream(&options_buf);
                                        for (all_disposals, 0..) |d, i| {
                                            if (i > 0) fbs.writer().writeAll(", ") catch {};
                                            fbs.writer().writeAll(displayDischargerName(d.qualified_name)) catch {};
                                        }
                                        if (all_disposals.len == 1) {
                                            try self.reporter.addError(
                                                .KORU030,
                                                flow.location.line,
                                                flow.location.column,
                                                "Resource '{s}' obligation <{s}> was not discharged. Call: {s}",
                                                .{ display_name, display_state, fbs.getWritten() },
                                            );
                                        } else {
                                            try self.reporter.addError(
                                                .KORU030,
                                                flow.location.line,
                                                flow.location.column,
                                                "Resource '{s}' obligation <{s}> was not discharged. Call one of: {s}",
                                                .{ display_name, display_state, fbs.getWritten() },
                                            );
                                        }
                                    } else {
                                        try self.reporter.addError(
                                            .KORU030,
                                            flow.location.line,
                                            flow.location.column,
                                            "Resource '{s}' obligation <{s}> was not discharged at scope exit.",
                                            .{ display_name, display_state },
                                        );
                                    }
                                } else {
                                    // Build list of discharge options
                                    var options_buf: [512]u8 = undefined;
                                    var fbs = std.io.fixedBufferStream(&options_buf);
                                    for (disposals, 0..) |d, i| {
                                        if (i > 0) fbs.writer().writeAll(", ") catch {};
                                        // Extract just event name from qualified name
                                        const disp_name = displayDischargerName(d.qualified_name);
                                        fbs.writer().writeAll(disp_name) catch {};
                                    }
                                    try self.reporter.addError(
                                        .KORU030,
                                        flow.location.line,
                                        flow.location.column,
                                        "Resource '{s}' <{s}> has multiple discharge options: {s}. Discharge explicitly.",
                                        .{ display_name, display_state, fbs.getWritten() },
                                    );
                                }
                                return error.ValidationFailed;
                            };

                            // Find the continuation with this binding and insert disposal
                            const scope_exit_result = try self.insertScopeExitDisposalInCont(
                                cont,
                                binding_name,
                                disposal,
                                program,
                                flow,
                            );
                            if (scope_exit_result.transformed) return scope_exit_result;
                        }
                    }
                }
            } else {
                var seq_context = try context.clone(self.allocator);
                defer seq_context.deinit();
                if (seq_prefix) seq_context.in_sequential_prefix = true;

                const result = try self.checkContinuation(cont, event_info.decl, module_name, &seq_context, program, flow, mode, true);
                if (result.transformed) return result;
            }
        }

        // Continuation-less flow head with an undischarged obligation: the head
        // IS the flow exit (`~make(): _` / `~make(): h` with nothing after).
        // There is no terminal for the terminator-disposal machinery to fire on,
        // so synthesize one (renaming a `_` head bind first) and re-run — the
        // obligation then discharges through the normal path instead of leaking
        // (silently for `: _`, as a Zig unused-const for a named bind). Guarded
        // on hasObligations() so it fires only for a real cleanup obligation.
        if (mode != .scope_exit_only and flow.body.continuations.len == 0 and
            flow.inv().return_binding != null and context.hasObligations())
        {
            const rebuilt = try self.giveContinuationlessHeadTerminal(flow);
            const new_program = try ast_functional.replaceFlowRecursive(
                self.allocator,
                program,
                flow,
                .{ .flow = rebuilt },
            ) orelse return .{ .transformed = false, .program = program };
            const result_ptr = try self.allocator.create(ast.Program);
            result_ptr.* = new_program;
            return .{ .transformed = true, .program = result_ptr };
        }

        return .{ .transformed = false, .program = program };
    }

    /// Check a continuation for terminators with obligations
    fn checkContinuation(
        self: *AutoDischargeInserter,
        cont: *const ast.Continuation,
        event_decl: *const ast.EventDecl,
        module_name: []const u8,
        parent_context: *BindingContext,
        program: *const ast.Program,
        flow: *const ast.Flow,
        mode: TransformMode,
        /// True when `event_decl` is KNOWN to be the event this continuation's
        /// branch/label attaches to (the flow head, or a resolved step
        /// invocation). The nested loop falls back to the PARENT decl when the
        /// step is not a plain invocation (label folds, foreach, inline code)
        /// — in that fallback the label-sugar registration below must not
        /// fire, or a fold arm like `| stop r` gets credited with the parent
        /// bare-return's obligation it never bound (330_074).
        event_is_direct_callee: bool,
    ) !TransformResult {
        // Clone context for this branch
        var context = try parent_context.clone(self.allocator);
        defer context.deinit();

        // Handle discard binding (_) - synthesize a real binding name
        // This must happen BEFORE we process the continuation so the binding can be used
        if (mode == .full) {
            if (cont.binding) |binding_name| {
                if (std.mem.eql(u8, binding_name, "_")) {
                    // Generate synthetic binding to replace _
                    const synthetic_name = try self.generateSyntheticBinding();

                    // Clone the continuation with the new binding (preserves all metadata)
                    const new_cont = try self.cloneContinuationWithBinding(cont, synthetic_name);

                    // Replace this continuation in the flow
                    const new_flow = try self.replaceContinuationAnywhere(flow, cont, new_cont.*);

                    // Replace the flow in the program
                    const new_program = try ast_functional.replaceFlowRecursive(
                        self.allocator,
                        program,
                        flow,
                        .{ .flow = new_flow },
                    ) orelse {
                        return .{ .transformed = false, .program = program };
                    };

                    const result_ptr = try self.allocator.create(ast.Program);
                    result_ptr.* = new_program;

                    // Return transformed - the next iteration will process with the real binding
                    return .{ .transformed = true, .program = result_ptr };
                }
            }
        }

        // Handle discard on a bare-return bind (`call(...): _`) — the flat-form
        // twin of the `| tag _ |>` branch discard above. A bind that carries an
        // obligation is never a true discard: the obligation must be discharged,
        // and the inserted discharge needs a referenceable name — otherwise
        // `close(conn: _)` leaks an unusable `_` into generated Zig. Synthesize a
        // real name exactly like the branch case. Only fires when the invoked
        // event's return carries a phantom obligation; a plain `: _` with no
        // obligation stays a genuine discard (`_ = handler(...)`).
        if (mode == .full) {
            if (cont.node) |node| {
                if (node == .invocation) {
                    if (node.invocation.return_binding) |rb| {
                        if (std.mem.eql(u8, rb, "_")) {
                            const inv_name = try self.pathToString(node.invocation.path);
                            defer self.allocator.free(inv_name);
                            const inv_mod = node.invocation.path.module_qualifier orelse module_name;
                            const inv_qual = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ inv_mod, inv_name });
                            defer self.allocator.free(inv_qual);
                            // Obligation means a trailing `!` — a plain state
                            // (`<closed>`) or a state variable (`<M'_>`) owes
                            // nothing, so its `: _` stays a genuine discard.
                            // Treating every phantom as owing minted an
                            // `_auto_N` no disposal ever used (525's unused
                            // local constant). Mirrors the unbound-return
                            // seeding's `endsWith "!"` check below.
                            const carries_obligation = if (self.event_map.get(inv_qual)) |info| blk: {
                                const rp = info.decl.return_phantom orelse break :blk false;
                                break :blk std.mem.endsWith(u8, std.mem.trim(u8, rp, " \t"), "!");
                            } else false;
                            if (carries_obligation) {
                                const synthetic_name = try self.generateSyntheticBinding();
                                const new_cont = try self.cloneContinuationWithReturnBinding(cont, synthetic_name);
                                const new_flow = try self.replaceContinuationAnywhere(flow, cont, new_cont.*);
                                const new_program = try ast_functional.replaceFlowRecursive(
                                    self.allocator,
                                    program,
                                    flow,
                                    .{ .flow = new_flow },
                                ) orelse {
                                    return .{ .transformed = false, .program = program };
                                };
                                const result_ptr = try self.allocator.create(ast.Program);
                                result_ptr.* = new_program;
                                return .{ .transformed = true, .program = result_ptr };
                            }
                        }
                    }
                }
            }
        }

        // A TERMINAL invocation with NO bind at all — `make(): h |> bump(h)`,
        // where `bump` hands back a fresh obligation the chain drops. Same
        // position as an unbound flow head (`cont.continuations.len == 0` IS the
        // flow exit), and the head has materialized its implicit discard since
        // 2026-07-12. Mint the name here too, and the ordinary return_binding
        // path takes it from there — including auto-discharge.
        //
        // This inverts the 2026-07-19 mid-chain ruling, whose stated ground was
        // "an unbound value has no name to dispose, so it is NOT
        // auto-dischargeable". That ground was already false when written: this
        // is the same `generateSyntheticBinding` the `: _` case above has used
        // since a week earlier. What did NOT exist on 07-19 was the terminus
        // framing (established 07-24) under which a zero-continuation mid-chain
        // call and a bare head are the same position — so the two were ruled
        // apart by accident of sequence, not by a distinction anyone defended.
        // Every condition auto-discharge states is met here: an obligation, no
        // discharge by the author, exactly one void disposer, and a compiler
        // that proves it knows which by NAMING it in the refusal it declines to
        // replace. A name is not one of those conditions.
        //
        // Gated on `.full` deliberately: `--auto-discharge=disable` and
        // `~[strict]` opt out of INSERTING a discharger, never out of the
        // obligation being VISIBLE to enforcement. Under normalize-only the
        // seeding below still runs and KORU030 still walls it.
        if (mode == .full) {
            if (cont.continuations.len == 0) {
                if (cont.node) |node| {
                    if (node == .invocation and node.invocation.return_binding == null) {
                        const inv_name = try self.pathToString(node.invocation.path);
                        defer self.allocator.free(inv_name);
                        const inv_mod = node.invocation.path.module_qualifier orelse module_name;
                        const inv_qual = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ inv_mod, inv_name });
                        defer self.allocator.free(inv_qual);
                        const carries_obligation = if (self.event_map.get(inv_qual)) |info| blk: {
                            const rp = info.decl.return_phantom orelse break :blk false;
                            break :blk std.mem.endsWith(u8, std.mem.trim(u8, rp, " \t"), "!");
                        } else false;
                        if (carries_obligation) {
                            const synthetic_name = try self.generateSyntheticBinding();
                            const new_cont = try self.cloneContinuationWithReturnBinding(cont, synthetic_name);
                            const new_flow = try self.replaceContinuationAnywhere(flow, cont, new_cont.*);
                            const new_program = try ast_functional.replaceFlowRecursive(
                                self.allocator,
                                program,
                                flow,
                                .{ .flow = new_flow },
                            ) orelse {
                                return .{ .transformed = false, .program = program };
                            };
                            const result_ptr = try self.allocator.create(ast.Program);
                            result_ptr.* = new_program;
                            return .{ .transformed = true, .program = result_ptr };
                        }
                    }
                }
            }
        }

        // Add bindings from this branch
        if (cont.binding) |binding_name| {
            // NAMED LABEL on a bare-return callee (`create() | made c |> ...`):
            // the callee declares no branches, so the branch walk below finds
            // nothing — the label is binding sugar for `: c` (the emitter lowers
            // both spellings to the same direct bind). Credit the binding with
            // the callee's return obligation, the label twin of the mid-chain
            // `: name` recording further down.
            if (event_is_direct_callee and event_decl.branches.len == 0 and
                cont.branch.len > 0 and !std.mem.eql(u8, binding_name, "_"))
            {
                if (event_decl.return_phantom) |rp| {
                    const canonical = try self.canonicalizePhantom(rp, module_name);
                    defer self.allocator.free(canonical);
                    try context.addBinding(binding_name, canonical, "__type_ref", event_decl.return_type orelse "", self.nextAcqSeq());
                }
            }
            // Find the branch in the event declaration
            for (event_decl.branches) |branch| {
                if (std.mem.eql(u8, branch.name, cont.branch)) {
                    // Add each field with phantom annotation
                    for (branch.payload.fields) |field| {
                        if (field.phantom) |phantom_str| {
                            // For identity branches (field name is __type_ref),
                            // use just the binding name since the value IS the binding
                            // For struct branches, use binding.field_name
                            const is_identity = std.mem.eql(u8, field.name, "__type_ref");
                            const field_path = if (is_identity)
                                try self.allocator.dupe(u8, binding_name)
                            else
                                try std.fmt.allocPrint(
                                    self.allocator,
                                    "{s}.{s}",
                                    .{ binding_name, field.name },
                                );
                            defer self.allocator.free(field_path);

                            // Canonicalize phantom state with module
                            const canonical = try self.canonicalizePhantom(phantom_str, module_name);
                            defer self.allocator.free(canonical);

                            try context.addBinding(field_path, canonical, field.name, field.type, self.nextAcqSeq());
                        }
                    }
                    break;
                }
            }
        }

        // Check if this continuation has a terminal node or branch constructor
        // Both are flow terminators that should trigger auto-discharge
        if (cont.node) |node| {
            const is_terminator = (node == .terminal or node == .branch_constructor);
            if (is_terminator) {
                // Found a terminator - check for unsatisfied obligations
                // Only dispose obligations from CURRENT scope
                // Outer-scope obligations will be handled at a non-repeating terminal (like `done`)

                // IMPORTANT: For branch_constructor, check if obligations ESCAPE via the return fields
                // If an obligation is returned (e.g., got_file { file: f.file }), it should NOT be disposed
                if (node == .branch_constructor) {
                    const bc = &node.branch_constructor;
                    // Collect escaping bindings (max 16 should be plenty)
                    var escaping_bindings: [16][]const u8 = undefined;
                    var escaping_count: usize = 0;

                    var obl_iter = context.obligations();
                    while (obl_iter.next()) |entry| {
                        if (bindingEscapesViaBranchConstructor(bc, entry.key_ptr.*)) {
                            if (escaping_count < 16) {
                                escaping_bindings[escaping_count] = entry.key_ptr.*;
                                escaping_count += 1;
                            }
                        }
                    }

                    // Remove escaping obligations (they transfer to the caller)
                    for (escaping_bindings[0..escaping_count]) |binding| {
                        _ = context.cleanup_obligations.remove(binding);
                    }
                }

                if (context.hasObligations() and !context.in_sequential_prefix) {
                    // (Sequential-prefix steps are not flow exits — see in_sequential_prefix.
                    // Their obligations are discharged by the final sibling.)
                    // Count how many obligations are from current scope
                    var current_scope_count: u32 = 0;
                    var obl_iter = context.obligations();
                    while (obl_iter.next()) |entry| {
                        if (entry.value_ptr.scope_depth == context.scope_depth) {
                            current_scope_count += 1;
                        }
                    }

                    if (mode == .full) {
                        if (current_scope_count > 0) {
                            // We have current-scope obligations to dispose
                            return try self.insertDisposals(cont, &context, program, flow, event_decl, module_name);
                        }
                        // Outer-scope obligations exist but not current-scope ones
                        // In a repeating context, this is OK - they'll be handled at `done`
                        // In a non-repeating context, they should be disposed here
                        if (!context.is_repeating) {
                            // Non-repeating: dispose all remaining obligations
                            return try self.insertDisposals(cont, &context, program, flow, event_decl, module_name);
                        }
                        // Repeating: outer obligations will flow through to `done`
                    }
                }
            }

            // Check invocations for obligation satisfaction
            // (when binding is passed to <!state> parameter)
            if (node == .invocation) {
                try self.checkInvocationSatisfiesObligations(&context, &node.invocation, module_name, flow);
            }
            // A label-fold declaration `#label event(args)` seeds the loop by
            // invoking `event` once before the first iteration. Its consuming
            // (`<!X>`) inputs discharge the seed binding's obligation exactly like
            // a plain invocation — the re-issued `<X!>` obligation arrives fresh
            // on the body's output branches (`again v` / `stop r`), NOT on the
            // seed binding. Without this credit, the seed binding (e.g. `h0` in
            // `made h0 |> #loop step(h: h0)`) stays "live" at the loop's exit
            // branch and auto-discharge inserts a spurious dispose of it there —
            // while the same pointer escapes via `=> finished r` and is disposed
            // again by the caller: a double-free (330_074/084/086). The phantom
            // checker already models the seed this way (validateSingleInvocation
            // on lwi.invocation); this mirrors it. Only declarations (`#label`)
            // seed; `@label` jumps are handled by the label_jump path.
            if (node == .label_with_invocation) {
                const lwi = node.label_with_invocation;
                if (lwi.is_declaration) {
                    try self.checkInvocationSatisfiesObligations(&context, &lwi.invocation, module_name, flow);
                    try self.label_seed_map.put(lwi.label, &lwi.invocation);
                }
            }
            // A back-edge `@label(args)` re-feeds the fold's round event: its
            // args bind the SAME consuming params as the seed's, so they credit
            // discharges identically (the next iteration re-consumes). Without
            // this, the carried obligation reads live after the jump and a
            // spurious double-free disposal lands under the back edge (330_076).
            if (node == .label_jump) {
                const lj = node.label_jump;
                if (self.label_seed_map.get(lj.label)) |seed_inv| {
                    try self.creditConsumingArgs(&context, seed_inv, lj.args, module_name, flow);
                }
            }

            // Handle foreach nodes - recurse into branches with scope tracking
            if (node == .foreach) {
                const result = try self.checkForeachNode(node.foreach.branches, &context, program, flow, module_name, mode);
                if (result.transformed) return result;
            }

            // Handle conditional nodes - recurse into branches WITHOUT cloning
            // Conditionals run exactly one branch, so obligation clearing in any branch
            // should propagate to the parent context (use checkForeachBranchContinuation
            // which doesn't clone, unlike checkContinuation which does)
            if (node == .conditional) {
                const cond = &node.conditional;
                for (cond.branches) |*branch| {
                    for (branch.body) |*body_cont| {
                        const result = try self.checkForeachBranchContinuation(body_cont, &context, program, flow, module_name, mode);
                        if (result.transformed) return result;
                    }
                }
            }
        }

        // Bare-return bind: a `call(...): owned` node binds `owned` to the invoked
        // event's `-> T<phantom>` return. Record its obligation here — the
        // bare-return twin of the branch-payload binding above — so a dropped
        // `owned` (e.g. `take(s): owned` with no explicit free) is auto-discharged
        // and an explicitly-freed one is credited. Without it the transfer
        // obligation is invisible to disposal and the bound name carries no state.
        if (cont.node) |node| {
            if (node == .invocation) {
                if (node.invocation.return_binding) |rb| {
                    const rb_event_name = try self.pathToString(node.invocation.path);
                    defer self.allocator.free(rb_event_name);
                    const rb_module = node.invocation.path.module_qualifier orelse module_name;
                    const rb_qualified = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ rb_module, rb_event_name });
                    defer self.allocator.free(rb_qualified);
                    if (self.event_map.get(rb_qualified)) |info| {
                        if (info.decl.return_phantom) |rp| {
                            // Canonicalize with the call-site module qualifier (rb_module),
                            // matching the branch-payload path's use of the resolved call
                            // module — not the bare decl module.
                            const canonical = try self.canonicalizePhantom(rp, rb_module);
                            defer self.allocator.free(canonical);
                            try context.addBinding(rb, canonical, "__type_ref", info.decl.return_type orelse "", self.nextAcqSeq());
                        } else if (info.decl.return_type) |rt| {
                            // No whole-value phantom, but a MID-CHAIN record return
                            // may carry per-field obligations (`make(id): r` where
                            // make returns `{ h: *Handle<owned!>, n }`). Seed each,
                            // the continuation-level twin of the flow-head record
                            // seeding — without it a record-field obligation bound
                            // inside a for-each / subflow body is invisible and
                            // leaks silently (330_098/099/100).
                            try self.seedRecordFieldObligations(rb, rt, rb_module, node.invocation.return_destructure, &context);
                        }
                    }
                } else if (cont.continuations.len == 0) {
                    // TERMINAL invocation with NO return binding: `make(): h |>
                    // bump(h)` — bump returns a fresh `<owned!>` that the chain
                    // drops on the floor. Enforcement otherwise keys off the
                    // return_binding (or branch payloads, which require
                    // continuations), so the dangling obligation would leak
                    // silently (330_097; the continuation-level twin of the
                    // flow-head discard materialization — concept
                    // frag-obligation-enforcement-keys-off-return-binding).
                    // Seed the obligation under a synthetic, unreferencable key.
                    // An unbound value has no name to dispose, so it is NOT
                    // auto-dischargeable — it presents no disposal candidate and
                    // falls to the "was not discharged" wall (KORU030), guiding
                    // the author to bind the return and discharge it. Non-terminal
                    // unbound calls (branch arms consume the return as payload;
                    // sequential prefixes are not flow exits) are untouched.
                    const rb_event_name = try self.pathToString(node.invocation.path);
                    defer self.allocator.free(rb_event_name);
                    const rb_module = node.invocation.path.module_qualifier orelse module_name;
                    const rb_qualified = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ rb_module, rb_event_name });
                    defer self.allocator.free(rb_qualified);
                    if (self.event_map.get(rb_qualified)) |info| {
                        if (info.decl.return_phantom) |rp| {
                            if (std.mem.endsWith(u8, std.mem.trim(u8, rp, " \t"), "!")) {
                                const canonical = try self.canonicalizePhantom(rp, rb_module);
                                defer self.allocator.free(canonical);
                                const key = try std.fmt.allocPrint(self.allocator, "__unbound_return.{s}", .{rb_event_name});
                                defer self.allocator.free(key);
                                // field_name doubles as the error display name
                                // (formatBindingForError) — the synthetic key
                                // itself must never surface to the user.
                                const display = try std.fmt.allocPrint(self.allocator, "return of {s}(...)", .{rb_event_name});
                                defer self.allocator.free(display);
                                try context.addBinding(key, canonical, display, info.decl.return_type orelse "", self.nextAcqSeq());
                                if (context.cleanup_obligations.getPtr(key)) |oblig| oblig.not_auto_dischargeable = true;
                            }
                        }
                    }
                }
            }
        }

        // Check nested continuations
        for (cont.continuations, 0..) |*nested, nested_idx| {
            // For nested continuations, we need to determine the event they belong to
            // This requires looking at the node in cont (if it's an invocation)
            var nested_event = event_decl;
            var nested_module = module_name;
            var nested_event_resolved = false;

            // Multiple unnamed (`branch=''`) siblings are SEQUENTIAL steps under one
            // site (the capture lowering's body chain + after-read chain). All but
            // the last are sequential prefixes whose tails are not flow exits.
            const seq_prefix = isSequentialPrefix(cont.continuations, nested_idx);

            if (cont.node) |node| {
                if (node == .invocation) {
                    const inv_event_name = try self.pathToString(node.invocation.path);
                    defer self.allocator.free(inv_event_name);
                    const inv_module = node.invocation.path.module_qualifier orelse module_name;
                    const inv_qualified = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ inv_module, inv_event_name });
                    defer self.allocator.free(inv_qualified);

                    if (self.event_map.get(inv_qualified)) |info| {
                        nested_event = info.decl;
                        nested_module = info.module_name;
                        nested_event_resolved = true;
                    }
                }
            }

            // If this continuation has @scope annotation, treat it as a scope boundary.
            // The @scope annotation is the source of truth - not the event name.
            //
            // ALSO enter a scope for effect branches (`! line`, `! each`): they lower
            // to host loops that fire 0..N times, so they are repeating scope
            // boundaries exactly like an @scope-annotated branch. Without this, an
            // OUTER-scope obligation (e.g. a `<view!>`/`<list!>` binding from the
            // enclosing `| ok s` / `| list xs`) counts as current-scope at a terminal
            // INSIDE the effect body, so its disposal is spuriously injected into the
            // per-iteration loop body — a double-free that aborts under the safety GPA
            // and drops all output. The @scope annotation was previously the only
            // recognized loop boundary, so a stdlib effect lowering to a loop was
            // invisible to this pass.
            if (hasScope(nested) or nested.kind == .effect) {
                var scoped_context = try context.clone(self.allocator);
                defer scoped_context.deinit();
                scoped_context.enterScope(true); // @scope or effect branch = repeating scope boundary

                const result = try self.checkContinuation(nested, nested_event, nested_module, &scoped_context, program, flow, mode, nested_event_resolved);
                if (result.transformed) return result;
            } else {
                var seq_context = try context.clone(self.allocator);
                defer seq_context.deinit();
                if (seq_prefix) seq_context.in_sequential_prefix = true;

                const result = try self.checkContinuation(nested, nested_event, nested_module, &seq_context, program, flow, mode, nested_event_resolved);
                if (result.transformed) return result;
            }
        }

        // CRITICAL: If we reach end of a pipeline (no nested continuations) and this isn't
        // already a terminator, treat as implicit terminator and check obligations.
        // This handles void event chains like: ~acquire() | ok r |> print.ln("...")
        // where the flow ends without explicit `|> _`
        if (cont.continuations.len == 0) {
            const has_explicit_terminator = if (cont.node) |node|
                (node == .terminal or node == .branch_constructor)
            else
                false;

            if (!has_explicit_terminator and context.hasObligations() and !context.in_sequential_prefix) {
                // (Sequential-prefix steps are not flow exits — the flow continues
                // into the next sibling, which discharges the obligation. See
                // in_sequential_prefix. This is the spot that previously injected a
                // spurious free at the end of a `capture` body, before the
                // `| captured` after-read used the binding.)
                // Count how many obligations are from current scope
                var current_scope_count: u32 = 0;
                var obl_iter = context.obligations();
                while (obl_iter.next()) |entry| {
                    if (entry.value_ptr.scope_depth == context.scope_depth) {
                        current_scope_count += 1;
                    }
                }

                if (mode == .full) {
                    if (current_scope_count > 0) {
                        // We have current-scope obligations at end of pipeline - need to dispose
                        return try self.insertDisposals(cont, &context, program, flow, event_decl, module_name);
                    }
                    // Outer-scope obligations in repeating context will flow to `done`
                    if (!context.is_repeating) {
                        return try self.insertDisposals(cont, &context, program, flow, event_decl, module_name);
                    }
                }
            }
        }

        return .{ .transformed = false, .program = program };
    }

    /// Check a foreach node for terminators with obligations
    /// Handles scope tracking: `each` branch is repeating, `done` is not
    fn checkForeachNode(
        self: *AutoDischargeInserter,
        branches: []const ast.NamedBranch, // The foreach branches
        parent_context: *BindingContext,
        program: *const ast.Program,
        flow: *const ast.Flow,
        module_name: []const u8,
        mode: TransformMode,
    ) RecursiveError!TransformResult {
        // Increment scope BEFORE recording loop entry
        // This ensures obligations created before the loop are at a lower scope
        parent_context.scope_depth += 1;

        // Mark that we're inside a loop - obligations from before this point
        // cannot be auto-discharged inside any branch of this loop
        parent_context.enterLoop();

        // Process each branch of the foreach
        for (branches) |*branch| {
            // Check for @scope annotation (replaces old "each" branch name check)
            const is_scope_boundary = branchHasScope(branch);

            if (is_scope_boundary) {
                // Scoped branch (like "each") - clone context and enter new scope
                // Obligations cleared here don't propagate to parent (each iteration is independent)
                var branch_context = try parent_context.clone(self.allocator);
                defer branch_context.deinit();
                branch_context.enterScope(true);

                // Process continuations in this branch
                for (branch.body) |*body_cont| {
                    const result = try self.checkForeachBranchContinuation(
                        body_cont,
                        &branch_context,
                        program,
                        flow,
                        module_name,
                        mode,
                    );
                    if (result.transformed) return result;
                }

                if (mode == .scope_exit_only) {
                    // SCOPE EXIT: Check for remaining obligations that need disposal
                    // These are obligations created in this scope that weren't discharged by an explicit terminal
                    if (branch_context.hasObligations()) {
                        const ordered = try self.obligationsInLifoOrder(&branch_context);
                        defer self.allocator.free(ordered);
                        for (ordered) |entry| {
                            const binding_name = entry.binding_path;
                            const info = entry.info;

                            // Find disposal event for this obligation
                            const disposals = if (info.not_auto_dischargeable)
                try self.allocator.alloc(DisposalEvent, 0)
            else
                try self.findDisposalEvents(info.phantom_state, info.base_type);
                            defer self.allocator.free(disposals);

                            const disposal = selectDisposal(disposals) orelse {
                                const display_name = formatBindingForError(binding_name, info.field_name, info.base_type);
                                const display_state = formatStateForError(info.phantom_state);
                                if (disposals.len == 0) {
                                    // Check for multi-branch events that could dispose this
                                    const all_disposals = try self.findAllDisposalEvents(info.phantom_state, info.base_type);
                                    defer self.allocator.free(all_disposals);
                                    if (all_disposals.len > 0) {
                                        var options_buf: [512]u8 = undefined;
                                        var fbs = std.io.fixedBufferStream(&options_buf);
                                        for (all_disposals, 0..) |d, i| {
                                            if (i > 0) fbs.writer().writeAll(", ") catch {};
                                            fbs.writer().writeAll(displayDischargerName(d.qualified_name)) catch {};
                                        }
                                        if (all_disposals.len == 1) {
                                            try self.reporter.addError(
                                                .KORU030,
                                                flow.location.line,
                                                flow.location.column,
                                                "Resource '{s}' obligation <{s}> was not discharged. Call: {s}",
                                                .{ display_name, display_state, fbs.getWritten() },
                                            );
                                        } else {
                                            try self.reporter.addError(
                                                .KORU030,
                                                flow.location.line,
                                                flow.location.column,
                                                "Resource '{s}' obligation <{s}> was not discharged. Call one of: {s}",
                                                .{ display_name, display_state, fbs.getWritten() },
                                            );
                                        }
                                    } else {
                                        try self.reporter.addError(
                                            .KORU030,
                                            flow.location.line,
                                            flow.location.column,
                                            "Resource '{s}' obligation <{s}> was not discharged at scope exit.",
                                            .{ display_name, display_state },
                                        );
                                    }
                                } else {
                                    var options_buf: [512]u8 = undefined;
                                    var fbs = std.io.fixedBufferStream(&options_buf);
                                    for (disposals, 0..) |d, i| {
                                        if (i > 0) fbs.writer().writeAll(", ") catch {};
                                        const disp_name = displayDischargerName(d.qualified_name);
                                        fbs.writer().writeAll(disp_name) catch {};
                                    }
                                    try self.reporter.addError(
                                        .KORU030,
                                        flow.location.line,
                                        flow.location.column,
                                        "Resource '{s}' <{s}> has multiple discharge options: {s}. Discharge explicitly.",
                                        .{ display_name, display_state, fbs.getWritten() },
                                    );
                                }
                                return error.ValidationFailed;
                            };

                            // Find the continuation that created this binding and insert disposal
                            const result = try self.insertScopeExitDisposal(
                                branch,
                                binding_name,
                                disposal,
                                program,
                                flow,
                            );
                            if (result.transformed) return result;
                        }
                    }
                }
            } else {
                // Non-scoped branch (like "done") - use parent context directly
                // Obligations cleared here DO propagate to parent (runs once after loop)
                for (branch.body) |*body_cont| {
                    const result = try self.checkForeachBranchContinuation(
                        body_cont,
                        parent_context,
                        program,
                        flow,
                        module_name,
                        mode,
                    );
                    if (result.transformed) return result;
                }
            }
        }

        return .{ .transformed = false, .program = program };
    }

    /// Check a continuation inside a foreach branch (no event_decl binding tracking)
    /// If use_parent_directly is true, modifications affect parent_context (for non-scoped branches)
    fn checkForeachBranchContinuation(
        self: *AutoDischargeInserter,
        cont: *const ast.Continuation,
        parent_context: *BindingContext,
        program: *const ast.Program,
        flow: *const ast.Flow,
        module_name: []const u8,
        mode: TransformMode,
    ) RecursiveError!TransformResult {
        // Use parent context directly - caller is responsible for cloning if needed
        const context = parent_context;

        // Handle discard binding (_) - synthesize a real binding name
        // This must happen BEFORE we process the continuation so the binding can be used
        if (mode == .full) {
            if (cont.binding) |binding_name| {
                if (std.mem.eql(u8, binding_name, "_")) {
                    // Generate synthetic binding to replace _
                    const synthetic_name = try self.generateSyntheticBinding();

                    // Clone the continuation with the new binding (preserves all metadata)
                    const new_cont = try self.cloneContinuationWithBinding(cont, synthetic_name);

                    // Replace this continuation in the flow
                    const new_flow = try self.replaceContinuationAnywhere(flow, cont, new_cont.*);

                    // Replace the flow in the program
                    const new_program = try ast_functional.replaceFlowRecursive(
                        self.allocator,
                        program,
                        flow,
                        .{ .flow = new_flow },
                    ) orelse {
                        return .{ .transformed = false, .program = program };
                    };

                    const result_ptr = try self.allocator.create(ast.Program);
                    result_ptr.* = new_program;

                    // Return transformed - the next iteration will process with the real binding
                    return .{ .transformed = true, .program = result_ptr };
                }
            }
        }

        // Check if this continuation has a node
        if (cont.node) |node| {
            const is_terminator = (node == .terminal or node == .branch_constructor);
            if (is_terminator) {
                // Found a terminator - check for obligations to dispose
                //
                // NOTE: Pre-loop obligations in repeating context are OK here!
                // They "flow through" the loop and will be handled at the `done` branch.
                // We only error for pre-loop obligations when:
                // 1. Trying to INSERT auto-disposal (checked in insertDisposalsInForeach)
                // 2. Manually disposing via invocation (checked in checkInvocationSatisfiesObligations)

                // IMPORTANT: For branch_constructor, check if obligations ESCAPE via the return fields
                // If an obligation is returned (e.g., got_file { file: f.file }), it should NOT be disposed
                if (node == .branch_constructor) {
                    const bc = &node.branch_constructor;
                    // Collect escaping bindings (max 16 should be plenty)
                    var escaping_bindings: [16][]const u8 = undefined;
                    var escaping_count: usize = 0;

                    var obl_iter = context.obligations();
                    while (obl_iter.next()) |entry| {
                        if (bindingEscapesViaBranchConstructor(bc, entry.key_ptr.*)) {
                            if (escaping_count < 16) {
                                escaping_bindings[escaping_count] = entry.key_ptr.*;
                                escaping_count += 1;
                            }
                        }
                    }

                    // Remove escaping obligations (they transfer to the caller)
                    for (escaping_bindings[0..escaping_count]) |binding| {
                        _ = context.cleanup_obligations.remove(binding);
                    }
                }

                // Check for current-scope obligations to dispose
                if (context.hasObligations()) {
                    // Count how many obligations are from current scope
                    var current_scope_count: u32 = 0;
                    var obl_iter = context.obligations();
                    while (obl_iter.next()) |entry| {
                        if (entry.value_ptr.scope_depth == context.scope_depth) {
                            current_scope_count += 1;
                        }
                    }

                    if (mode == .full) {
                        if (current_scope_count > 0) {
                            // We have current-scope obligations to dispose
                            return try self.insertDisposalsInForeach(cont, context, program, flow);
                        }
                        // Outer-scope obligations exist but not current-scope ones
                        // In a repeating context, this is OK - they'll be handled at `done`
                        // In a non-repeating context, they should be disposed here
                        if (!context.is_repeating) {
                            // Non-repeating: dispose all remaining obligations
                            return try self.insertDisposalsInForeach(cont, context, program, flow);
                        }
                        // Repeating: outer obligations will flow through to `done`
                    }
                }
            }

            // Handle invocations - look up event and check for obligation satisfaction + binding creation
            if (node == .invocation) {
                const invocation = &node.invocation;
                try self.checkInvocationSatisfiesObligations(context, invocation, module_name, flow);

                // Also add any bindings from this invocation's continuations
                const inv_event_name = try self.pathToString(invocation.path);
                defer self.allocator.free(inv_event_name);
                const inv_module = invocation.path.module_qualifier orelse module_name;
                const inv_qualified = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ inv_module, inv_event_name });
                defer self.allocator.free(inv_qualified);

                if (self.event_map.get(inv_qualified)) |info| {
                    const event_decl = info.decl;

                    // Process nested continuations with the event's binding info
                    for (cont.continuations) |*nested| {
                        // Add binding from nested continuation if it matches event branch
                        if (nested.binding) |binding_name| {
                            for (event_decl.branches) |ev_branch| {
                                if (std.mem.eql(u8, ev_branch.name, nested.branch)) {
                                    for (ev_branch.payload.fields) |field| {
                                        if (field.phantom) |phantom_str| {
                                            // For identity branches (field name is __type_ref),
                                            // use just the binding name since the value IS the binding
                                            // For struct branches, use binding.field_name
                                            const is_identity = std.mem.eql(u8, field.name, "__type_ref");
                                            const field_path = if (is_identity)
                                                try self.allocator.dupe(u8, binding_name)
                                            else
                                                try std.fmt.allocPrint(
                                                    self.allocator,
                                                    "{s}.{s}",
                                                    .{ binding_name, field.name },
                                                );
                                            defer self.allocator.free(field_path);

                                            const canonical = try self.canonicalizePhantom(phantom_str, info.module_name);
                                            defer self.allocator.free(canonical);

                                            try context.addBinding(field_path, canonical, field.name, field.type, self.nextAcqSeq());
                                        }
                                    }
                                    break;
                                }
                            }
                        }

                        const result = try self.checkForeachBranchContinuation(nested, context, program, flow, info.module_name, mode);
                        if (result.transformed) return result;
                    }
                }
                // If event not found, still recurse into continuations
                else {
                    for (cont.continuations) |*nested| {
                        const result = try self.checkForeachBranchContinuation(nested, context, program, flow, module_name, mode);
                        if (result.transformed) return result;
                    }
                }

                // DON'T return early - fall through to end-of-pipeline check below
            }

            // Handle nested foreach
            if (node == .foreach) {
                const result = try self.checkForeachNode(node.foreach.branches, context, program, flow, module_name, mode);
                if (result.transformed) return result;
            }

            // Handle conditional
            if (node == .conditional) {
                const cond = &node.conditional;
                for (cond.branches) |*branch| {
                    for (branch.body) |*body_cont| {
                        const result = try self.checkForeachBranchContinuation(body_cont, context, program, flow, module_name, mode);
                        if (result.transformed) return result;
                    }
                }
            }
        }

        // Check nested continuations (skip if already handled by invocation processing above)
        const already_processed_continuations = if (cont.node) |n| n == .invocation else false;
        if (!already_processed_continuations) {
            for (cont.continuations) |*nested| {
                const result = try self.checkForeachBranchContinuation(nested, context, program, flow, module_name, mode);
                if (result.transformed) return result;
            }
        }

        // CRITICAL: If we reach end of a pipeline (no nested continuations) and this isn't
        // already a terminator, treat as implicit terminator and check obligations
        if (cont.continuations.len == 0) {
            const has_explicit_terminator = if (cont.node) |node|
                (node == .terminal or node == .branch_constructor)
            else
                false;

            if (!has_explicit_terminator and context.hasObligations()) {
                // Count how many obligations are from current scope
                var current_scope_count: u32 = 0;
                var obl_iter = context.obligations();
                while (obl_iter.next()) |entry| {
                    if (entry.value_ptr.scope_depth == context.scope_depth) {
                        current_scope_count += 1;
                    }
                }

                if (mode == .full) {
                    if (current_scope_count > 0) {
                        // We have current-scope obligations at end of pipeline - need to dispose
                        return try self.insertDisposalsInForeach(cont, context, program, flow);
                    }
                    // Outer-scope obligations in repeating context will flow to `done`
                    if (!context.is_repeating) {
                        return try self.insertDisposalsInForeach(cont, context, program, flow);
                    }
                }
            }
        }

        return .{ .transformed = false, .program = program };
    }

    /// Insert disposals for obligations inside a foreach (placeholder - needs AST surgery)
    fn insertDisposalsInForeach(
        self: *AutoDischargeInserter,
        cont: *const ast.Continuation,
        context: *BindingContext,
        program: *const ast.Program,
        flow: *const ast.Flow,
    ) RecursiveError!TransformResult {

        // Find obligations to dispose based on scope rules, last-acquired first (LIFO).
        const ordered = try self.obligationsInLifoOrder(context);
        defer self.allocator.free(ordered);
        for (ordered) |entry| {
            // In repeating context: only dispose current-scope obligations
            // In non-repeating context: dispose all obligations
            const should_dispose = if (context.is_repeating)
                entry.info.scope_depth == context.scope_depth
            else
                true; // Dispose all in non-repeating context

            if (should_dispose) {
                const binding_path = entry.binding_path;
                const info = entry.info;

                const disposals = if (info.not_auto_dischargeable)
                try self.allocator.alloc(DisposalEvent, 0)
            else
                try self.findDisposalEvents(info.phantom_state, info.base_type);
                defer self.allocator.free(disposals);

                // Use selectDisposal to handle [!] default annotation
                const disposal = selectDisposal(disposals) orelse {
                    // Ambiguous or no disposal found
                    const display_name = formatBindingForError(binding_path, info.field_name, info.base_type);
                    const display_state = formatStateForError(info.phantom_state);
                    if (disposals.len == 0) {
                        // Check for multi-branch events that could dispose this
                        const all_disposals = try self.findAllDisposalEvents(info.phantom_state, info.base_type);
                        defer self.allocator.free(all_disposals);
                        if (all_disposals.len > 0) {
                            var options_buf: [1024]u8 = undefined;
                            var fbs = std.io.fixedBufferStream(&options_buf);
                            for (all_disposals, 0..) |d, i| {
                                if (i > 0) fbs.writer().writeAll(", ") catch {};
                                const disp_name = displayDischargerName(d.qualified_name);
                                fbs.writer().writeAll(disp_name) catch {};
                            }
                            if (all_disposals.len == 1) {
                                try self.reporter.addError(
                                    .KORU030,
                                    flow.location.line,
                                    flow.location.column,
                                    "Resource '{s}' obligation <{s}> was not discharged. Call: {s}",
                                    .{ display_name, display_state, fbs.getWritten() },
                                );
                            } else {
                                try self.reporter.addError(
                                    .KORU030,
                                    flow.location.line,
                                    flow.location.column,
                                    "Resource '{s}' obligation <{s}> was not discharged. Call one of: {s}",
                                    .{ display_name, display_state, fbs.getWritten() },
                                );
                            }
                        } else {
                            try self.reporter.addError(
                                .KORU030,
                                flow.location.line,
                                flow.location.column,
                                "Resource '{s}' obligation <{s}> was not discharged.",
                                .{ display_name, display_state },
                            );
                        }
                    } else {
                        var options_buf: [1024]u8 = undefined;
                        var fbs = std.io.fixedBufferStream(&options_buf);
                        for (disposals, 0..) |d, i| {
                            if (i > 0) fbs.writer().writeAll(", ") catch {};
                            const disp_name = displayDischargerName(d.qualified_name);
                            fbs.writer().writeAll(disp_name) catch {};
                        }
                        try self.reporter.addError(
                            .KORU030,
                            flow.location.line,
                            flow.location.column,
                            "Resource '{s}' <{s}> has multiple discharge options: {s}. Discharge explicitly.",
                            .{ display_name, display_state, fbs.getWritten() },
                        );
                    }
                    return error.ValidationFailed;
                };

                // Emit warning about auto-discharge insertion (only in warn mode)
                if (self.warn_mode) {
                    std.debug.print("warning[AUTO-DISCHARGE]: Inserting '{s}' to discharge '{s}' (state: {s})\n", .{
                        disposal.qualified_name,
                        binding_path,
                        info.phantom_state,
                    });
                }

                // Create new continuation with disposal
                const new_cont = try self.createDisposalContinuation(cont, binding_path, disposal);

                // Find and replace this continuation in the flow
                // This is tricky because it's nested inside a foreach
                const new_flow = try self.replaceContinuationAnywhere(flow, cont, new_cont);

                const new_program = try ast_functional.replaceFlowRecursive(
                    self.allocator,
                    program,
                    flow,
                    .{ .flow = new_flow },
                ) orelse {
                    return .{ .transformed = false, .program = program };
                };

                const result_ptr = try self.allocator.create(ast.Program);
                result_ptr.* = new_program;

                return .{ .transformed = true, .program = result_ptr };
            }
        }

        return .{ .transformed = false, .program = program };
    }

    /// Check if an invocation satisfies any obligations (explicit cleanup)
    /// Also validates that manual disposal doesn't happen in repeating context for pre-loop obligations
    fn checkInvocationSatisfiesObligations(
        self: *AutoDischargeInserter,
        context: *BindingContext,
        invocation: *const ast.Invocation,
        module_name: []const u8,
        flow: *const ast.Flow,
    ) !void {
        // Look up the event being invoked
        const event_name = try self.pathToString(invocation.path);
        defer self.allocator.free(event_name);

        const inv_module = invocation.path.module_qualifier orelse module_name;
        const qualified_name = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ inv_module, event_name });
        defer self.allocator.free(qualified_name);

        const event_info = self.event_map.get(qualified_name) orelse return;
        try self.creditConsumingArgsForDecl(context, invocation.args, event_info.decl, flow);
    }

    /// Credit a back-edge `@label(args)` jump: resolve the fold's round event
    /// from the registered seed invocation and credit the JUMP's args against
    /// its consuming params, exactly as the seed's args were.
    fn creditConsumingArgs(
        self: *AutoDischargeInserter,
        context: *BindingContext,
        seed_inv: *const ast.Invocation,
        jump_args: []const ast.Arg,
        module_name: []const u8,
        flow: *const ast.Flow,
    ) !void {
        const event_name = try self.pathToString(seed_inv.path);
        defer self.allocator.free(event_name);
        const inv_module = seed_inv.path.module_qualifier orelse module_name;
        const qualified_name = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ inv_module, event_name });
        defer self.allocator.free(qualified_name);
        const event_info = self.event_map.get(qualified_name) orelse return;
        try self.creditConsumingArgsForDecl(context, jump_args, event_info.decl, flow);
    }

    /// The shared crediting walk: which args bind consuming (`<!state>`)
    /// params, and clear those obligations.
    fn creditConsumingArgsForDecl(
        self: *AutoDischargeInserter,
        context: *BindingContext,
        args: []const ast.Arg,
        event_decl: *const ast.EventDecl,
        flow: *const ast.Flow,
    ) !void {
        // Check each argument to see if it satisfies (discharges) an obligation.
        //
        // Resolving which PARAMETER an arg binds is the subtle part. A NAMED arg
        // (`free(s: owned)`) carries the param name in arg.name. A POSITIONAL arg
        // (`free(sub)`) carries the value in BOTH arg.name and arg.value — so it
        // must be matched by POSITION, not by arg.name (which is the binding, not
        // a param name). Matching positional args by name only worked when the
        // binding happened to equal the param name (`free(s)` where the binding is
        // also `s`); any other binding silently failed to discharge, producing a
        // false KORU030 on every multi-resource flow (610_011/610_012).
        for (args, 0..) |arg, arg_idx| {
            const is_positional = std.mem.eql(u8, arg.name, arg.value);
            const field_idx: ?usize = blk: {
                if (is_positional) {
                    break :blk if (arg_idx < event_decl.input.fields.len) arg_idx else null;
                }
                for (event_decl.input.fields, 0..) |f, fi| {
                    if (std.mem.eql(u8, f.name, arg.name)) break :blk fi;
                }
                break :blk null;
            };
            const field = event_decl.input.fields[field_idx orelse continue];
            const phantom_str = field.phantom orelse continue;

            var parsed = phantom_parser.PhantomState.parse(self.allocator, phantom_str) catch continue;
            defer parsed.deinit(self.allocator);

            // Check if parameter consumes obligation (concrete or any union member with ! prefix)
            const consumes = switch (parsed) {
                .concrete => |c| c.consumes_obligation,
                .state_union => |u| blk: {
                    var any = false;
                    for (u.members) |m| if (m.consumes_obligation) {
                        any = true;
                        break;
                    };
                    break :blk any;
                },
                .variable => false,
            };
            if (!consumes) continue;

            // ERROR: Cannot manually dispose outer-scope obligation inside @scope
            // boundary (loops, taps, custom constructs). is_repeating is true
            // when we're inside a @scope boundary.
            if (context.is_repeating) {
                if (context.loop_entry_scope) |scope_entry| {
                    if (context.cleanup_obligations.get(arg.value)) |obl_info| {
                        if (obl_info.scope_depth < scope_entry) {
                            try self.reporter.addError(
                                .KORU032,
                                flow.location.line,
                                flow.location.column,
                                "Cannot discharge outer-scope resource '{s}' inside @scope boundary. Handle outside the scope or escape via branch constructor.",
                                .{arg.value},
                            );
                            return error.ValidationFailed;
                        }
                    }
                }
            }

            // This parameter consumes an obligation - clear it.
            //
            // Field-granular double-discharge: a record-field projection (`s.h`)
            // that was already discharged on a prior step has vanished from the
            // record's type; discharging it again is a use-after-discharge
            // (330_109). Whole-value re-use stays with the phantom checker's
            // site-keyed detector — scope this to dotted field paths only.
            const is_field_path = std.mem.indexOfScalar(u8, arg.value, '.') != null;
            if (is_field_path and context.disposed_fields.contains(arg.value)) {
                try self.reporter.addError(
                    .KORU030,
                    flow.location.line,
                    flow.location.column,
                    "Use-after-discharge: field '{s}' was already discharged and cannot be discharged again",
                    .{arg.value},
                );
                continue;
            }
            context.clearObligation(arg.value);
            if (is_field_path) {
                const dk = try self.allocator.dupe(u8, arg.value);
                context.disposed_fields.put(dk, {}) catch self.allocator.free(dk);
            }
        }
    }

    /// Insert disposal calls for unsatisfied obligations
    fn insertDisposals(
        self: *AutoDischargeInserter,
        cont: *const ast.Continuation,
        context: *BindingContext,
        program: *const ast.Program,
        flow: *const ast.Flow,
        event_decl: *const ast.EventDecl,
        module_name: []const u8,
    ) !TransformResult {
        _ = event_decl;
        _ = module_name;

        // For each obligation (last-acquired first — LIFO / reverse-acquisition),
        // find disposal events. In repeating context, only dispose current-scope
        // obligations.
        const ordered = try self.obligationsInLifoOrder(context);
        defer self.allocator.free(ordered);
        for (ordered) |entry| {
            const binding_path = entry.binding_path;
            const info = entry.info;

            // Skip outer-scope obligations in repeating context
            if (context.is_repeating and info.scope_depth < context.scope_depth) {
                continue;
            }

            const disposals = if (info.not_auto_dischargeable)
                try self.allocator.alloc(DisposalEvent, 0)
            else
                try self.findDisposalEvents(info.phantom_state, info.base_type);
            defer self.allocator.free(disposals);

            // Use selectDisposal to handle [!] default annotation
            const disposal = selectDisposal(disposals) orelse {
                // Ambiguous or no disposal found
                const display_name = formatBindingForError(binding_path, info.field_name, info.base_type);
                const display_state = formatStateForError(info.phantom_state);
                if (disposals.len == 0) {
                    // No auto-dischargeable events - check if there are multi-branch events that accept this state
                    const all_disposals = try self.findAllDisposalEvents(info.phantom_state, info.base_type);
                    defer self.allocator.free(all_disposals);
                    if (all_disposals.len > 0) {
                        var options_buf: [1024]u8 = undefined;
                        var fbs = std.io.fixedBufferStream(&options_buf);
                        for (all_disposals, 0..) |d, i| {
                            if (i > 0) fbs.writer().writeAll(", ") catch {};
                            const disp_name = displayDischargerName(d.qualified_name);
                            fbs.writer().writeAll(disp_name) catch {};
                        }
                        if (all_disposals.len == 1) {
                            try self.reporter.addError(
                                .KORU030,
                                flow.location.line,
                                flow.location.column,
                                "Resource '{s}' obligation <{s}> was not discharged. Call: {s}",
                                .{ display_name, display_state, fbs.getWritten() },
                            );
                        } else {
                            try self.reporter.addError(
                                .KORU030,
                                flow.location.line,
                                flow.location.column,
                                "Resource '{s}' obligation <{s}> was not discharged. Call one of: {s}",
                                .{ display_name, display_state, fbs.getWritten() },
                            );
                        }
                    } else {
                        // Strip trailing `!` from the state literal for the consumer-form suggestion:
                        // the obligation is on `<unsanitized!>`; the discharger accepts `<!unsanitized>`.
                        const state_without_bang = if (std.mem.endsWith(u8, display_state, "!"))
                            display_state[0 .. display_state.len - 1]
                        else
                            display_state;
                        try self.reporter.addError(
                            .KORU030,
                            flow.location.line,
                            flow.location.column,
                            "Resource '{s}' obligation <{s}> was not discharged. No tor accepts <!{s}>.",
                            .{ display_name, display_state, state_without_bang },
                        );
                    }
                } else {
                    var options_buf: [1024]u8 = undefined;
                    var fbs = std.io.fixedBufferStream(&options_buf);
                    for (disposals, 0..) |d, i| {
                        if (i > 0) fbs.writer().writeAll(", ") catch {};
                        const disp_name = displayDischargerName(d.qualified_name);
                        fbs.writer().writeAll(disp_name) catch {};
                    }
                    try self.reporter.addError(
                        .KORU030,
                        flow.location.line,
                        flow.location.column,
                        "Resource '{s}' <{s}> has multiple discharge options: {s}. Discharge explicitly.",
                        .{ display_name, display_state, fbs.getWritten() },
                    );
                }
                return error.ValidationFailed;
            };

            // Emit warning about auto-discharge insertion (only in warn mode)
            if (self.warn_mode) {
                std.debug.print("warning[AUTO-DISCHARGE]: Inserting '{s}' to discharge '{s}' (state: {s})\n", .{
                    disposal.qualified_name,
                    binding_path,
                    info.phantom_state,
                });
            }

            // Create the transformed continuation
            const new_cont = try self.createDisposalContinuation(
                cont,
                binding_path,
                disposal,
            );

            // Replace in the flow - use replaceContinuationAnywhere to handle nested continuations
            const new_flow = try self.replaceContinuationAnywhere(flow, cont, new_cont);

            // Mark flow as processed

            // Replace in program
            const new_program = try ast_functional.replaceFlowRecursive(
                self.allocator,
                program,
                flow,
                .{ .flow = new_flow },
            ) orelse {
                return .{ .transformed = false, .program = program };
            };

            const result_ptr = try self.allocator.create(ast.Program);
            result_ptr.* = new_program;

            return .{ .transformed = true, .program = result_ptr };
        }

        return .{ .transformed = false, .program = program };
    }

    /// Check if an event has the [!] annotation (marks it as default for auto-discharge)
    fn eventHasDefaultAnnotation(event_decl: *const ast.EventDecl) bool {
        for (event_decl.annotations) |ann| {
            if (std.mem.eql(u8, ann, "!")) return true;
        }
        return false;
    }

    /// Default auto-discharge targets must be void — inserted at scope exit with
    /// no branch dispatch and no bind for an output. Non-void comes in TWO
    /// spellings: named branches AND the single-return `-> T` bare return
    /// (an EventDecl has either return_type or branches, never both — ast.zig).
    /// Both disqualify: the inserter appends a bare call and cannot synthesize
    /// the bind either output form requires (the same rule findDisposalEventsEx
    /// applies when selecting candidates).
    fn validateDefaultDischargeEvent(self: *AutoDischargeInserter, event_decl: *const ast.EventDecl) !void {
        if (eventHasDefaultAnnotation(event_decl) and
            (event_decl.branches.len > 0 or event_decl.return_type != null))
        {
            try self.reporter.addError(
                .KORU083,
                event_decl.location.line,
                event_decl.location.column,
                "[!] annotation requires a void tor (no branches, no `-> T` return) - a tor with output cannot be auto-inserted",
                .{},
            );
        }
    }

    /// Select the disposal to use from a list of candidates
    /// Returns the single disposal if unambiguous, or null if ambiguous/none
    /// Selection logic:
    /// - 1 disposal → use it
    /// - Multiple disposals → filter to [!] annotated ones
    ///   - 1 default → use it
    ///   - 0 or >1 defaults → ambiguous (return null)
    fn selectDisposal(disposals: []const DisposalEvent) ?DisposalEvent {
        return pickUnattendedDischarge(DisposalEvent, disposals, struct {
            fn declOf(d: DisposalEvent) *const ast.EventDecl {
                return d.event_decl;
            }
        }.declOf);
    }

    /// Find all events that can dispose a given phantom state for a given base type
    /// If include_multi_branch is true, includes events with multiple branches (for error reporting)
    /// base_type filters to events where the parameter type matches (e.g., "*Connection")
    fn findDisposalEventsEx(self: *AutoDischargeInserter, phantom_state: []const u8, base_type: []const u8, include_multi_branch: bool) ![]DisposalEvent {
        var results = try std.ArrayList(DisposalEvent).initCapacity(self.allocator, 4);

        // Strip the ! suffix to get base state
        var base_state = phantom_state;
        if (std.mem.endsWith(u8, base_state, "!")) {
            base_state = base_state[0 .. base_state.len - 1];
        }

        // Search all events for <!state> parameters
        var iter = self.event_map.iterator();
        while (iter.next()) |entry| {
            const event_decl = entry.value_ptr.decl;

            // Auto-discharge can only insert a VOID event (no continuation branch
            // AND no bare `-> T` return): the inserter appends a bare call, and any
            // output — a branch (re-issued obligation OR plain value/error) or a
            // bare-return value/transfer-obligation — needs a bind it can't
            // synthesize. So ANY output disqualifies the event from auto-insertion
            // (KORU083). A bare-return transfer like `take` (`-> *String<instance!>`)
            // hands back a NEW obligation, so it never discharges — it must not be
            // auto-inserted as a disposer. The error-suggestion path
            // (include_multi_branch) still lists branched dischargers so the user can
            // call one explicitly.
            if (!include_multi_branch and (event_decl.branches.len > 0 or event_decl.return_type != null)) continue;

            // Self-loop suggestion filter: an event that consumes <state!> on
            // base_type but ALSO re-issues <state!> on the same base_type through
            // an output branch never discharges the obligation — calling it just
            // hands back another one (`tx.exec`: active! -> active!). It must never
            // be named as a disposer. Only the suggestion path needs this; the
            // auto-insert path already excludes such events via the void filter.
            if (include_multi_branch and self.eventReIssuesObligation(event_decl, base_state, base_type)) continue;

            const is_default = eventHasDefaultAnnotation(event_decl);

            for (event_decl.input.fields) |field| {
                if (field.phantom) |field_phantom| {
                    // Filter by base type: the field's type must match the obligation's base type
                    // This ensures close(*Connection<!active>) only matches *Connection obligations,
                    // not *Transaction obligations that also have an "active" phantom state
                    if (!std.mem.eql(u8, field.type, base_type)) continue;

                    // Parse to check if it consumes this state
                    var parsed = phantom_parser.PhantomState.parse(self.allocator, field_phantom) catch continue;
                    defer parsed.deinit(self.allocator);

                    switch (parsed) {
                        .concrete => |concrete| {
                            if (concrete.consumes_obligation) {
                                // Build full state name - canonicalize using event's module if no module specified
                                const consumer_state = if (concrete.module_path) |mod|
                                    try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ mod, concrete.name })
                                else
                                    // Use event's module to canonicalize
                                    try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ entry.value_ptr.module_name, concrete.name });
                                defer self.allocator.free(consumer_state);

                                if (std.mem.eql(u8, consumer_state, base_state)) {
                                    if (!include_multi_branch and !eventCanBeAutoInserted(event_decl, field.name)) {
                                        continue;
                                    }
                                    try results.append(self.allocator, .{
                                        .qualified_name = try self.allocator.dupe(u8, entry.key_ptr.*),
                                        .event_decl = event_decl,
                                        .field_name = try self.allocator.dupe(u8, field.name),
                                        .is_default = is_default,
                                    });
                                }
                            }
                        },
                        .variable => {},
                        .state_union => |u| {
                            // Only members with ! can discharge an obligation
                            for (u.members) |member| {
                                if (!member.consumes_obligation) continue;
                                const consumer_state = if (member.module_path) |mod|
                                    try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ mod, member.name })
                                else
                                    try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ entry.value_ptr.module_name, member.name });
                                defer self.allocator.free(consumer_state);

                                if (std.mem.eql(u8, consumer_state, base_state)) {
                                    if (!include_multi_branch and !eventCanBeAutoInserted(event_decl, field.name)) {
                                        break;
                                    }
                                    try results.append(self.allocator, .{
                                        .qualified_name = try self.allocator.dupe(u8, entry.key_ptr.*),
                                        .event_decl = event_decl,
                                        .field_name = try self.allocator.dupe(u8, field.name),
                                        .is_default = is_default,
                                    });
                                    break; // Found a match, don't add duplicates
                                }
                            }
                        },
                    }
                }
            }
        }

        return results.toOwnedSlice(self.allocator);
    }

    /// True if `event_decl` re-issues `<base_state!>` on `base_type` through one of
    /// its output branches — a self-loop on the obligation it consumes. Such an
    /// event (e.g. `tx.exec`: consumes active! and outputs `*Transaction<active!>`)
    /// can never discharge the obligation, so it must be excluded from the disposer
    /// suggestion list. A genuine forward-transition disposer like `tx.commit`
    /// issues its obligation on a DIFFERENT type (`*Connection`), so it is kept.
    fn eventReIssuesObligation(self: *AutoDischargeInserter, event_decl: *const ast.EventDecl, base_state: []const u8, base_type: []const u8) bool {
        // `base_state` is module-qualified (e.g. "app.db:active"); output-branch
        // phantoms carry the bare state name ("active"). Compare against the tail.
        // The `base_type` equality below guards against cross-module collisions.
        const base_state_name = if (std.mem.lastIndexOfScalar(u8, base_state, ':')) |idx|
            base_state[idx + 1 ..]
        else
            base_state;
        // Bare-return re-issue: after the single-return migration a transition
        // like tx.exec (`consumes <!active>` → `-> *Transaction<active!>`) hands
        // back its obligation through the bare return, not a branch. It never
        // discharges, so exclude it here the same way branch re-issuers are.
        if (event_decl.return_type) |rt| {
            if (std.mem.eql(u8, rt, base_type)) {
                if (event_decl.return_phantom) |rp| {
                    if (phantom_parser.PhantomState.parse(self.allocator, rp)) |*parsed_ret| {
                        defer @constCast(parsed_ret).deinit(self.allocator);
                        switch (parsed_ret.*) {
                            .concrete => |concrete| {
                                if (concrete.requires_cleanup and std.mem.eql(u8, concrete.name, base_state_name)) return true;
                            },
                            .state_union => |u| {
                                for (u.members) |member| {
                                    if (member.requires_cleanup and std.mem.eql(u8, member.name, base_state_name)) return true;
                                }
                            },
                            .variable => {},
                        }
                    } else |_| {}
                }
            }
        }
        for (event_decl.branches) |branch| {
            for (branch.payload.fields) |field| {
                if (!std.mem.eql(u8, field.type, base_type)) continue;
                const field_phantom = field.phantom orelse continue;
                var parsed = phantom_parser.PhantomState.parse(self.allocator, field_phantom) catch continue;
                defer parsed.deinit(self.allocator);
                switch (parsed) {
                    .concrete => |concrete| {
                        if (concrete.requires_cleanup and std.mem.eql(u8, concrete.name, base_state_name)) return true;
                    },
                    .state_union => |u| {
                        for (u.members) |member| {
                            if (member.requires_cleanup and std.mem.eql(u8, member.name, base_state_name)) return true;
                        }
                    },
                    .variable => {},
                }
            }
        }
        return false;
    }

    /// Auto-insert at scope exit can fill the obligation parameter from the binding.
    /// Every other input must be auto-fillable without user authorship — not
    /// "exactly one field", but "no user-required fields we don't have a value for".
    fn eventCanBeAutoInserted(event_decl: *const ast.EventDecl, obligation_field_name: []const u8) bool {
        for (event_decl.input.fields) |input_field| {
            if (std.mem.eql(u8, input_field.name, obligation_field_name)) continue;
            if (!inputFieldAutoFillableAtScopeExit(input_field)) return false;
        }
        return true;
    }

    /// Parameters the inserter may omit or synthesize without user input.
    fn inputFieldAutoFillableAtScopeExit(field: ast.Field) bool {
        // Optional event inputs (?T) need no call-site value.
        if (field.type.len > 0 and field.type[0] == '?') return true;
        // Nor does one carrying a default — the surface supports them on shapes
        // now, as a parsed `Field.default` rather than a tail left on the type.
        if (field.default != null) return true;
        return false;
    }

    /// Find all events that can dispose a given phantom state (auto-dischargeable only)
    pub fn findDisposalEvents(self: *AutoDischargeInserter, phantom_state: []const u8, base_type: []const u8) ![]DisposalEvent {
        return self.findDisposalEventsEx(phantom_state, base_type, false);
    }

    /// Find all events that accept a given phantom state (including multi-branch, for error messages)
    fn findAllDisposalEvents(self: *AutoDischargeInserter, phantom_state: []const u8, base_type: []const u8) ![]DisposalEvent {
        return self.findDisposalEventsEx(phantom_state, base_type, true);
    }

    /// Create a new continuation with disposal call inserted at the end
    /// Handles two cases:
    /// 1. Original node is a terminator → insert disposal before terminal
    /// 2. Original node is an invocation (void event) → append disposal after invocation
    fn createDisposalContinuation(
        self: *AutoDischargeInserter,
        original: *const ast.Continuation,
        binding_path: []const u8,
        disposal: DisposalEvent,
    ) !ast.Continuation {
        // Parse disposal event name to get path components
        const colon_idx = std.mem.indexOf(u8, disposal.qualified_name, ":") orelse 0;
        const disposal_module = disposal.qualified_name[0..colon_idx];
        const disposal_event = disposal.qualified_name[colon_idx + 1 ..];

        // Create invocation for disposal call
        const segments = try self.eventNameToSegments(disposal_event);

        var args = try self.allocator.alloc(ast.Arg, 1);
        args[0] = .{
            .name = try self.allocator.dupe(u8, disposal.field_name),
            .value = try self.allocator.dupe(u8, binding_path),
            .expression_value = null,
            .source_value = null,
        };

        const disposal_invocation = ast.Invocation{
            .path = .{
                .segments = segments,
                .module_qualifier = try self.allocator.dupe(u8, disposal_module),
            },
            .args = args,
            .annotations = &[_][]const u8{},
        };

        // Check if original node is a terminator or an invocation
        const original_is_terminator = if (original.node) |node|
            (node == .terminal or node == .branch_constructor)
        else
            true; // null node treated as implicit terminal

        // Handle disposal event being void (no branches) vs having branches
        const disposal_is_void = disposal.event_decl.branches.len == 0;

        if (original_is_terminator) {
            if (disposal_is_void) {
                // Void disposal replacing a terminal. Two sub-cases:
                //   .terminal           — `|> _`, no value to preserve, flat result.
                //   .branch_constructor — `|> result "x"`, the constructor IS the
                //                         subflow's return value and must survive
                //                         the discharge. Chain it after the disposal.
                const preserves_value = original.node != null and
                    original.node.? == .branch_constructor;
                const child_conts = if (preserves_value) blk: {
                    var cont = try self.allocator.alloc(ast.Continuation, 1);
                    cont[0] = .{
                        .branch = "",
                        .binding = null,
                        .binding_annotations = &[_][]const u8{},
                        .condition = null,
                        .node = original.node,
                        .indent = original.indent + 1,
                        .continuations = &[_]ast.Continuation{},
                        .location = original.location,
                    };
                    break :blk @as([]const ast.Continuation, cont);
                } else &[_]ast.Continuation{};
                return .{
                    .branch = try self.allocator.dupe(u8, original.branch),
                    .binding = if (original.binding) |b| try self.allocator.dupe(u8, b) else null,
                    .destructure = try ast.copyDestructure(self.allocator, original.destructure),
                    .binding_annotations = original.binding_annotations,
                    .condition = if (original.condition) |c| try self.allocator.dupe(u8, c) else null,
                    .node = .{ .invocation = disposal_invocation },
                    .indent = original.indent,
                    .continuations = child_conts,
                    .location = original.location,
                    .kind = original.kind, // preserve effect-handler classification
                };
            } else {
                // Disposal event with branches - nest terminal as child
                var disposal_branch: []const u8 = "done";
                for (disposal.event_decl.branches) |branch| {
                    disposal_branch = branch.name;
                    break;
                }
                var after_disposal_cont = try self.allocator.alloc(ast.Continuation, 1);
                after_disposal_cont[0] = .{
                    .branch = try self.allocator.dupe(u8, disposal_branch),
                    .binding = try self.allocator.dupe(u8, "_"),
                    .binding_annotations = &[_][]const u8{},
                    .condition = null,
                    .node = original.node, // Preserve original terminal
                    .indent = original.indent + 1,
                    .continuations = &[_]ast.Continuation{},
                    .location = original.location,
                };

                return .{
                    .branch = try self.allocator.dupe(u8, original.branch),
                    .binding = if (original.binding) |b| try self.allocator.dupe(u8, b) else null,
                    .destructure = try ast.copyDestructure(self.allocator, original.destructure),
                    .binding_annotations = original.binding_annotations,
                    .condition = if (original.condition) |c| try self.allocator.dupe(u8, c) else null,
                    .node = .{ .invocation = disposal_invocation },
                    .indent = original.indent,
                    .continuations = after_disposal_cont,
                    .location = original.location,
                    .kind = original.kind, // preserve effect-handler classification
                };
            }
        } else {
            // Case 2: Original is an invocation (void event chain)
            // Need to: keep original invocation, append disposal after it
            // Result: original_invocation() |> disposal() |> _

            // Create disposal continuation after the original invocation.
            // For void disposal events, use a flat structure (no children) to match
            // what the parser produces for explicit hand-written void calls.
            // For disposal events with branches, nest the terminal inside.
            const disposal_cont = if (disposal_is_void) ast.Continuation{
                .branch = "", // void continuation after original invocation
                .binding = null,
                .binding_annotations = &[_][]const u8{},
                .condition = null,
                .node = .{ .invocation = disposal_invocation },
                .indent = original.indent + 1,
                .continuations = &[_]ast.Continuation{},
                .location = original.location,
            } else blk: {
                var disposal_branch: []const u8 = "done";
                for (disposal.event_decl.branches) |branch| {
                    disposal_branch = branch.name;
                    break;
                }
                var disposal_cont_children = try self.allocator.alloc(ast.Continuation, 1);
                disposal_cont_children[0] = .{
                    .branch = try self.allocator.dupe(u8, disposal_branch),
                    .binding = try self.allocator.dupe(u8, "_"),
                    .binding_annotations = &[_][]const u8{},
                    .condition = null,
                    .node = .{ .terminal = {} },
                    .indent = original.indent + 2,
                    .continuations = &[_]ast.Continuation{},
                    .location = original.location,
                };
                break :blk ast.Continuation{
                    .branch = "", // void continuation after original invocation
                    .binding = null,
                    .binding_annotations = &[_][]const u8{},
                    .condition = null,
                    .node = .{ .invocation = disposal_invocation },
                    .indent = original.indent + 1,
                    .continuations = disposal_cont_children,
                    .location = original.location,
                };
            };

            // Create new continuations array: [disposal_cont]
            var new_continuations = try self.allocator.alloc(ast.Continuation, 1);
            new_continuations[0] = disposal_cont;

            // Return original invocation with disposal appended
            return .{
                .branch = try self.allocator.dupe(u8, original.branch),
                .binding = if (original.binding) |b| try self.allocator.dupe(u8, b) else null,
                .binding_annotations = original.binding_annotations,
                .condition = if (original.condition) |c| try self.allocator.dupe(u8, c) else null,
                .node = original.node, // Keep original invocation!
                .indent = original.indent,
                .continuations = new_continuations,
                .location = original.location,
                // Preserve effect-ness: this continuation REPLACES the original
                // handler, so the emitter must still classify `! NAME` as an
                // effect-handler member (not a terminal switch arm). Dropping
                // .kind defaulted it to .terminal → "Handlers_0 has no member".
                .kind = original.kind,
            };
        }
    }

    /// Insert disposal at scope exit for a binding
    /// Finds the continuation with the given binding and adds disposal to its continuations
    fn insertScopeExitDisposal(
        self: *AutoDischargeInserter,
        branch: *const ast.NamedBranch,
        binding_name: []const u8,
        disposal: DisposalEvent,
        program: *const ast.Program,
        flow: *const ast.Flow,
    ) RecursiveError!TransformResult {
        // Extract base binding name (before any field access like `.file`)
        // e.g., "_auto_1.file" -> "_auto_1"
        const base_binding = if (std.mem.indexOf(u8, binding_name, ".")) |dot_idx|
            binding_name[0..dot_idx]
        else
            binding_name;

        // Find the continuation that has this binding
        const target_cont = self.findContinuationByBinding(branch.body, base_binding) orelse {
            // Binding not found - might be a synthetic binding from discard or nested structure
            return .{ .transformed = false, .program = program };
        };

        // Create disposal invocation
        const colon_idx = std.mem.indexOf(u8, disposal.qualified_name, ":") orelse 0;
        const disposal_module = disposal.qualified_name[0..colon_idx];
        const disposal_event = disposal.qualified_name[colon_idx + 1 ..];

        const segments = try self.eventNameToSegments(disposal_event);

        var args = try self.allocator.alloc(ast.Arg, 1);
        args[0] = .{
            .name = try self.allocator.dupe(u8, disposal.field_name),
            .value = try self.allocator.dupe(u8, binding_name),
            .expression_value = null,
            .source_value = null,
        };

        const disposal_invocation = ast.Invocation{
            .path = .{
                .segments = segments,
                .module_qualifier = try self.allocator.dupe(u8, disposal_module),
            },
            .args = args,
            .annotations = &[_][]const u8{},
        };

        // Create disposal continuation with terminal
        const disposal_is_void = disposal.event_decl.branches.len == 0;
        var disposal_branch_name: []const u8 = "";
        if (!disposal_is_void) {
            for (disposal.event_decl.branches) |b| {
                disposal_branch_name = b.name;
                break;
            }
        }

        var terminal_conts = try self.allocator.alloc(ast.Continuation, 1);
        terminal_conts[0] = .{
            .branch = if (disposal_is_void) "" else try self.allocator.dupe(u8, disposal_branch_name),
            .binding = if (disposal_is_void) null else try self.allocator.dupe(u8, "_"),
            .binding_annotations = &[_][]const u8{},
            .condition = null,
            .node = .{ .terminal = {} },
            .indent = target_cont.indent + 2,
            .continuations = &[_]ast.Continuation{},
            .location = target_cont.location,
        };

        const disposal_cont = ast.Continuation{
            .branch = "", // void continuation
            .binding = null,
            .binding_annotations = &[_][]const u8{},
            .condition = null,
            .node = .{ .invocation = disposal_invocation },
            .indent = target_cont.indent + 1,
            .continuations = terminal_conts,
            .location = target_cont.location,
        };

        // Create new continuation with disposal appended to its continuations
        var new_conts = try self.allocator.alloc(ast.Continuation, target_cont.continuations.len + 1);
        for (target_cont.continuations, 0..) |c, i| {
            new_conts[i] = try ast_functional.cloneContinuation(self.allocator, &c);
        }
        new_conts[target_cont.continuations.len] = disposal_cont;

        const new_target_cont = ast.Continuation{
            .branch = try self.allocator.dupe(u8, target_cont.branch),
            .binding = if (target_cont.binding) |b| try self.allocator.dupe(u8, b) else null,
            .destructure = try ast.copyDestructure(self.allocator, target_cont.destructure),
            .binding_annotations = target_cont.binding_annotations,
            .condition = if (target_cont.condition) |c| try self.allocator.dupe(u8, c) else null,
            .node = target_cont.node,
            .indent = target_cont.indent,
            .continuations = new_conts,
            .location = target_cont.location,
        };

        // Replace the continuation in the flow
        const new_flow = try self.replaceContinuationAnywhere(flow, target_cont, new_target_cont);

        const new_program = try ast_functional.replaceFlowRecursive(
            self.allocator,
            program,
            flow,
            .{ .flow = new_flow },
        ) orelse {
            return .{ .transformed = false, .program = program };
        };

        const result_ptr = try self.allocator.create(ast.Program);
        result_ptr.* = new_program;

        if (self.warn_mode) {
            std.debug.print("warning[AUTO-DISCHARGE]: Inserting '{s}' at scope exit for '{s}'\n", .{
                disposal.qualified_name,
                binding_name,
            });
        }

        return .{ .transformed = true, .program = result_ptr };
    }

    /// Insert disposal at scope exit for a binding within a continuation (for flow-level scopes)
    fn insertScopeExitDisposalInCont(
        self: *AutoDischargeInserter,
        cont: *const ast.Continuation,
        binding_name: []const u8,
        disposal: DisposalEvent,
        program: *const ast.Program,
        flow: *const ast.Flow,
    ) RecursiveError!TransformResult {
        // Search for the continuation with this binding starting from the given cont
        const target_cont = if (cont.binding) |b|
            if (std.mem.eql(u8, b, binding_name)) cont else self.findContinuationInCont(cont, binding_name)
        else
            self.findContinuationInCont(cont, binding_name);

        const actual_target = target_cont orelse {
            return .{ .transformed = false, .program = program };
        };

        // Create disposal invocation
        const colon_idx = std.mem.indexOf(u8, disposal.qualified_name, ":") orelse 0;
        const disposal_module = disposal.qualified_name[0..colon_idx];
        const disposal_event = disposal.qualified_name[colon_idx + 1 ..];

        const segments = try self.eventNameToSegments(disposal_event);

        var args = try self.allocator.alloc(ast.Arg, 1);
        args[0] = .{
            .name = try self.allocator.dupe(u8, disposal.field_name),
            .value = try self.allocator.dupe(u8, binding_name),
            .expression_value = null,
            .source_value = null,
        };

        const disposal_invocation = ast.Invocation{
            .path = .{
                .segments = segments,
                .module_qualifier = try self.allocator.dupe(u8, disposal_module),
            },
            .args = args,
            .annotations = &[_][]const u8{},
        };

        // Create disposal continuation with terminal
        const disposal_is_void = disposal.event_decl.branches.len == 0;
        var disposal_branch_name: []const u8 = "";
        if (!disposal_is_void) {
            for (disposal.event_decl.branches) |b| {
                disposal_branch_name = b.name;
                break;
            }
        }

        var terminal_conts = try self.allocator.alloc(ast.Continuation, 1);
        terminal_conts[0] = .{
            .branch = if (disposal_is_void) "" else try self.allocator.dupe(u8, disposal_branch_name),
            .binding = if (disposal_is_void) null else try self.allocator.dupe(u8, "_"),
            .binding_annotations = &[_][]const u8{},
            .condition = null,
            .node = .{ .terminal = {} },
            .indent = actual_target.indent + 2,
            .continuations = &[_]ast.Continuation{},
            .location = actual_target.location,
        };

        const disposal_cont = ast.Continuation{
            .branch = "",
            .binding = null,
            .binding_annotations = &[_][]const u8{},
            .condition = null,
            .node = .{ .invocation = disposal_invocation },
            .indent = actual_target.indent + 1,
            .continuations = terminal_conts,
            .location = actual_target.location,
        };

        // Append disposal to target's continuations
        var new_conts = try self.allocator.alloc(ast.Continuation, actual_target.continuations.len + 1);
        for (actual_target.continuations, 0..) |c, i| {
            new_conts[i] = try ast_functional.cloneContinuation(self.allocator, &c);
        }
        new_conts[actual_target.continuations.len] = disposal_cont;

        const new_target_cont = ast.Continuation{
            .branch = try self.allocator.dupe(u8, actual_target.branch),
            .binding = if (actual_target.binding) |b| try self.allocator.dupe(u8, b) else null,
            .destructure = try ast.copyDestructure(self.allocator, actual_target.destructure),
            .binding_annotations = actual_target.binding_annotations,
            .condition = if (actual_target.condition) |c| try self.allocator.dupe(u8, c) else null,
            .node = actual_target.node,
            .indent = actual_target.indent,
            .continuations = new_conts,
            .location = actual_target.location,
        };

        const new_flow = try self.replaceContinuationAnywhere(flow, actual_target, new_target_cont);

        const new_program = try ast_functional.replaceFlowRecursive(
            self.allocator,
            program,
            flow,
            .{ .flow = new_flow },
        ) orelse {
            return .{ .transformed = false, .program = program };
        };

        const result_ptr = try self.allocator.create(ast.Program);
        result_ptr.* = new_program;

        if (self.warn_mode) {
            std.debug.print("warning[AUTO-DISCHARGE]: Inserting '{s}' at scope exit for '{s}'\n", .{
                disposal.qualified_name,
                binding_name,
            });
        }

        return .{ .transformed = true, .program = result_ptr };
    }

    /// Find a continuation with a specific binding within a continuation tree
    fn findContinuationInCont(self: *AutoDischargeInserter, cont: *const ast.Continuation, binding_name: []const u8) ?*const ast.Continuation {
        _ = self;
        // Check nested continuations
        if (cont.continuations.len > 0) {
            if (findContinuationByBindingRecursive(cont.continuations, binding_name)) |found| {
                return found;
            }
        }
        // Check node's nested structures
        if (cont.node) |node| {
            switch (node) {
                .foreach => |fe| {
                    for (fe.branches) |*branch| {
                        if (findContinuationByBindingRecursive(branch.body, binding_name)) |found| {
                            return found;
                        }
                    }
                },
                .conditional => |cond| {
                    for (cond.branches) |*branch| {
                        if (findContinuationByBindingRecursive(branch.body, binding_name)) |found| {
                            return found;
                        }
                    }
                },
                else => {},
            }
        }
        return null;
    }

    /// Find a continuation that has a specific binding name
    fn findContinuationByBinding(self: *AutoDischargeInserter, conts: []const ast.Continuation, binding_name: []const u8) ?*const ast.Continuation {
        _ = self;
        for (conts) |*cont| {
            if (cont.binding) |b| {
                if (std.mem.eql(u8, b, binding_name)) {
                    return cont;
                }
            }
            // Recursively search in nested continuations
            if (cont.continuations.len > 0) {
                if (findContinuationByBindingRecursive(cont.continuations, binding_name)) |found| {
                    return found;
                }
            }
            // Search in node's nested structures
            if (cont.node) |node| {
                switch (node) {
                    .invocation => |inv| {
                        _ = inv;
                        // Invocations have their continuations in cont.continuations, already searched
                    },
                    .foreach => |fe| {
                        for (fe.branches) |*branch| {
                            if (findContinuationByBindingRecursive(branch.body, binding_name)) |found| {
                                return found;
                            }
                        }
                    },
                    .conditional => |cond| {
                        for (cond.branches) |*branch| {
                            if (findContinuationByBindingRecursive(branch.body, binding_name)) |found| {
                                return found;
                            }
                        }
                    },
                    else => {},
                }
            }
        }
        return null;
    }

    /// Replace a continuation in a flow
    fn replaceContInFlow(
        self: *AutoDischargeInserter,
        flow: *const ast.Flow,
        old_cont: *const ast.Continuation,
        new_cont: ast.Continuation,
    ) !ast.Flow {
        var new_continuations = try self.allocator.alloc(ast.Continuation, flow.body.continuations.len);

        for (flow.body.continuations, 0..) |*cont, i| {
            if (@intFromPtr(cont) == @intFromPtr(old_cont)) {
                new_continuations[i] = new_cont;
            } else {
                new_continuations[i] = try ast_functional.cloneContinuation(self.allocator, cont);
            }
        }

        // Clone annotations
        var new_annotations = try self.allocator.alloc([]const u8, flow.annotations.len);
        for (flow.annotations, 0..) |ann, i| {
            new_annotations[i] = try self.allocator.dupe(u8, ann);
        }

        return .{
            .body = ast.rootSite(try ast_functional.cloneInvocation(self.allocator, flow.inv()), new_continuations, flow.location),
            .annotations = new_annotations,
            .pre_label = if (flow.pre_label) |l| try self.allocator.dupe(u8, l) else null,
            .super_shape = flow.super_shape,
            .inline_body = if (flow.inline_body) |b| try self.allocator.dupe(u8, b) else null,
            .preamble_code = if (flow.preamble_code) |p| try self.allocator.dupe(u8, p) else null,
            .is_pure = flow.is_pure,
            .is_transitively_pure = flow.is_transitively_pure,
            .location = flow.location,
            .module = try self.allocator.dupe(u8, flow.module),
            .impl_of = if (flow.impl_of) |io| try ast_functional.cloneDottedPath(self.allocator, &io) else null,
            .impl_variant = if (flow.impl_variant) |v| try self.allocator.dupe(u8, v) else null,
            .is_impl = flow.is_impl,
        };
    }

    /// Replace a continuation anywhere in the flow (including inside foreach nodes)
    fn replaceContinuationAnywhere(
        self: *AutoDischargeInserter,
        flow: *const ast.Flow,
        old_cont: *const ast.Continuation,
        new_cont: ast.Continuation,
    ) !ast.Flow {
        var new_continuations = try self.allocator.alloc(ast.Continuation, flow.body.continuations.len);

        for (flow.body.continuations, 0..) |*cont, i| {
            new_continuations[i] = try self.replaceContinuationInTree(cont, old_cont, new_cont);
        }

        // Clone annotations
        var new_annotations = try self.allocator.alloc([]const u8, flow.annotations.len);
        for (flow.annotations, 0..) |ann, i| {
            new_annotations[i] = try self.allocator.dupe(u8, ann);
        }

        return .{
            .body = ast.rootSite(try ast_functional.cloneInvocation(self.allocator, flow.inv()), new_continuations, flow.location),
            .annotations = new_annotations,
            .pre_label = if (flow.pre_label) |l| try self.allocator.dupe(u8, l) else null,
            .super_shape = flow.super_shape,
            .inline_body = if (flow.inline_body) |b| try self.allocator.dupe(u8, b) else null,
            .preamble_code = if (flow.preamble_code) |p| try self.allocator.dupe(u8, p) else null,
            .is_pure = flow.is_pure,
            .is_transitively_pure = flow.is_transitively_pure,
            .location = flow.location,
            .module = try self.allocator.dupe(u8, flow.module),
            .impl_of = if (flow.impl_of) |io| try ast_functional.cloneDottedPath(self.allocator, &io) else null,
            .impl_variant = if (flow.impl_variant) |v| try self.allocator.dupe(u8, v) else null,
            .is_impl = flow.is_impl,
        };
    }

    /// Rebuild a continuation-less flow head as an explicit flow exit: rename a
    /// `_` head bind to a synthetic (so a disposal can reference the value) and
    /// give the head an explicit terminal `|> _`. The existing terminator-
    /// disposal machinery then discharges the obligation on that terminal — the
    /// flow-head twin of the nested discard, reusing one disposal path rather
    /// than a bespoke head-disposal. Caller guarantees `flow.inv().return_binding`.
    fn giveContinuationlessHeadTerminal(self: *AutoDischargeInserter, flow: *const ast.Flow) !ast.Flow {
        var new_head_inv = try ast_functional.cloneInvocation(self.allocator, flow.inv());
        if (std.mem.eql(u8, flow.inv().return_binding.?, "_")) {
            new_head_inv.return_binding = try self.generateSyntheticBinding();
        }
        var term = try self.allocator.alloc(ast.Continuation, 1);
        term[0] = .{
            .branch = "",
            .binding = null,
            .condition = null,
            .node = .{ .terminal = {} },
            .indent = flow.body.indent + 1,
            .continuations = &[_]ast.Continuation{},
            .location = flow.location,
        };
        const new_body = ast.rootSite(new_head_inv, term, flow.location);

        var new_annotations = try self.allocator.alloc([]const u8, flow.annotations.len);
        for (flow.annotations, 0..) |ann, i| new_annotations[i] = try self.allocator.dupe(u8, ann);
        return .{
            .body = new_body,
            .annotations = new_annotations,
            .pre_label = if (flow.pre_label) |l| try self.allocator.dupe(u8, l) else null,
            .super_shape = flow.super_shape,
            .inline_body = if (flow.inline_body) |b| try self.allocator.dupe(u8, b) else null,
            .preamble_code = if (flow.preamble_code) |p| try self.allocator.dupe(u8, p) else null,
            .is_pure = flow.is_pure,
            .is_transitively_pure = flow.is_transitively_pure,
            .location = flow.location,
            .module = try self.allocator.dupe(u8, flow.module),
            .impl_of = if (flow.impl_of) |io| try ast_functional.cloneDottedPath(self.allocator, &io) else null,
            .impl_variant = if (flow.impl_variant) |v| try self.allocator.dupe(u8, v) else null,
            .is_impl = flow.is_impl,
        };
    }

    /// Materialize the implicit discard bind of an UNBOUND flow head whose
    /// event returns a phantom obligation: `~open()` (with `open -> T<state!>`)
    /// becomes `~open(): _`, continuations untouched. The bare call is the
    /// fully-discarded spelling of the bind — dropping the dead `: _` must not
    /// drop the obligation — so this rewrite makes the discard explicit and
    /// hands it to the existing `_`-discard machinery (the rename below, the
    /// continuation-less terminal synthesis, checkContinuation's flat-form
    /// discard). Fires from the transform loop only when the head event's
    /// return carries a phantom; a plain-value bare call stays untouched.
    fn materializeHeadDiscardBind(self: *AutoDischargeInserter, flow: *const ast.Flow) !ast.Flow {
        var new_head_inv = try ast_functional.cloneInvocation(self.allocator, flow.inv());
        new_head_inv.return_binding = try self.allocator.dupe(u8, "_");

        var new_conts = try self.allocator.alloc(ast.Continuation, flow.body.continuations.len);
        for (flow.body.continuations, 0..) |*c, i| {
            new_conts[i] = try ast_functional.cloneContinuation(self.allocator, c);
        }
        const new_body = ast.rootSite(new_head_inv, new_conts, flow.location);

        var new_annotations = try self.allocator.alloc([]const u8, flow.annotations.len);
        for (flow.annotations, 0..) |ann, i| new_annotations[i] = try self.allocator.dupe(u8, ann);
        return .{
            .body = new_body,
            .annotations = new_annotations,
            .pre_label = if (flow.pre_label) |l| try self.allocator.dupe(u8, l) else null,
            .super_shape = flow.super_shape,
            .inline_body = if (flow.inline_body) |b| try self.allocator.dupe(u8, b) else null,
            .preamble_code = if (flow.preamble_code) |p| try self.allocator.dupe(u8, p) else null,
            .is_pure = flow.is_pure,
            .is_transitively_pure = flow.is_transitively_pure,
            .location = flow.location,
            .module = try self.allocator.dupe(u8, flow.module),
            .impl_of = if (flow.impl_of) |io| try ast_functional.cloneDottedPath(self.allocator, &io) else null,
            .impl_variant = if (flow.impl_variant) |v| try self.allocator.dupe(u8, v) else null,
            .is_impl = flow.is_impl,
        };
    }

    /// Rename a `_` flow-head bind to a synthetic while KEEPING the head's
    /// continuations — the has-continuations twin of
    /// giveContinuationlessHeadTerminal. A `_` head that carries a phantom
    /// return obligation seeds that obligation under the name `_` (see the
    /// seeding block in the main transform); the eventual disposal, inserted
    /// on a downstream terminal, then references `_` and leaks `.field = _`
    /// into generated Zig (unusable — bare `_` is not a readable identifier).
    /// Renaming the head bind gives the disposal a real value to reference.
    /// Unlike the continuation-less twin we do NOT append a `|> _` terminal:
    /// the existing continuations already provide the flow exit where the
    /// terminator-disposal machinery fires.
    fn renameHeadDiscardBinding(self: *AutoDischargeInserter, flow: *const ast.Flow) !ast.Flow {
        var new_head_inv = try ast_functional.cloneInvocation(self.allocator, flow.inv());
        new_head_inv.return_binding = try self.generateSyntheticBinding();

        var new_conts = try self.allocator.alloc(ast.Continuation, flow.body.continuations.len);
        for (flow.body.continuations, 0..) |*c, i| {
            new_conts[i] = try ast_functional.cloneContinuation(self.allocator, c);
        }
        const new_body = ast.rootSite(new_head_inv, new_conts, flow.location);

        var new_annotations = try self.allocator.alloc([]const u8, flow.annotations.len);
        for (flow.annotations, 0..) |ann, i| new_annotations[i] = try self.allocator.dupe(u8, ann);
        return .{
            .body = new_body,
            .annotations = new_annotations,
            .pre_label = if (flow.pre_label) |l| try self.allocator.dupe(u8, l) else null,
            .super_shape = flow.super_shape,
            .inline_body = if (flow.inline_body) |b| try self.allocator.dupe(u8, b) else null,
            .preamble_code = if (flow.preamble_code) |p| try self.allocator.dupe(u8, p) else null,
            .is_pure = flow.is_pure,
            .is_transitively_pure = flow.is_transitively_pure,
            .location = flow.location,
            .module = try self.allocator.dupe(u8, flow.module),
            .impl_of = if (flow.impl_of) |io| try ast_functional.cloneDottedPath(self.allocator, &io) else null,
            .impl_variant = if (flow.impl_variant) |v| try self.allocator.dupe(u8, v) else null,
            .is_impl = flow.is_impl,
        };
    }

    /// Recursively replace a continuation in the tree
    fn replaceContinuationInTree(
        self: *AutoDischargeInserter,
        cont: *const ast.Continuation,
        old_cont: *const ast.Continuation,
        new_cont: ast.Continuation,
    ) !ast.Continuation {
        // Check if this is the continuation we're looking for
        if (@intFromPtr(cont) == @intFromPtr(old_cont)) {
            return new_cont;
        }

        // Clone this continuation but recurse into nested structures
        var cloned = try ast_functional.cloneContinuation(self.allocator, cont);

        // If the node contains nested structures (foreach, conditional), we need to recurse
        if (cont.node) |node| {
            if (node == .foreach) {
                const foreach = &node.foreach;
                var new_branches = try self.allocator.alloc(ast.NamedBranch, foreach.branches.len);
                for (foreach.branches, 0..) |*branch, bi| {
                    var new_body = try self.allocator.alloc(ast.Continuation, branch.body.len);
                    for (branch.body, 0..) |*body_cont, bci| {
                        new_body[bci] = try self.replaceContinuationInTree(body_cont, old_cont, new_cont);
                    }
                    // Clone annotations (critical for @scope)
                    var cloned_anns = try self.allocator.alloc([]const u8, branch.annotations.len);
                    for (branch.annotations, 0..) |ann, ai| {
                        cloned_anns[ai] = try self.allocator.dupe(u8, ann);
                    }
                    new_branches[bi] = .{
                        .name = try self.allocator.dupe(u8, branch.name),
                        .body = new_body,
                        .binding = if (branch.binding) |b| try self.allocator.dupe(u8, b) else null,
                        .is_optional = branch.is_optional,
                        .annotations = cloned_anns,
                    };
                }
                cloned.node = .{ .foreach = .{
                    .iterable = try self.allocator.dupe(u8, foreach.iterable),
                    .element_type = if (foreach.element_type) |t| try self.allocator.dupe(u8, t) else null,
                    .branches = new_branches,
                } };
            } else if (node == .conditional) {
                const cond = &node.conditional;
                var new_branches = try self.allocator.alloc(ast.NamedBranch, cond.branches.len);
                for (cond.branches, 0..) |*branch, bi| {
                    var new_body = try self.allocator.alloc(ast.Continuation, branch.body.len);
                    for (branch.body, 0..) |*body_cont, bci| {
                        new_body[bci] = try self.replaceContinuationInTree(body_cont, old_cont, new_cont);
                    }
                    // Clone annotations (critical for @scope)
                    var cloned_anns = try self.allocator.alloc([]const u8, branch.annotations.len);
                    for (branch.annotations, 0..) |ann, ai| {
                        cloned_anns[ai] = try self.allocator.dupe(u8, ann);
                    }
                    new_branches[bi] = .{
                        .name = try self.allocator.dupe(u8, branch.name),
                        .body = new_body,
                        .binding = if (branch.binding) |b| try self.allocator.dupe(u8, b) else null,
                        .is_optional = branch.is_optional,
                        .annotations = cloned_anns,
                    };
                }
                cloned.node = .{
                    .conditional = .{
                        .condition = try self.allocator.dupe(u8, cond.condition),
                        .condition_expr = cond.condition_expr, // TODO: clone if needed
                        .branches = new_branches,
                    },
                };
            }
        }

        // Recurse into nested continuations
        if (cont.continuations.len > 0) {
            var new_nested = try self.allocator.alloc(ast.Continuation, cont.continuations.len);
            for (cont.continuations, 0..) |*nested, ni| {
                new_nested[ni] = try self.replaceContinuationInTree(nested, old_cont, new_cont);
            }
            cloned.continuations = new_nested;
        }

        return cloned;
    }


    /// Canonicalize a phantom state with module prefix
    fn canonicalizePhantom(self: *AutoDischargeInserter, phantom_str: []const u8, module: []const u8) ![]const u8 {
        var parsed = phantom_parser.PhantomState.parse(self.allocator, phantom_str) catch {
            // If parsing fails, return unchanged
            return try self.allocator.dupe(u8, phantom_str);
        };
        defer parsed.deinit(self.allocator);

        switch (parsed) {
            .concrete => |concrete| {
                const mod = concrete.module_path orelse module;
                const cleanup_suffix = if (concrete.requires_cleanup) "!" else "";
                return try std.fmt.allocPrint(self.allocator, "{s}:{s}{s}", .{ mod, concrete.name, cleanup_suffix });
            },
            .variable => {
                return try self.allocator.dupe(u8, phantom_str);
            },
            .state_union => {
                // Unions are not canonicalized - they may have mixed modules
                return try self.allocator.dupe(u8, phantom_str);
            },
        }
    }

    /// Seed cleanup obligations from a RECORD return type's fields. A scalar
    /// return carries its obligation as the whole-value `return_phantom`; a
    /// record return (`-> { h: *Handle<owned!>, n: i64 }`) embeds the phantom
    /// INSIDE the type string, one per field — the same shape an event-payload
    /// field carries (2103, 330_082), mirrored on the output side (Lars-ruled:
    /// a return record is a transparent bag, not an opaque payload). Enforcement
    /// otherwise keys off the whole-value phantom and never descends, so a
    /// dropped field obligation escapes as a raw-Zig leak with no koru wall.
    /// (330_096; concept frag-obligation-enforcement-keys-off-return-binding.)
    ///
    /// Each phantom-carrying field mints an obligation keyed `binding.field`, so
    /// multiple obligations per record don't collide (the capstone's "multiple
    /// to and from a record"). A field whose phantom is not a cleanup obligation
    /// (no trailing `!`) is a plain state marker and seeds nothing.
    fn seedRecordFieldObligations(
        self: *AutoDischargeInserter,
        binding: []const u8,
        return_type: []const u8,
        module_name: []const u8,
        destructure: []const ast.DestructureField,
        context: *BindingContext,
    ) !void {
        const trimmed = std.mem.trim(u8, return_type, " \t");
        if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return;
        const inner = trimmed[1 .. trimmed.len - 1];
        // Split the record into top-level `name: value` fields — commas nested in
        // a phantom `<...>`, a slice `[...]`, or parens don't split a field.
        var seg_start: usize = 0;
        var depth: i32 = 0;
        var i: usize = 0;
        while (i <= inner.len) : (i += 1) {
            const at_end = i == inner.len;
            const c = if (at_end) ',' else inner[i];
            switch (c) {
                '<', '{', '[', '(' => depth += 1,
                '>', '}', ']', ')' => depth -= 1,
                else => {},
            }
            if (!(at_end or (c == ',' and depth == 0))) continue;
            const seg = std.mem.trim(u8, inner[seg_start..i], " \t");
            seg_start = i + 1;
            if (seg.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, seg, ':') orelse continue; // positional, no phantom
            const f_name = std.mem.trim(u8, seg[0..colon], " \t");
            const f_value = std.mem.trim(u8, seg[colon + 1 ..], " \t");
            if (f_name.len == 0) continue;
            const lt = std.mem.indexOfScalar(u8, f_value, '<') orelse continue;
            // Match the phantom's closing `>` (koru surface types use `<>` only
            // for phantoms — no language generics — so this group IS the phantom).
            var ph_depth: usize = 0;
            var close: ?usize = null;
            for (f_value[lt..], lt..) |pc, pj| {
                if (pc == '<') ph_depth += 1 else if (pc == '>') {
                    ph_depth -= 1;
                    if (ph_depth == 0) {
                        close = pj;
                        break;
                    }
                }
            }
            const gt = close orelse continue;
            const phantom_content = std.mem.trim(u8, f_value[lt + 1 .. gt], " \t");
            // Only a cleanup obligation (trailing `!`) is an obligation to track.
            if (!std.mem.endsWith(u8, phantom_content, "!")) continue;
            const base_type = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{
                std.mem.trim(u8, f_value[0..lt], " \t"),
                f_value[gt + 1 ..],
            });
            defer self.allocator.free(base_type);
            const canonical = try self.canonicalizePhantom(phantom_content, module_name);
            defer self.allocator.free(canonical);
            // A destructured obligation field is discharged by its scalar binding
            // name (`dispose(x: h)`), so it must be keyed by that name; an
            // obligation field the destructure does NOT name keeps the
            // `binding.field` key (unreachable → a guaranteed leak, the ordinary
            // "every obligation must be discharged" rule — 330_103).
            var named_in_destructure = false;
            if (destructure.len > 0) {
                for (destructure) |df| {
                    if (std.mem.eql(u8, df.name, f_name)) {
                        named_in_destructure = true;
                        break;
                    }
                }
            }
            const key = if (named_in_destructure)
                try self.allocator.dupe(u8, f_name)
            else
                try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ binding, f_name });
            defer self.allocator.free(key);
            try context.addBinding(key, canonical, f_name, base_type, self.nextAcqSeq());
            // Mark it as a return-record field obligation so enforcement routes it
            // to the "was not discharged" wall rather than an auto-insert the
            // phantom checker can't validate.
            if (context.cleanup_obligations.getPtr(key)) |oblig| oblig.not_auto_dischargeable = true;
        }
    }

    /// Convert a dotted path to a string
    /// Split an event name (possibly dotted, e.g. `dispose.file`) into its
    /// path segments — the inverse of `pathToString`. A synthetic disposal
    /// call must carry the SAME multi-segment path a real parsed call would;
    /// a single-segment blob makes the emitter mis-resolve a dotted disposer
    /// to `<module>.<first-segment>` and leak a host error
    /// (see tests/regression/.../330_090_auto_discharge_dotted_disposer).
    fn eventNameToSegments(self: *AutoDischargeInserter, event_name: []const u8) ![][]const u8 {
        var count: usize = 1;
        for (event_name) |ch| {
            if (ch == '.') count += 1;
        }
        const segments = try self.allocator.alloc([]const u8, count);
        var i: usize = 0;
        var start: usize = 0;
        for (event_name, 0..) |ch, idx| {
            if (ch == '.') {
                segments[i] = try self.allocator.dupe(u8, event_name[start..idx]);
                i += 1;
                start = idx + 1;
            }
        }
        segments[i] = try self.allocator.dupe(u8, event_name[start..]);
        return segments;
    }

    fn pathToString(self: *AutoDischargeInserter, path: ast.DottedPath) ![]const u8 {
        if (path.segments.len == 0) return try self.allocator.dupe(u8, "");
        if (path.segments.len == 1) return try self.allocator.dupe(u8, path.segments[0]);

        var total_len: usize = path.segments[0].len;
        for (path.segments[1..]) |seg| {
            total_len += 1 + seg.len;
        }

        var result = try self.allocator.alloc(u8, total_len);
        var pos: usize = 0;

        @memcpy(result[pos .. pos + path.segments[0].len], path.segments[0]);
        pos += path.segments[0].len;

        for (path.segments[1..]) |seg| {
            result[pos] = '.';
            pos += 1;
            @memcpy(result[pos .. pos + seg.len], seg);
            pos += seg.len;
        }

        return result;
    }

    /// Generate a unique synthetic binding name
    fn generateSyntheticBinding(self: *AutoDischargeInserter) ![]const u8 {
        const name = try std.fmt.allocPrint(self.allocator, "_auto_{d}", .{self.synthetic_binding_counter});
        self.synthetic_binding_counter += 1;
        return name;
    }

    /// Format a binding name for display in error messages.
    /// Converts synthetic names like "_auto_0.conn" to cleaner forms like "conn"
    /// and extracts just the field name when available.
    ///
    /// `_auto_N` is a name the compiler minted for a value the author
    /// discarded; quoting it back asks them to look for something they never
    /// wrote (690_108). When nothing authored survives, the resource's TYPE is
    /// the thing they DID write, so that is what the sentence names.
    fn formatBindingForError(binding_name: []const u8, field_name: []const u8, base_type: []const u8) []const u8 {
        // For identity branches, field_name is "__type_ref" - use binding_name instead
        if (field_name.len > 0 and !std.mem.eql(u8, field_name, "__type_ref")) {
            return field_name;
        }
        // If binding is synthetic (_auto_N), try to extract the field part after the dot
        if (std.mem.startsWith(u8, binding_name, "_auto_")) {
            if (std.mem.indexOf(u8, binding_name, ".")) |dot_idx| {
                return binding_name[dot_idx + 1 ..];
            }
            if (base_type.len > 0) return base_type;
        }
        // Otherwise use the binding name as-is
        return binding_name;
    }

    /// Format phantom state for display - extract just the state name without module prefix
    fn formatStateForError(phantom_state: []const u8) []const u8 {
        // phantom_state is like "app.db:started!" - extract just "started!"
        if (std.mem.lastIndexOf(u8, phantom_state, ":")) |colon_idx| {
            return phantom_state[colon_idx + 1 ..];
        }
        return phantom_state;
    }

    /// The verb the user actually calls to discharge, from a disposer's qualified
    /// name. Generated store disposers (`__store_giveback_<s>`) are internal —
    /// the user's surface verb is `give-back`. Show that, never the mangled name,
    /// so the "Call:" hint points at real code (pit-of-success). Any other
    /// disposer shows its plain event name.
    fn displayDischargerName(qualified_name: []const u8) []const u8 {
        const tail = if (std.mem.lastIndexOf(u8, qualified_name, ":")) |idx|
            qualified_name[idx + 1 ..]
        else
            qualified_name;
        if (std.mem.startsWith(u8, tail, "__store_giveback_")) return "give-back";
        return tail;
    }

    /// Clone a continuation with a new binding name
    /// This preserves ALL metadata by copying fields, only changing the binding
    fn cloneContinuationWithBinding(
        self: *AutoDischargeInserter,
        cont: *const ast.Continuation,
        new_binding: []const u8,
    ) !*const ast.Continuation {
        const new_cont = try self.allocator.create(ast.Continuation);
        // Copy all fields from original (preserves all pointers/metadata)
        new_cont.* = cont.*;
        // Override just the binding
        new_cont.binding = try self.allocator.dupe(u8, new_binding);
        return new_cont;
    }

    /// Clone a continuation, overriding the bare-return bind on its invocation
    /// node (`call(...): _` → `call(...): _auto_N`). The bare-return twin of
    /// cloneContinuationWithBinding: the discard lives in the node's
    /// return_binding, not cont.binding, so a `: _` on an obligation-carrying
    /// return needs a referenceable name for the inserted discharge.
    fn cloneContinuationWithReturnBinding(
        self: *AutoDischargeInserter,
        cont: *const ast.Continuation,
        new_binding: []const u8,
    ) !*const ast.Continuation {
        const new_cont = try self.allocator.create(ast.Continuation);
        new_cont.* = cont.*;
        if (cont.node) |node| {
            if (node == .invocation) {
                var new_inv = node.invocation;
                new_inv.return_binding = try self.allocator.dupe(u8, new_binding);
                new_cont.node = ast.Node{ .invocation = new_inv };
            }
        }
        return new_cont;
    }

    /// Synthesize continuations for unhandled optional branches
    /// This ensures:
    /// 1. All optional branches get proper switch cases (runtime safety)
    /// 2. Auto-discharge can insert disposals for obligations in optional branches
    fn synthesizeOptionalBranches(
        self: *AutoDischargeInserter,
        flow: *const ast.Flow,
        event_decl: *const ast.EventDecl,
    ) !?*const ast.Flow {
        // Find which branches are already handled
        var handled = std.StringHashMap(void).init(self.allocator);
        defer handled.deinit();

        for (flow.body.continuations) |*cont| {
            if (cont.is_catchall) {
                // Catch-all handles all optional branches - no synthesis needed
                return null;
            }
            try handled.put(cont.branch, {});
        }

        // Find optional/panic branches that need synthesis.
        // - optional (`| ?`): unhandled => synthesized NO-OP (safe to ignore).
        // - panic    (`| ?!`): unhandled => synthesized @panic(...) (UNSAFE to
        //   ignore; the path must not silently proceed). Same detection path,
        //   different synthesized body.
        // We track which missing branches are panic so the synthesized body
        // differs (panic vs empty terminal).
        var missing_optional = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        defer missing_optional.deinit(self.allocator);
        var missing_panic = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        defer missing_panic.deinit(self.allocator);
        // ~[prototype] holes: required terminal branches left unhandled. Same
        // @panic body as missing_panic, but a distinct list so the crash-surface
        // strict gate (--panic-branches=strict) below only governs real `| ?!`
        // panic branches, never prototype holes (different feature, different
        // opt-in).
        var missing_prototype = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        defer missing_prototype.deinit(self.allocator);

        for (event_decl.branches) |branch| {
            // Effect (`!`) branches are NOT switch arms — they lower to fns in
            // the consumer's Handlers struct. The emitter synthesizes no-op
            // fns for unhandled optional effect branches; switch padding here
            // would emit `.warn => |_| {}` on a union that has no `.warn`.
            if (branch.kind == .effect) continue;
            if (handled.contains(branch.name)) continue;
            if (branch.is_panic) {
                try missing_panic.append(self.allocator, branch.name);
            } else if (branch.is_optional) {
                try missing_optional.append(self.allocator, branch.name);
            } else if (self.prototype_mode) {
                // A plain REQUIRED terminal left unhandled under ~[prototype] is
                // a HOLE: synthesize a loud @panic arm (same as | ?!) so the
                // incomplete program compiles and runs its built paths, and
                // crashes loudly if the hole is ever reached. Without ~[prototype]
                // this is a KORU022 exhaustiveness error (400_161).
                try missing_prototype.append(self.allocator, branch.name);
            }
        }

        // ~[prototype] DUAL of hole-synthesis: an arm handling a branch the event
        // does NOT declare (400_165) can never fire, and lowering it would emit an
        // invalid switch case (`.soon =>` on a union with no `soon`). The checkers
        // already let it slide (KORU021 / KORU030); here we DROP it from the
        // lowered switch. Terminal-only (an undeclared effect arm already errored
        // at KORU030), never a catchall or metatype (Transition/Profile/Audit are
        // valid), and never when the event declares a raw-name class branch (`*`),
        // which makes every name declared.
        var prune_flags = try self.allocator.alloc(bool, flow.body.continuations.len);
        defer self.allocator.free(prune_flags);
        var prune_count: usize = 0;
        if (self.prototype_mode) {
            for (flow.body.continuations, 0..) |*cont, i| {
                prune_flags[i] = false;
                if (cont.branch.len == 0) continue; // void event chain (|> event()), not a named branch
                if (cont.is_catchall) continue;
                if (cont.kind == .effect) continue;
                if (isMetatypeBranchName(cont.branch)) continue;
                if (branchNameIsDeclared(event_decl, cont.branch)) continue;
                prune_flags[i] = true;
                prune_count += 1;
            }
        } else {
            for (prune_flags) |*f| f.* = false;
        }

        if (missing_optional.items.len == 0 and missing_panic.items.len == 0 and
            missing_prototype.items.len == 0 and prune_count == 0)
        {
            return null; // Nothing to synthesize or prune
        }

        // ~[prototype] GAP READOUT: the "thought about, not built yet" frontier,
        // printed to stderr during compilation for any prototype flow with gaps.
        // The two directions read as one report per event:
        //   • hole       — a DECLARED terminal left unhandled (→ @panic if reached)
        //   • undeclared — a HANDLED arm the event does not declare (pruned dead code)
        // This is the machine-/human-readable surface for closing the gaps and for
        // describing the events from exploratory code. (First-cut home: this pass is
        // the one place holding BOTH sets; lift to its own pass in a later tightening.)
        if (self.prototype_mode and (missing_prototype.items.len > 0 or prune_count > 0)) {
            const ev_name = try self.pathToString(event_decl.path);
            defer self.allocator.free(ev_name);
            std.debug.print("📋 prototype gaps — tor '{s}' ({s}:{d}):\n", .{
                ev_name, flow.location.file, flow.location.line,
            });
            for (missing_prototype.items) |name| {
                std.debug.print("     hole       — '{s}' unhandled → @panic if reached\n", .{name});
            }
            for (flow.body.continuations, 0..) |*cont, i| {
                if (prune_flags[i]) {
                    std.debug.print("     undeclared — '{s}' handled but not declared → pruned (declare it on '{s}' to build it)\n", .{ cont.branch, ev_name });
                }
            }
        }

        // Crash-surface map (strict mode): when --panic-branches=strict is set,
        // every UNHANDLED panic branch is a compile error (KORU022) — the
        // enumerated list of where the program can crash on a rare failure.
        // Dev build (flag off) stays silent: the synthesized @panic is still
        // there at runtime (ergonomic prototyping). Production/audit build
        // (flag on) blocks compilation until each is handled or explicitly
        // muted (`| <name> _ |> ...`). Same source, the flag flips it.
        // Detection is free here (missing_panic already computed) — this is
        // "also report + fail", not a new pass. Reuses KORU022 (missing required
        // branch): in strict mode a panic branch IS required to be handled.
        if (self.strict_panic_branches and missing_panic.items.len > 0) {
            for (missing_panic.items) |branch_name| {
                try self.reporter.addErrorAtLocation(.KORU022, flow.location,
                    "panic branch '{s}' is unhandled — in strict mode (--panic-branches=strict) panic branches must be handled or explicitly muted (| {s} _ |> ...). Without strict mode this synthesizes @panic at runtime.", .{ branch_name, branch_name });
            }
            return error.ValidationFailed;
        }

        // Create new continuations array with synthesized branches. Pruned
        // undeclared arms (prototype dual) are dropped, so kept_count is the base
        // offset the synthesized arms append after.
        const kept_count = flow.body.continuations.len - prune_count;
        const new_len = kept_count + missing_optional.items.len +
            missing_panic.items.len + missing_prototype.items.len;
        var new_continuations = try self.allocator.alloc(ast.Continuation, new_len);
        errdefer self.allocator.free(new_continuations);

        // Copy existing continuations, skipping pruned undeclared arms.
        {
            var write_idx: usize = 0;
            for (flow.body.continuations, 0..) |*cont, i| {
                if (prune_flags[i]) continue;
                new_continuations[write_idx] = try ast_functional.cloneContinuation(self.allocator, cont);
                write_idx += 1;
            }
        }

        // Add synthesized continuations for missing optional branches (NO-OP body).
        for (missing_optional.items, 0..) |branch_name, i| {
            const idx = kept_count + i;
            new_continuations[idx] = ast.Continuation{
                .branch = try self.allocator.dupe(u8, branch_name),
                .binding = try self.allocator.dupe(u8, "_"), // Discard binding - auto-discharge will synthesize _auto_N
                .binding_annotations = &[_][]const u8{},
                .binding_type = .branch_payload,
                .is_catchall = false,
                .catchall_metatype = null,
                .condition = null,
                .condition_expr = null,
                .node = .{ .terminal = {} }, // Terminal - triggers auto-discharge check
                .indent = 0,
                .continuations = &[_]ast.Continuation{},
                .location = flow.location,
            };
        }

        // Add synthesized continuations for missing PANIC branches (@panic body).
        // Same shape as optional (discard binding, switch arm present) but the
        // body is `@panic(...)` — UNSAFE to ignore. inline_code is emitted
        // verbatim as the handler body and is NOT a terminal, so auto-discharge
        // leaves it alone (no no-op discharge). The switch arm is exhaustive
        // (so Zig accepts it) AND loud (panics if the branch ever fires).
        for (missing_panic.items, 0..) |branch_name, i| {
            const idx = kept_count + missing_optional.items.len + i;
            const panic_msg = try std.fmt.allocPrint(
                self.allocator,
                "@panic(\"unhandled panic branch '{s}' fired at runtime\");",
                .{branch_name},
            );
            new_continuations[idx] = ast.Continuation{
                .branch = try self.allocator.dupe(u8, branch_name),
                .binding = try self.allocator.dupe(u8, "_"), // Discard payload; auto-discharge renames to _auto_N
                .binding_annotations = &[_][]const u8{},
                .binding_type = .branch_payload,
                .is_catchall = false,
                .catchall_metatype = null,
                .condition = null,
                .condition_expr = null,
                .node = .{ .inline_code = panic_msg }, // @panic(...) — loud, not a no-op
                .indent = 0,
                .continuations = &[_]ast.Continuation{},
                .location = flow.location,
            };
        }

        // Add synthesized continuations for ~[prototype] HOLES (required
        // terminal branches left unhandled). Identical shape and body to the
        // panic-branch arm above — a loud @panic — but a distinct, guiding
        // message: this path was never built, not a rare-failure escape hatch.
        for (missing_prototype.items, 0..) |branch_name, i| {
            const idx = kept_count + missing_optional.items.len +
                missing_panic.items.len + i;
            const panic_msg = try std.fmt.allocPrint(
                self.allocator,
                "@panic(\"unhandled branch '{s}' reached — prototype hole (~[prototype]); this path is not built yet\");",
                .{branch_name},
            );
            new_continuations[idx] = ast.Continuation{
                .branch = try self.allocator.dupe(u8, branch_name),
                .binding = try self.allocator.dupe(u8, "_"),
                .binding_annotations = &[_][]const u8{},
                .binding_type = .branch_payload,
                .is_catchall = false,
                .catchall_metatype = null,
                .condition = null,
                .condition_expr = null,
                .node = .{ .inline_code = panic_msg }, // @panic(...) — loud hole, not a no-op
                .indent = 0,
                .continuations = &[_]ast.Continuation{},
                .location = flow.location,
            };
        }

        // Create new flow with synthesized continuations
        const new_flow = try self.allocator.create(ast.Flow);
        new_flow.* = flow.*;
        new_flow.body.continuations = new_continuations;

        return new_flow;
    }
};

/// Transition/Profile/Audit are compiler metatypes available on any event, so a
/// continuation naming one is NOT an undeclared branch — never prune it.
fn isMetatypeBranchName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Transition") or
        std.mem.eql(u8, name, "Profile") or
        std.mem.eql(u8, name, "Audit");
}

/// True if `name` resolves against the event's declared branches — an exact
/// match, or any name when the event declares a raw-name class branch (`*`).
/// Mirrors branch_checker.resolveDeclared. Under ~[prototype], a continuation
/// whose branch does NOT resolve is the undeclared-arm doodle to prune.
fn branchNameIsDeclared(event_decl: *const ast.EventDecl, name: []const u8) bool {
    for (event_decl.branches) |branch| {
        if (std.mem.eql(u8, branch.name, name)) return true;
    }
    for (event_decl.branches) |branch| {
        if (std.mem.eql(u8, branch.name, "*")) return true;
    }
    return false;
}

/// Standalone recursive helper for finding continuation by binding (outside struct for recursive calls)
fn findContinuationByBindingRecursive(conts: []const ast.Continuation, binding_name: []const u8) ?*const ast.Continuation {
    for (conts) |*cont| {
        if (cont.binding) |b| {
            if (std.mem.eql(u8, b, binding_name)) {
                return cont;
            }
        }
        // Recursively search in nested continuations
        if (cont.continuations.len > 0) {
            if (findContinuationByBindingRecursive(cont.continuations, binding_name)) |found| {
                return found;
            }
        }
        // Search in node's nested structures
        if (cont.node) |node| {
            switch (node) {
                .foreach => |fe| {
                    for (fe.branches) |*branch| {
                        if (findContinuationByBindingRecursive(branch.body, binding_name)) |found| {
                            return found;
                        }
                    }
                },
                .conditional => |cond| {
                    for (cond.branches) |*branch| {
                        if (findContinuationByBindingRecursive(branch.body, binding_name)) |found| {
                            return found;
                        }
                    }
                },
                else => {},
            }
        }
    }
    return null;
}
