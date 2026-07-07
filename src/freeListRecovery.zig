// freeListRecovery.zig -- decoding the persisted free-list chain back into
// memory when a database is opened or refreshed to a newer committed version.
//
// The free list is persisted by commit as a chain of bounded chunks on the
// arena (see freeList.zig for the chunk format). Decoding walks the chain,
// validates it against forged or bit-rotted refs, and re-validates every
// extent before any of it is trusted for reuse.

const std = @import("std");
const platform = @import("platform.zig");
const Db = @import("database.zig").Db;
const Ref = @import("reference.zig").Ref;
const FreeList = @import("freeList.zig").FreeList;

/// Decode the persisted free-list chain headed at free_list_ref into `out`,
/// returning the HEAD chunk's byte length. `out` must already be initialized;
/// its previous contents are discarded. O(chain length + extent count).
pub fn decodeFreeListNode(db: *Db, free_list_ref: Ref, out: *FreeList) !usize {
    out.reset();
    const limit: u64 = @intCast(db.store.sectionsView().len * platform.section_size);
    var head_len: usize = 0;
    var cref = free_list_ref;
    var hops: usize = 0;
    while (cref != 0) : (hops += 1) {
        if (hops >= FreeList.max_chunks) return error.Corrupt; // ref cycle
        // Read the chunk header to learn the chunk size and successor.
        const hdr = try db.arena.deref(cref, FreeList.chunk_header_bytes);
        const count = std.mem.readInt(u32, hdr[0..4], .little);
        const node_len = FreeList.chunkByteLen(count);
        const node_bytes = try db.arena.deref(cref, node_len);
        const next = try out.decodeChunkAppend(node_bytes);
        // Chunks are written back-to-front, so a legitimate chain's refs
        // strictly DECREASE along the walk. Enforcing that kills forged or
        // bit-rotted cycles outright: a next_ref pointing at itself or any
        // up-chain chunk re-decoded its extents every hop, demanding
        // terabytes of heap before the hop guard could ever fire.
        if (next != 0 and (next % 8 != 0 or next >= cref)) return error.Corrupt;
        if (hops == 0) head_len = node_len;
        cref = next;
    }
    // Validate every decoded extent before trusting it for reuse: the
    // free-list chunks carry no checksum of their own, and the reuse path
    // translates offsets without bounds checks -- a bit-rotted extent
    // would silently hand out live or out-of-bounds bytes as free space.
    for (out.extents.items) |ex| {
        if (ex.len == 0 or ex.offset % 8 != 0) return error.Corrupt;
        if (ex.offset > limit or ex.len > limit - ex.offset) return error.Corrupt;
    }
    return head_len;
}

/// Decode the persisted free-list node at free_list_ref into db.free_list.
/// Sets db.free_list_node_ref and db.free_list_node_len. db.free_list must
/// already be initialized (possibly empty).
pub fn loadFreeList(db: *Db, free_list_ref: Ref) !void {
    const node_len = try decodeFreeListNode(db, free_list_ref, &db.free_list);
    db.free_list_node_ref = free_list_ref;
    db.free_list_node_len = node_len;
}
