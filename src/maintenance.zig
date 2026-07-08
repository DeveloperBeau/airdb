//! Caller-driven background upkeep for a database instance.
//!
//! Edge-level entry points that sequence inner-layer machinery (compaction,
//! the type directory) over a Database. Nothing inner imports this file.

const Database = @import("database.zig").Database;
const typeDirectory = @import("schema/typeDirectory.zig");
const compaction = @import("storage/compaction.zig");

/// Outcome of one maybeCompactStep call: whether a step ran, the rows moved,
/// and whether the type is now fully packed.
pub const CompactStepResult = struct { ran: bool, moved: usize, done: bool };

/// Perform at most one budgeted incremental-compaction step on `typeId`,
/// committing the result in its own write transaction. Returns `ran = false`
/// (a no-op) when the type does not yet warrant compaction; otherwise reports
/// the rows moved this step and whether the type is now fully packed.
///
/// Advisory and opt-in: this is never invoked from `commit` or any hot path.
/// The `autoCompact` flag is consulted by callers to decide whether to drive
/// this loop; the function itself does not check it. Does I/O: commits a
/// write transaction when a step runs.
pub fn maybeCompactStep(database: *Database, typeId: u16, budget: usize) !CompactStepResult {
    var writeTransaction = try database.beginWrite();
    errdefer writeTransaction.deinit();
    const directoryReference = database.activeRoot;
    const catalogReference = try typeDirectory.catalogReference(&writeTransaction, directoryReference, typeId);
    if (!try compaction.shouldCompact(&writeTransaction, catalogReference)) {
        writeTransaction.deinit();
        return .{ .ran = false, .moved = 0, .done = false };
    }
    const step = try compaction.compactStep(&writeTransaction, catalogReference, typeId, budget);
    const newDirectoryReference = try typeDirectory.setCatalogReference(&writeTransaction, directoryReference, typeId, step.catalogReference);
    writeTransaction.setRoot(newDirectoryReference);
    _ = try writeTransaction.commit();
    return .{ .ran = true, .moved = step.moved, .done = step.done };
}
