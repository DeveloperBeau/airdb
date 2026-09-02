//! Test suite for grouping.zig's own units that need no database:
//! validateGroupableProperty, Grouping.validate, and isOrderedByValue.

const std = @import("std");
const testing = std.testing;
const catalog = @import("../schema/catalog.zig");
const scanModule = @import("scan.zig");
const Scan = scanModule.Scan;
const grouping = @import("grouping.zig");
const Group = grouping.Group;
const Grouping = grouping.Grouping;
const validateGroupableProperty = grouping.validateGroupableProperty;
const isOrderedByValue = grouping.isOrderedByValue;

// A Scan with two properties: 0 = int, 1 = the kind under test. Neither is
// indexed; validateGroupableProperty and Grouping.validate touch no I/O and
// do not consult scan.indexed, so a plain struct with zeroed references is
// enough, following orderingTests.zig's makeScan.
fn makeScan(secondKind: catalog.PropertyKind) Scan {
    var scan: Scan = undefined;
    scan.propertyCount = 2;
    scan.propertyKinds[0] = .int;
    scan.propertyKinds[1] = secondKind;
    scan.indexed[0] = false;
    scan.indexed[1] = false;
    scan.propertyReferences[0] = 0;
    scan.propertyReferences[1] = 0;
    scan.valueIndexReferences[0] = 0;
    scan.valueIndexReferences[1] = 0;
    scan.liveColumnReference = 0;
    scan.keyToRowIndexReference = 0;
    return scan;
}

test "V1: validateGroupableProperty accepts .int" {
    const scan = makeScan(.int);
    try validateGroupableProperty(&scan, 0);
}

test "V2: validateGroupableProperty accepts .link" {
    const scan = makeScan(.link);
    try validateGroupableProperty(&scan, 1);
}

test "V3: validateGroupableProperty rejects .blob" {
    const scan = makeScan(.blob);
    try testing.expectError(error.UnsupportedGrouping, validateGroupableProperty(&scan, 1));
}

test "V4: validateGroupableProperty rejects every remaining collection kind" {
    for ([_]catalog.PropertyKind{ .list, .set, .linkSet, .dict }) |kind| {
        const scan = makeScan(kind);
        try testing.expectError(error.UnsupportedGrouping, validateGroupableProperty(&scan, 1));
    }
}

test "V5: validateGroupableProperty rejects a property index equal to propertyCount" {
    const scan = makeScan(.int);
    try testing.expectError(error.BadProperty, validateGroupableProperty(&scan, scan.propertyCount));
}

test "V6: false-positive validation, propertyCount - 1 is accepted" {
    const scan = makeScan(.int);
    try validateGroupableProperty(&scan, scan.propertyCount - 1);
}

test "V7: Grouping.validate rejects when only the second property is bad" {
    const scan = makeScan(.blob);
    const grouped = Grouping{ .groupProperty = 0, .aggregateProperty = 1 };
    try testing.expectError(error.UnsupportedGrouping, grouped.validate(&scan));
}

test "V8: isOrderedByValue is a strict order" {
    const low = Group{ .value = 1, .aggregate = .{} };
    const high = Group{ .value = 2, .aggregate = .{} };
    try testing.expect(isOrderedByValue({}, low, high));
    try testing.expect(!isOrderedByValue({}, high, low));
    try testing.expect(!isOrderedByValue({}, low, low));
}
