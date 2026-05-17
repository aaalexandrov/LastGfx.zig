const std = @import("std");
const v = @import("../vec_math.zig");
const rc = @import("../rc_ptr.zig");
const r = @import("renderer.zig");

const Camera = @import("camera.zig");
const Light = @import("light.zig");
const Material = @import("material.zig");
const Mesh = @import("mesh.zig");

pub const Vec3f = v.Vec(3, f32);
pub const Vec4f = v.Vec(4, f32);
pub const Mat4f = v.Mat(4, 4, f32);

pub const RcMesh = rc.SharedPtr(Mesh, rc.simpleDeinit(Mesh));
pub const RcMaterial = rc.SharedPtr(Material, rc.simpleDeinit(Material));
pub const RcObject = rc.SharedPtr(Object, rc.simpleDeinit(Object));

pub const Object = struct {
    transform: Mat4f,
    material: RcMaterial,
    mesh: RcMesh,
};

camera: Camera,
light: Light,
objects: std.array_list.Aligned(RcObject, null),
renderer: *r.Renderer,

pub const Self = @This();

pub fn init(self: *Self, rend: *r.Renderer) !void {
    self.camera = .{};
    self.light = .{};
    self.objects = std.array_list.Aligned(RcObject, null).initCapacity(rend.gfx.alloc, 16);
    self.renderer = rend;
}

pub fn deinit(self: *Self) void {
    for (self.objects.items) |*obj|
        obj.clear(self.alloc());
    self.objects.deinit(self.alloc());
}

pub fn render(submit: *r.SubmitInfo) !void {
    
}

fn alloc(self: *Self) std.mem.Allocator {
    return self.renderer.gfx.alloc;
}