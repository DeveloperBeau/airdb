//! The nested result of an include fetch: the object shape a caller holds,
//! plus the request shape that asks for one. Pure data and one validator that
//! touches no storage, modeled on predicate.zig.

const std = @import("std");
const catalog = @import("../schema/catalog.zig");
const Reference = @import("../storage/reference.zig").Reference;

/// Deepest include nesting accepted. Depths are caller-supplied and will
/// arrive across the C ABI, which is an untrusted boundary.
pub const maxIncludeDepth: usize = 8;

/// One property's value inside a materialized object, decoded from the raw
/// column word. Holds no pointer into mapped storage: the two reference
/// variants are storage references, meaningful only inside the transaction
/// that produced them.
pub const PropertyValue = union(enum) {
    /// An int property's value.
    int: u64,
    /// A to-one link property's target object key, null when the link is unset.
    link: ?u64,
    /// A blob property's storage reference, NOT its bytes. Read the bytes with
    /// `blob.getAlloc(transaction, reference, allocator)` before the producing
    /// transaction ends.
    blobReference: Reference,
    /// A list, set, dict or linkSet property's tree root. Read it through the
    /// collections or links API before the producing transaction ends.
    collectionRoot: Reference,
};

/// What an included relation resolved to.
pub const RelationTarget = union(enum) {
    /// The link is unset (its column word is 0).
    absent,
    /// The target's object key, not materialized: it is a back edge to an
    /// object already materialized at a shallower level (a cycle), or the
    /// target no longer resolves to a live row.
    key: u64,
    /// The materialized target. Owned by the fetch's arena and shared: two
    /// parents linking to one target hold the same pointer.
    object: *const MaterializedObject,
};

/// One included relation on one object: which link property it came from and
/// what that property resolved to.
pub const IncludedRelation = struct {
    /// The source object's link property index.
    property: usize,
    /// What the link resolved to.
    target: RelationTarget,
};

/// One object materialized by an include fetch, allocated from the fetch's
/// arena. `values` holds one entry per property of `typeId`'s schema, in
/// property order. `included` is empty for an object at the depth bound; its
/// relations are then readable from `values` as bare `.link` keys.
pub const MaterializedObject = struct {
    /// The type this object belongs to.
    typeId: u16,
    /// The object's stable object key.
    objectKey: u64,
    /// The row version this fetch read.
    version: u64,
    /// Every property of the object, in property order.
    values: []const PropertyValue,
    /// The relations resolved for this object, in the order they were asked
    /// for. Empty at the depth bound.
    included: []const IncludedRelation,
};

/// Which relations an include fetch resolves, and how deep.
pub const Relations = struct {
    /// Link properties of the ROOT type to resolve. Below the root, every
    /// `.link` property of each type reached is followed.
    linkProperties: []const usize = &.{},
    /// How many levels of links to resolve below the root. 0 resolves
    /// nothing.
    depth: usize = 1,

    /// Reject a request this engine cannot answer, before any row is read:
    /// a depth past `maxIncludeDepth`, a property outside the root type, a
    /// repeated property, or a property whose kind is not `.link` (to-many
    /// `.linkSet` includes are a later phase). Walks the property list once,
    /// O(properties squared) over a list that is at most `maxPropertyCount`
    /// long, no I/O.
    pub fn validate(self: Relations, kinds: []const catalog.PropertyKind) !void {
        if (self.depth > maxIncludeDepth) return error.IncludeTooDeep;
        for (self.linkProperties, 0..) |property, position| {
            if (property >= kinds.len) return error.BadProperty;
            if (kinds[property] != .link) return error.UnsupportedInclude;
            for (self.linkProperties[0..position]) |earlier| {
                if (earlier == property) return error.DuplicateIncludeProperty;
            }
        }
    }
};

test {
    _ = @import("materializedTests.zig");
}
