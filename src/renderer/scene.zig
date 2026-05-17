const std = @import("std");
const v = @import("../vec_math.zig");
const rc = @import("../rc_ptr.zig");
const r = @import("renderer.zig");

const Camera = @import("camera.zig");
const Light = @import("light.zig");

pub const Vec3f = v.Vec(3, f32);
pub const Vec4f = v.Vec(4, f32);
pub const Mat4f = v.Mat(4, 4, f32);

pub const Object = @import("scene_object.zig");

camera: Camera,
light: Light,
objects: std.array_list.Aligned(Object.Rc, null),
renderer: *r.Renderer,

pub const Self = @This();

pub fn init(self: *Self, rend: *r.Renderer) !void {
    self.camera = .{};
    self.light = .{};
    self.objects = try std.array_list.Aligned(Object.Rc, null).initCapacity(rend.gfx.alloc, 16);
    self.renderer = rend;
}

pub fn deinit(self: *Self) void {
    for (self.objects.items) |*obj|
        obj.clear(self.alloc());
    self.objects.deinit(self.alloc());
}

pub fn render(self: *Self, submit: *r.SubmitInfo) !void {
    for (self.objects.items) |*obj|
        try obj.data().?.render(submit);
}

fn alloc(self: *Self) std.mem.Allocator {
    return self.renderer.gfx.alloc;
}