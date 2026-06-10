const std = @import("std");
const c = @import("c");
const rc = @import("../rc_ptr.zig");
const r = @import("renderer.zig");
const Scene = @import("scene.zig");
const types = @import("../types.zig");
const uni = @import("uniforms.zig");

const Material = @import("material.zig");
const Mesh = @import("mesh.zig");
const Light = @import("light.zig");

pub const Vec3f = Scene.Vec3f;
pub const Vec4f = Scene.Vec4f;
pub const Mat4f = Scene.Mat4f;

pub const Rc = rc.SharedPtr(Self, Self);

transform: Mat4f.Simd = Mat4f.diag(1),
material: Material.Rc = .{},
mesh: Mesh.Rc = .{},

pub const Self = @This();

pub fn init(self: *@This()) void {
    _ = self;
}

pub fn deinit(self: *@This(), alloc_: std.mem.Allocator) void {
    self.material.clear(alloc_);
    self.mesh.clear(alloc_);
}

pub fn render(self: *Self, scene: *Scene, submit: *r.SubmitInfo) !void {
    const material = self.material.data().?;
    const pushType = material.pipeline.data().?.pushType;
    const bufferType = pushType.getMember("inputData").?.typeInfo.info.Pointer.pointedType;

    const staging = try submit.staging.alloc(bufferType.size, Material.PropertiesAlignment);
    const data = types.AnyPtr.init(bufferType, staging.slice().ptr);

    const resolveData = uni.ResolveData{
        .object = self,
        .scene = scene,
    };
    uni.updateUniforms(data, &resolveData);

    const mesh = self.mesh.data().?;
    const numTriangles = mesh.numIndices / 3;

    submit.cmds.pushData(&staging.deviceAddress());

    submit.cmds.bindRenderPipeline(&material.pipeline.data().?.pipeline);
    submit.cmds.drawMeshTasks(numTriangles, 1, 1);
}
