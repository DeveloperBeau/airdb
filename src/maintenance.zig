// maintenance.zig -- caller-driven background upkeep for a database instance.
//
// Edge-level entry points that sequence inner-layer machinery (compaction,
// the type directory) over a Database. Nothing inner imports this file.

const Database = @import("database.zig").Database;
const typedir = @import("schema/typeDirectory.zig");
const compaction = @import("storage/compaction.zig");

/// Outcome of one maybeCompactStep call: whether a step ran, the rows moved,
/// and whether the type is now fully packed.
pub const CompactStepResult = struct { ran: bool, moved: usize, done: bool };

/// Perform at most one budgeted incremental-compaction step on `type_id`,
/// committing the result in its own write transaction. Returns `ran = false`
/// (a no-op) when the type does not yet warrant compaction; otherwise reports
/// the rows moved this step and whether the type is now fully packed.
///
/// Advisory and opt-in: this is never invoked from `commit` or any hot path.
/// The `auto_compact` flag is consulted by callers to decide whether to drive
/// this loop; the function itself does not check it. Does I/O: commits a
/// write transaction when a step runs.
pub fn maybeCompactStep(database: *Database, type_id: u16, budget: usize) !CompactStepResult {
    var w = try database.beginWrite();
    errdefer w.deinit();
    const dir = database.active_root;
    const catalogRef = try typedir.catalogRef(&w, dir, type_id);
    if (!try compaction.shouldCompact(&w, catalogRef)) {
        w.deinit();
        return .{ .ran = false, .moved = 0, .done = false };
    }
    const step = try compaction.compactStep(&w, catalogRef, type_id, budget);
    const new_dir = try typedir.setCatalogRef(&w, dir, type_id, step.catalogRef);
    w.setRoot(new_dir);
    _ = try w.commit();
    return .{ .ran = true, .moved = step.moved, .done = step.done };
}
