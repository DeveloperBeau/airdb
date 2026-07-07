// readTransaction.zig -- ReadTransaction, a pinned read snapshot over a Database.

const Reference = @import("../storage/reference.zig").Reference;
const Database = @import("../database.zig").Database;

pub const ReadTransaction = struct {
    database: *Database,
    rootRef: Reference,
    version: u64,
    /// Set by end(). A second end() must be a no-op: decrementing the pin count
    /// again would release another reader's pin at the same version and expose
    /// it to premature space reuse.
    ended: bool = false,

    pub fn root(self: ReadTransaction) Reference {
        return self.rootRef;
    }

    pub fn deref(self: *ReadTransaction, ref: Reference, length: usize) ![]const u8 {
        return self.database.arena.deref(ref, length);
    }

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
