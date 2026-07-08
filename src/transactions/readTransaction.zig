//! ReadTransaction, a pinned read snapshot over a Database.

const Reference = @import("../storage/reference.zig").Reference;
const Database = @import("../database.zig").Database;

/// A pinned read snapshot: captures the root and version current at begin
/// time and keeps that version's space from being reused until end().
pub const ReadTransaction = struct {
    database: *Database,
    rootReference: Reference,
    version: u64,
    /// Set by end(). A second end() must be a no-op: decrementing the pin count
    /// again would release another reader's pin at the same version and expose
    /// it to premature space reuse.
    ended: bool = false,

    /// The snapshot's root reference (the type directory as of begin time).
    pub fn root(self: ReadTransaction) Reference {
        return self.rootReference;
    }

    /// Read `length` bytes at `reference` as a zero-copy slice into mapped storage;
    /// valid while this snapshot stays pinned (until end()).
    pub fn dereference(self: *ReadTransaction, reference: Reference, length: usize) ![]const u8 {
        return self.database.arena.dereference(reference, length);
    }

    /// Release this snapshot's pin and republish the process's minimum pinned
    /// version. Idempotent: a second end() is a no-op.
    pub fn end(self: *ReadTransaction) void {
        if (self.ended) return;
        self.ended = true;
        if (self.database.pins.getPtr(self.version)) |ptr| {
            if (ptr.* > 0) ptr.* -= 1;
            if (ptr.* == 0) _ = self.database.pins.remove(self.version);
        }
        self.database.publishPins();
    }
};
