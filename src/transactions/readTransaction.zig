// readTransaction.zig -- ReadTxn, a pinned read snapshot over a Db.

const Ref = @import("../storage/reference.zig").Ref;
const Db = @import("../database.zig").Db;

pub const ReadTxn = struct {
    db: *Db,
    root_ref: Ref,
    version: u64,
    /// Set by end(). A second end() must be a no-op: decrementing the pin count
    /// again would release another reader's pin at the same version and expose
    /// it to premature space reuse.
    ended: bool = false,

    pub fn root(self: ReadTxn) Ref {
        return self.root_ref;
    }

    pub fn deref(self: *ReadTxn, ref: Ref, len: usize) ![]const u8 {
        return self.db.arena.deref(ref, len);
    }

    pub fn end(self: *ReadTxn) void {
        if (self.ended) return;
        self.ended = true;
        if (self.db.pins.getPtr(self.version)) |ptr| {
            if (ptr.* > 0) ptr.* -= 1;
            if (ptr.* == 0) _ = self.db.pins.remove(self.version);
        }
        self.db.publishPins();
    }
};
