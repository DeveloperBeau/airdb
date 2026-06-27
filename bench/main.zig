const std = @import("std");
const harness = @import("harness.zig");

// Thin entry point: collect args, hand off to the harness. All benchmark
// logic lives in harness.zig so this file stays trivial.
pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    // args slice is owned by the process arena; parseArgs dupes anything it retains.
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var opts = try harness.parseArgs(alloc, args);
    defer opts.deinit(alloc);

    try harness.runAll(alloc, opts);
}
