const std = @import("std");
const v = @import("../vec_math.zig");

pub const Vec3f = v.Vec(3, f32);
pub const Vec4f = v.Vec(4, f32);
pub const Mat4f = v.Mat(4, 4, f32);

transform: Mat4f.Simd = Mat4f.diag(1),
fovY: f32 = std.math.degreesToRadians(60),
aspect: f32 = 1,
nearZ: f32 = 0.1,
farZ: f32 = 1e1000,

pub const Self = @This();

pub fn getPos(self: *Self) Vec4f.Simd {
    return Mat4f.row(self.transform, 3);
}

pub fn getViewMatrix(self: *Self) !Mat4f.Simd {
    return try Mat4f.inverse(self.transform);
}

pub fn getProjectionMatrix(self: *Self) Mat4f.Simd {
    return Mat4f.perspective(self.fovY, self.aspect, self.nearZ, self.farZ);
}

pub fn translate(self: *Self, delta: Vec3f.Simd) void {
    const vec = Mat4f.mulMatVec(self.transform, Vec3f.toDim(4, delta, 0));
    self.translate[3] += vec;
}

pub fn rotate(self: *Self, angles: Vec3f.Simd) void {
    inline for (0..3) |d| {
        const rot = Mat4f.rotate3D(4, angles[0], Vec4f.cardinal(d, 1));
        self.transform = Mat4f.mul(4, self.transform, rot);
    }
}