const std = @import("std");
const ast = @import("ast");
const BindingContext = @import("binding_context.zig").BindingContext;
const BindingInfo = @import("binding_context.zig").BindingInfo;

/// Information about a label in the control flow
pub const LabelInfo = struct {
    name: []const u8,
    label_type: LabelType,
    invocation_path: ?[]const []const u8,  // Event path for the label
    expected_shape: ?*const ast.Shape,  // Expected input/output shape
    continuations: std.ArrayList(*const ast.Continuation),
    captured_bindings: ?std.ArrayList(BindingInfo),  // Bindings captured at label definition
    emission_state: EmissionState,
    
    pub const LabelType = enum {
        pre_invocation,   // ~#label event()
        post_invocation,  // ~event() #label
    };
    
    pub const EmissionState = enum {
        not_emitted,
        emitting,
        emitted,
    };
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, label_type: LabelType) !LabelInfo {
        return LabelInfo{
            .name = try allocator.dupe(u8, name),
            .label_type = label_type,
            .invocation_path = null,
            .expected_shape = null,
            .continuations = std.ArrayList(*const ast.Continuation).init(allocator),
            .captured_bindings = null,
            .emission_state = .not_emitted,
        };
    }
    
    pub fn deinit(self: *LabelInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.continuations.deinit();
        if (self.captured_bindings) |*bindings| {
            bindings.deinit();
        }
    }
};

/// Manages control flow constructs (labels, loops, etc.) during emission
pub const ControlFlow = struct {
    allocator: std.mem.Allocator,
    labels: std.StringHashMap(LabelInfo),
    current_label: ?[]const u8,  // Currently active label (for nested continuations)
    label_stack: std.ArrayList([]const u8),  // Stack of labels being processed
    
    pub fn init(allocator: std.mem.Allocator) !ControlFlow {
        return ControlFlow{
            .allocator = allocator,
            .labels = std.StringHashMap(LabelInfo).init(allocator),
            .current_label = null,
            .label_stack = std.ArrayList([]const u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *ControlFlow) void {
        var iter = self.labels.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.labels.deinit();
        self.label_stack.deinit();
    }
    
    /// Register a new label
    pub fn registerLabel(
        self: *ControlFlow,
        name: []const u8,
        label_type: LabelInfo.LabelType,
        binding_ctx: ?*const BindingContext,
    ) !void {
        const key = try self.allocator.dupe(u8, name);
        var label = try LabelInfo.init(self.allocator, name, label_type);
        
        // Capture current bindings if context provided
        if (binding_ctx) |ctx| {
            label.captured_bindings = try ctx.captureContext();
        }
        
        try self.labels.put(key, label);
    }
    
    /// Add continuation to a label
    pub fn addContinuation(self: *ControlFlow, label_name: []const u8, continuation: *const ast.Continuation) !void {
        if (self.labels.getPtr(label_name)) |label| {
            try label.continuations.append(continuation);
        } else {
            return error.UnknownLabel;
        }
    }
    
    /// Set the expected shape for a label
    pub fn setLabelShape(self: *ControlFlow, label_name: []const u8, shape: *const ast.Shape) !void {
        if (self.labels.getPtr(label_name)) |label| {
            label.expected_shape = shape;
        } else {
            return error.UnknownLabel;
        }
    }
    
    /// Set the invocation path for a label
    pub fn setLabelInvocation(self: *ControlFlow, label_name: []const u8, path: []const []const u8) !void {
        if (self.labels.getPtr(label_name)) |label| {
            label.invocation_path = path;
        } else {
            return error.UnknownLabel;
        }
    }
    
    /// Get label information
    pub fn getLabel(self: *const ControlFlow, name: []const u8) ?*const LabelInfo {
        return self.labels.getPtr(name);
    }
    
    /// Check if a label exists
    pub fn hasLabel(self: *const ControlFlow, name: []const u8) bool {
        return self.labels.contains(name);
    }
    
    /// Push a label onto the processing stack
    pub fn pushLabel(self: *ControlFlow, label_name: []const u8) !void {
        const duped = try self.allocator.dupe(u8, label_name);
        try self.label_stack.append(duped);
        self.current_label = duped;
    }
    
    /// Pop a label from the processing stack
    pub fn popLabel(self: *ControlFlow) void {
        if (self.label_stack.items.len > 0) {
            const label = self.label_stack.pop();
            self.allocator.free(label);
            
            if (self.label_stack.items.len > 0) {
                self.current_label = self.label_stack.items[self.label_stack.items.len - 1];
            } else {
                self.current_label = null;
            }
        }
    }
    
    /// Mark a label as being emitted
    pub fn markLabelEmitting(self: *ControlFlow, label_name: []const u8) !void {
        if (self.labels.getPtr(label_name)) |label| {
            if (label.emission_state == .emitting) {
                return error.CircularLabel;  // Detect circular dependencies
            }
            label.emission_state = .emitting;
        } else {
            return error.UnknownLabel;
        }
    }
    
    /// Mark a label as emitted
    pub fn markLabelEmitted(self: *ControlFlow, label_name: []const u8) !void {
        if (self.labels.getPtr(label_name)) |label| {
            label.emission_state = .emitted;
        } else {
            return error.UnknownLabel;
        }
    }
    
    /// Check if a label has been emitted
    pub fn isLabelEmitted(self: *const ControlFlow, label_name: []const u8) bool {
        if (self.labels.getPtr(label_name)) |label| {
            return label.emission_state == .emitted;
        }
        return false;
    }
    
    /// Get the current active label
    pub fn getCurrentLabel(self: *const ControlFlow) ?[]const u8 {
        return self.current_label;
    }
    
    /// Check if we're inside a label context
    pub fn isInLabelContext(self: *const ControlFlow) bool {
        return self.label_stack.items.len > 0;
    }
    
    /// Get all labels (for debugging/reporting)
    pub fn getAllLabels(self: *const ControlFlow) []const []const u8 {
        var result = std.ArrayList([]const u8).init(self.allocator);
        var iter = self.labels.iterator();
        while (iter.next()) |entry| {
            result.append(entry.key_ptr.*) catch continue;
        }
        return result.items;
    }
};