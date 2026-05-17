const std = @import("std");
const rc = @import("../rc_ptr.zig");
const r = @import("renderer.zig");
const Scene = @import("scene.zig");

const Material = @import("material.zig");
const Mesh = @import("mesh.zig");

pub const Vec3f = Scene.Vec3f;
pub const Vec4f = Scene.Vec4f;
pub const Mat4f = Scene.Mat4f;

pub const Rc = rc.SharedPtr(Self, Self.deinit);

transform: Mat4f.Simd = Mat4f.diag(1),
material: Material.Rc = .{},
mesh: Mesh.Rc = .{},

pub const Self = @This();

pub fn init(self: *@This()) void {
    _ = self;
}

pub fn deinit(self: *@This(), alloc_: std.mem.Allocator) void {
    self.material.clear(alloc_);
}

pub fn render(self: *Self, submit: *r.SubmitInfo) !void {
    _ = self;
    _ = submit;
}
