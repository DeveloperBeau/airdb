//! Captures the column references one query needs from the catalog, once,
//! so evaluation and planning never re-dereference the catalog mid-scan.

const catalog = @import("../schema/catalog.zig");
const Reference = @import("../storage/reference.zig").Reference;

/// The column references one query needs, captured from the catalog once so no
/// catalog dereference slice is held across reads.
pub const Scan = struct {
    propertyReferences: [catalog.maxPropertyCount]Reference,
    propertyKinds: [catalog.maxPropertyCount]catalog.PropertyKind,
    /// Whether property i has a value index the planner can drive off.
    indexed: [catalog.maxPropertyCount]bool,
    valueIndexReferences: [catalog.maxPropertyCount]Reference,
    propertyCount: usize,
    liveColumnReference: Reference,
    keyToRowIndexReference: Reference,

    /// Capture the catalog's per-property references for `catalogReference`.
    /// One catalog node read.
    pub fn open(transaction: anytype, catalogReference: Reference) !Scan {
        const view = try catalog.loadCatalog(transaction, catalogReference);
        var scan: Scan = undefined;
        scan.propertyCount = view.propertyCount;
        scan.liveColumnReference = view.liveColumnReference;
        scan.keyToRowIndexReference = view.keyToRowIndexReference;
        var propertyIndex: usize = 0;
        while (propertyIndex < view.propertyCount) : (propertyIndex += 1) {
            scan.propertyReferences[propertyIndex] = view.propertyColumnReference(propertyIndex);
            scan.propertyKinds[propertyIndex] = view.kind(propertyIndex);
            scan.indexed[propertyIndex] = view.indexed(propertyIndex);
            scan.valueIndexReferences[propertyIndex] = view.valueIndexReference(propertyIndex);
        }
        return scan;
    }
};
