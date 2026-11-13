// The Koru mounted-scope ABI — the module side of the boundary, mirrored
// field-for-field from koru_std (interpreter.contracts/resdispatch,
// runtime.lookups/specs, runtime.kz:ScopeRuntime). A module and its host
// must be built by the same toolchain: these layouts are compiled, not
// serialized, and `abi_version` is the handshake, not a compat story.
//
// `Invocation` is imported whole from the compiler's own ast.zig — it is
// the one type on this boundary too large to mirror honestly.

const std = @import("std");
const ast = @import("ast");

pub const Invocation = ast.Invocation;
pub const Arg = ast.Arg;

// -- dispatch protocol (koru_std/interpreter.kz) --

pub const FieldValue = union(enum) {
    string_val: []const u8,
    int_val: i64,
    float_val: f64,
    bool_val: bool,
    string_array: []const []const u8,
};

pub const NamedField = struct {
    name: []const u8,
    value: FieldValue,
};

pub const DispatchResult = struct {
    branch: []const u8,
    fields: []const NamedField,
};

pub const DispatchFn = *const fn (*const Invocation, *DispatchResult) anyerror!void;

// -- metadata lookups (koru_std/runtime.lookups + specs) --

pub const CostFn = *const fn ([]const u8) u64;
pub const ObligationsArrayFn = *const fn ([]const u8) []const []const u8;
pub const DischargeEventFn = *const fn ([]const u8) ?[]const u8;

pub const CreateSpec = struct {
    obligation_module: []const u8,
    obligation_name: []const u8,
    field_name: []const u8,
    resource_type: []const u8,
    branch: ?[]const u8 = null,
    tainted: bool = false,
};

pub const DischargeSpec = struct {
    obligation_module: []const u8,
    obligation_name: []const u8,
    arg_name: []const u8,
};

pub const CreatesSpecFn = *const fn ([]const u8) []const CreateSpec;
pub const DischargesSpecFn = *const fn ([]const u8) []const DischargeSpec;

pub const BranchField = struct {
    name: []const u8,
    type_name: []const u8,
    is_optional: bool = false,
};

pub const BranchSpec = struct {
    name: []const u8,
    fields: []const BranchField,
    is_optional: bool = false,
};

pub const BranchesLookupFn = *const fn ([]const u8) []const BranchSpec;
pub const EventsLookupFn = *const fn () []const []const u8;

pub const InputFieldSpec = struct {
    name: []const u8,
    type_name: []const u8,
    is_optional: bool = false,
    phantom: ?[]const u8 = null,
};

pub const InputLookupFn = *const fn ([]const u8) ?[]const InputFieldSpec;
pub const DocLookupFn = *const fn ([]const u8) []const u8;

// -- the vtable (koru_std/runtime.kz:858 — field order is load-bearing) --

pub const ScopeRuntime = struct {
    name: []const u8,
    dispatcher: DispatchFn,
    cost_fn: ?CostFn,
    creates_obligations_fn: ?ObligationsArrayFn,
    discharges_obligations_fn: ?ObligationsArrayFn,
    discharge_event_fn: ?DischargeEventFn,
    creates_spec_fn: ?CreatesSpecFn,
    discharges_spec_fn: ?DischargesSpecFn,
    branches_fn: ?BranchesLookupFn,
    events_fn: ?EventsLookupFn,
    input_fn: ?InputLookupFn,
    doc_fn: ?DocLookupFn,
    manifest: ?*const anyopaque = null,
};

// -- host services (koru_std/interpreter.resdispatch.kz) --
//
// The three calls a mounted dispatcher may make back into the host. They
// are the module-boundary spelling of setDispatchDetail /
// registerDispatchResource / resolveDispatchResource: a mounted proc
// mints and resolves against the HOST'S pool — the session's handles —
// not a private table inside the .dylib.

pub const KORU_MOUNTED_ABI_VERSION: u32 = 2;

pub const MountedHostServices = struct {
    abi_version: u32,
    set_dispatch_detail: *const fn ([]const u8) void,
    register_dispatch_resource: *const fn ([]const u8, *anyopaque) []const u8,
    resolve_dispatch_resource: *const fn ([]const u8) ?*anyopaque,
};
