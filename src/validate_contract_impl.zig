const std = @import("std");
const ast = @import("ast");
const errors = @import("errors");
const file_types = @import("file_types");

const ErrorReporter = errors.ErrorReporter;

/// Phase 3: enforce the contract/implementation file split.
///
/// Opt-in per module — fires only when the merged module contains at least one
/// `.k` companion file. Modules without a `.k` file (the status-quo single-`.kz`
/// pattern) are completely unaffected.
///
/// Rule 1 (REMOVED 2026-07-17): previously rejected private events in a `.k`.
///         Repudiated — a `.k` is a full program, not a contract-only surface,
///         so private events are legal there (implemented as pure Koru in-file,
///         called by local flows). Only Rule 2 remains.
///
/// Rule 2: when `.k` exists in the module, events declared in non-`.k`
///         companion files (`.kz`, `.kjs`, `.kc`, `.kgpu`) MUST NOT be
///         `~pub`. The public surface lives in the `.k` contract; private
///         events in implementation files remain legal for internal subflow
///         scaffolding.
pub fn validate(items: []const ast.Item, reporter: *ErrorReporter) !void {
    var module_has_k = false;
    for (items) |item| {
        switch (item) {
            .event_decl => |event| {
                if (isContractFile(event.location.file)) {
                    module_has_k = true;
                    break;
                }
            },
            else => {},
        }
    }

    for (items) |item| {
        switch (item) {
            .event_decl => |event| {
                const in_contract = isContractFile(event.location.file);
                // Rule 1 removed (2026-07-17): a `.k` is a full program, not a
                // contract-only surface. Private events are legal in `.k` —
                // they implement as pure Koru in-file and local flows call
                // them; forcing them to a `.kz`/`.kjs` companion "just because"
                // is backwards. See 140_010 (positive pin) and 140_006 (the old
                // Rule-1 negative, marked TODO for rework into a cross-module
                // visibility test).
                if (!in_contract and event.is_public and module_has_k) {
                    try reporter.addErrorWithHint(
                        .KORU111,
                        event.location.line,
                        event.location.column,
                        "public tor in implementation file '{s}' when a .k contract companion exists in the same module",
                        .{event.location.file},
                        "public event declarations belong in the .k contract — move this ~pub event to the sibling .k file, or drop ~pub if it is internal scaffolding",
                        .{},
                    );
                }
            },
            .module_decl => |module| {
                try validate(module.items, reporter);
            },
            else => {},
        }
    }
}

/// True iff `file_path` ends with the `.k` extension specifically, distinct
/// from `.kz` / `.kjs` / `.kc` / `.kgpu`. Uses the longest-first match in
/// `file_types.koruExtensionOf` so `helper.kz` does not pattern-match as
/// `.k`.
fn isContractFile(file_path: []const u8) bool {
    const ext = file_types.koruExtensionOf(file_path) orelse return false;
    return std.mem.eql(u8, ext, ".k");
}
