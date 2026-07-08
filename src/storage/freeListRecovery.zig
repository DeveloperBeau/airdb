//! Decoding of the persisted free-list chain back into
//! memory when a database is opened or refreshed to a newer committed version.
//!
//! The free list is persisted by commit as a chain of bounded chunks on the
//! arena (see freeList.zig for the chunk format). Decoding walks the chain,
//! validates it against forged or bit-rotted references, and re-validates every
//! extent before any of it is trusted for reuse.

const std = @import("std");
const platform = @import("../platform.zig");
const Database = @import("../database.zig").Database;
const Reference = @import("reference.zig").Reference;
const FreeList = @import("freeList.zig").FreeList;

/// Decode the persisted free-list chain headed at freeListReference into `out`,
/// returning the HEAD chunk's byte length. `out` must already be initialized;
/// its previous contents are discarded. O(chain length + extent count).
pub fn decodeFreeListNode(database: *Database, freeListReference: Reference, out: *FreeList) !usize {
    out.reset();
    const limit: u64 = @intCast(database.store.sectionsView().len * platform.sectionSize);
    var headLen: usize = 0;
    var catalogReference = freeListReference;
    var hops: usize = 0;
    while (catalogReference != 0) : (hops += 1) {
        if (hops >= FreeList.maxChunks) return error.Corrupt; // reference cycle
        // Read the chunk header to learn the chunk size and successor.
        const header = try database.arena.dereference(catalogReference, FreeList.chunkHeaderBytes);
        const count = std.mem.readInt(u32, header[0..4], .little);
        const nodeLen = FreeList.chunkByteLength(count);
        const nodeBytes = try database.arena.dereference(catalogReference, nodeLen);
        const next = try out.decodeChunkAppend(nodeBytes);
        // Chunks are written back-to-front, so a legitimate chain's references
        // strictly DECREASE along the walk. Enforcing that kills forged or
        // bit-rotted cycles outright: a nextReference pointing at itself or any
        // up-chain chunk re-decoded its extents every hop, demanding
        // terabytes of heap before the hop guard could ever fire.
        if (next != 0 and (next % 8 != 0 or next >= catalogReference)) return error.Corrupt;
        if (hops == 0) headLen = nodeLen;
        catalogReference = next;
    }
    // Validate every decoded extent before trusting it for reuse: the
    // free-list chunks carry no checksum of their own, and the reuse path
    // translates offsets without bounds checks -- a bit-rotted extent
    // would silently hand out live or out-of-bounds bytes as free space.
    for (out.extents.items) |extent| {
        if (extent.len == 0 or extent.offset % 8 != 0) return error.Corrupt;
        if (extent.offset > limit or extent.len > limit - extent.offset) return error.Corrupt;
    }
    return headLen;
}

/// Decode the persisted free-list node at freeListReference into database.freeList.
/// Sets database.freeListNodeReference and database.freeListNodeLen. database.freeList must
/// already be initialized (possibly empty).
pub fn loadFreeList(database: *Database, freeListReference: Reference) !void {
    const nodeLen = try decodeFreeListNode(database, freeListReference, &database.freeList);
    database.freeListNodeReference = freeListReference;
    database.freeListNodeLen = nodeLen;
}
