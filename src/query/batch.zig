//! The anti-N+1 primitive: turn a sorted key list into rows in one ascending
//! walk of the key->row index. One responsibility, and nothing else: this
//! file imports only std, storage/reference.zig and trees/index.zig, which is
//! what makes it measurable in isolation and keeps its callers honest about
//! going through it.

const std = @import("std");
const Reference = @import("../storage/reference.zig").Reference;
const index = @import("../trees/index.zig");

/// Resolve `sortedObjectKeys` to their physical rows in ONE ascending walk of
/// the key->row index, writing each key's row into `rowsOut` at the same
/// position and `null` where the key has no entry. `rowsOut.len` must equal
/// `sortedObjectKeys.len`.
///
/// `sortedObjectKeys` must be strictly ascending (sorted and deduplicated);
/// `error.UnsortedObjectKeys` otherwise, checked before any I/O. Sorting first
/// is the point: it replaces one random descent per key with a single
/// sequential pass.
///
/// Cost: O(entries between the smallest and largest key) with I/O, NOT
/// O(keys). One walk beats N descents when the keys are dense in the index's
/// key space, which is the normal case because object keys are handed out in
/// insertion order; for a handful of keys spread across a large type the walk
/// reads the whole span and costs more than N descents would. The upgrade
/// path, if a workload ever needs it, is a walk that reseeks over large gaps
/// (`bTreeCore.forEachEntryFromWhile`, not currently exported by index.zig).
///
/// Reads no columns and checks no liveness: a key whose row is tombstoned
/// still yields its row here. The caller checks the live column.
pub fn collectRowsForSortedKeys(
    transaction: anytype,
    keyToRowIndexReference: Reference,
    sortedObjectKeys: []const u64,
    rowsOut: []?u64,
) !void {
    std.debug.assert(rowsOut.len == sortedObjectKeys.len);
    @memset(rowsOut, null);
    if (sortedObjectKeys.len == 0) return;
    var checkIndex: usize = 1;
    while (checkIndex < sortedObjectKeys.len) : (checkIndex += 1) {
        if (sortedObjectKeys[checkIndex] <= sortedObjectKeys[checkIndex - 1]) return error.UnsortedObjectKeys;
    }
    const Merge = struct {
        sortedObjectKeys: []const u64,
        rowsOut: []?u64,
        position: usize = 0,
        fn onEntry(self: *@This(), objectKey: u64, row: u64) anyerror!bool {
            while (self.position < self.sortedObjectKeys.len and self.sortedObjectKeys[self.position] < objectKey) self.position += 1;
            if (self.position == self.sortedObjectKeys.len) return false;
            if (self.sortedObjectKeys[self.position] == objectKey) {
                self.rowsOut[self.position] = row;
                self.position += 1;
            }
            return self.position < self.sortedObjectKeys.len;
        }
    };
    var merge = Merge{ .sortedObjectKeys = sortedObjectKeys, .rowsOut = rowsOut };
    _ = try index.forEachEntryInRangeWhile(
        transaction,
        keyToRowIndexReference,
        sortedObjectKeys[0],
        sortedObjectKeys[sortedObjectKeys.len - 1],
        &merge,
        Merge.onEntry,
    );
}

test {
    _ = @import("batchTests.zig");
}
