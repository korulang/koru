const std = @import("std");
const ast = @import("ast");
const errors = @import("errors");

/// The release gate: a `~[prototype]` module must never be built for release.
///
/// `~[prototype]` (concepts/frag-prototype-mode-panic-holes.md) is a DEV-ONLY
/// affordance — it lets an incomplete program compile-and-run by synthesizing
/// loud `@panic` holes for unhandled terminal branches. This gate is the other
/// half of that bargain: a `--release` build rejects any module in the graph
/// bearing the annotation, so prototype code can never ship. The dev workflow
/// closes the gap by DELETING the annotation as branches get handled; this pass
/// is what forces the deletion before a release build succeeds.
///
/// Runs FIRST in the analysis phase and only when `--release` is set, so a
/// release build of prototype code is dismissed up front (KORU029) rather than
/// leniently compiled. Without `--release` this never fires — dev builds keep
/// the prototype affordance.
pub const ReleaseGate = struct {
    reporter: *errors.ErrorReporter,

    pub fn init(reporter: *errors.ErrorReporter) ReleaseGate {
        return .{ .reporter = reporter };
    }

    /// Reject the build if the entry module OR any imported module (transitive —
    /// each import is a `module_decl` item) is marked `~[prototype]`. The caller
    /// invokes this only in release mode.
    pub fn check(self: *ReleaseGate, program: *const ast.Program) !void {
        // Entry module.
        for (program.module_annotations) |ann| {
            if (std.mem.eql(u8, ann, "prototype")) {
                try self.reporter.addErrorAtLocation(
                    .KORU029,
                    .{ .file = "release-gate", .line = 0, .column = 0 },
                    "this module is marked ~[prototype] and cannot be built for release (--release) — handle every branch and remove ~[prototype], or drop --release for a dev build",
                    .{},
                );
                return error.ReleaseRejectsPrototype;
            }
        }

        // Imported modules — a release build rejects a prototype anywhere in the
        // graph, not only the entry file.
        for (program.items) |item| {
            if (item == .module_decl) {
                for (item.module_decl.annotations) |ann| {
                    if (std.mem.eql(u8, ann, "prototype")) {
                        try self.reporter.addErrorAtLocation(
                            .KORU029,
                            item.module_decl.location,
                            "imported module '{s}' is marked ~[prototype] and cannot be built for release (--release) — a release build rejects any prototype module in the graph; make it release-clean or drop --release",
                            .{item.module_decl.logical_name},
                        );
                        return error.ReleaseRejectsPrototype;
                    }
                }
            }
        }
    }
};
