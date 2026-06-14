pub const Ref = @import("ref.zig").Ref;

test {
    @import("std").testing.refAllDecls(@This());
}
