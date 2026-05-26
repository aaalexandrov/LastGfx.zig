const std = @import("std");
const v = @import("../vec_math.zig");

pub const Vec3f = v.Vec(3, f32);

pub const Properties = extern struct {
    direction: [3]f32 = Vec3f.normalize(.{ 1, 2, 3 }),
    color: [3]f32 = .{ 1, 1, 1 },
};

properties: Properties = .{},
