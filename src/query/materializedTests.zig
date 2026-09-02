//! Companion suite for materialized.zig: Relations.validate's error set and
//! its ordering. Pure data, no database.
//!
//! Every expected value in this file is written out by hand from the
//! fixture's own construction, never read back from the code under test.
//! Every count bound is a literal derived from the fixture's sizes and the
//! node capacities in indexNode.zig, never from a measurement of this code.

const std = @import("std");
const testing = std.testing;
const materialized = @import("materialized.zig");
const catalog = @import("../schema/catalog.zig");

const Relations = materialized.Relations;
const maxIncludeDepth = materialized.maxIncludeDepth;

// Three properties: int, link, int. Property 1 is the only link.
const threePropertyKinds = [_]catalog.PropertyKind{ .int, .link, .int };

// R1: success cases -----------------------------------------------------

test "R1: validate accepts a link property at depth 1" {
    try (Relations{ .linkProperties = &.{1}, .depth = 1 }).validate(&threePropertyKinds);
}

test "R1: validate accepts an empty property list at the default depth" {
    try (Relations{}).validate(&threePropertyKinds);
}

test "R1: validate accepts depth 0" {
    try (Relations{ .linkProperties = &.{1}, .depth = 0 }).validate(&threePropertyKinds);
}

test "R1: validate accepts depth == maxIncludeDepth" {
    try (Relations{ .linkProperties = &.{1}, .depth = maxIncludeDepth }).validate(&threePropertyKinds);
}

// R2: failure cases, each named and isolated ----------------------------

test "R2: depth past maxIncludeDepth is error.IncludeTooDeep" {
    try testing.expectError(error.IncludeTooDeep, (Relations{ .linkProperties = &.{1}, .depth = maxIncludeDepth + 1 }).validate(&threePropertyKinds));
}

test "R2: a property index outside the type is error.BadProperty" {
    try testing.expectError(error.BadProperty, (Relations{ .linkProperties = &.{3}, .depth = 1 }).validate(&threePropertyKinds));
}

test "R2: an int property is error.UnsupportedInclude" {
    try testing.expectError(error.UnsupportedInclude, (Relations{ .linkProperties = &.{0}, .depth = 1 }).validate(&threePropertyKinds));
}

test "R2: a linkSet property is error.UnsupportedInclude" {
    const kinds = [_]catalog.PropertyKind{ .int, .linkSet };
    try testing.expectError(error.UnsupportedInclude, (Relations{ .linkProperties = &.{1}, .depth = 1 }).validate(&kinds));
}

test "R2: a blob property is error.UnsupportedInclude" {
    const kinds = [_]catalog.PropertyKind{ .int, .blob };
    try testing.expectError(error.UnsupportedInclude, (Relations{ .linkProperties = &.{1}, .depth = 1 }).validate(&kinds));
}

test "R2: a repeated property is error.DuplicateIncludeProperty" {
    const kinds = [_]catalog.PropertyKind{ .int, .link, .link };
    try testing.expectError(error.DuplicateIncludeProperty, (Relations{ .linkProperties = &.{ 1, 1 }, .depth = 1 }).validate(&kinds));
}

test "R2: depth checked before property, so a request that is both too deep and bad is IncludeTooDeep" {
    try testing.expectError(error.IncludeTooDeep, (Relations{ .linkProperties = &.{99}, .depth = maxIncludeDepth + 1 }).validate(&threePropertyKinds));
}

// R3: false-positive validation ------------------------------------------

test "R3: depth == maxIncludeDepth does NOT raise IncludeTooDeep" {
    try (Relations{ .linkProperties = &.{1}, .depth = maxIncludeDepth }).validate(&threePropertyKinds);
}

test "R3: the last valid property index does NOT raise BadProperty" {
    // Property 2 is an int, not a link, on threePropertyKinds, so use a
    // fixture whose last valid index is itself a link to isolate this check.
    const kinds = [_]catalog.PropertyKind{ .int, .link };
    try (Relations{ .linkProperties = &.{1}, .depth = 1 }).validate(&kinds);
}

test "R3: two distinct link properties do NOT raise DuplicateIncludeProperty" {
    const kinds = [_]catalog.PropertyKind{ .int, .link, .link };
    try (Relations{ .linkProperties = &.{ 1, 2 }, .depth = 1 }).validate(&kinds);
}
