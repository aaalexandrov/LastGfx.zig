const std = @import("std");
const v = @import("../vec_math.zig");

pub const vec3f = v.Vec(3, f32);
pub const vec4f = v.Vec(4, f32);
pub const mat4f = v.Mat(4, 4, f32);

transform: mat4f.Simd = mat4f.diag(1),
fovY: f32 = std.math.degreesToRadians(60),
aspect: f32 = 1,
nearZ: f32 = 0.1,
farZ: f32 = 1e1000,

pub const Self = @This();

pub fn getPos(self: *Self) vec4f.Simd {
    return mat4f.row(self.transform, 3);
}

pub fn getViewMatrix(self: *Self) mat4f.Simd {
    return mat4f.inverse(self.transform);
}

pub fn getProjectionMatrix(self: *Self) mat4f.Simd {
    return mat4f.perspective(self.fovY, self.aspect, self.nearZ, self.farZ);
}

pub fn translate(self: *Self, delta: vec3f.Simd) void {
    const vec = mat4f.mulMatVec(self.transform, vec3f.toDim(4, delta, 0));
    self.translate[3] += vec;
}

pub fn rotate(self: *Self, angles: vec3f.Simd) void {
    inline for (0..3) |d| {
        const rot = mat4f.rotate3D(4, angles[0], vec4f.cardinal(d, 1));
        self.transform = mat4f.mul(4, self.transform, rot);
    }
}