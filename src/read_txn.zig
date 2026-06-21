// read_txn.zig -- ReadTxn, a pinned read snapshot over a Db.

const Ref = @import("ref.zig").Ref;
const Db = @import("db.zig").Db;

pub const ReadTxn = struct {
    db: *Db,
    root_ref: Ref,
    version: u64,

    pub fn root(self: ReadTxn) Ref {
        return self.root_ref;
    }

    pub fn deref(self: *ReadTxn, ref: Ref, len: usize) ![]const u8 {
        return self.db.arena.deref(ref, len);
    }

    pub fn end(self: *ReadTxn) void {
        if (self.db.pins.getPtr(self.version)) |ptr| {
            if (ptr.* > 0) ptr.* -= 1;
            if (ptr.* == 0) _ = self.db.pins.remove(self.version);
        }
        self.db.publishPins();
    }
};
