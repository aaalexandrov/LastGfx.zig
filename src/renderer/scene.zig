const std = @import("std");
const v = @import("../vec_math.zig");
const rc = @import("../rc_ptr.zig");

const Camera = @import("camera.zig");
const Light = @import("light.zig");
const Material = @import("material.zig");
const Mesh = @import("mesh.zig");

pub const Vec3f = v.Vec(3, f32);
pub const Vec4f = v.Vec(4, f32);
pub const Mat4f = v.Mat(4, 4, f32);

pub const Object = struct {
    transform: Mat4f,
    material: Material,
    mesh: Mesh,
};

camera: Camera,
light: Light,

