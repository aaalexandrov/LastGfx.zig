const std = @import("std");
const c = @import("c");
const rc = @import("../rc_ptr.zig");
const r = @import("renderer.zig");
const Scene = @import("scene.zig");

const Material = @import("material.zig");
const Mesh = @import("mesh.zig");
const Light = @import("light.zig");

pub const Vec3f = Scene.Vec3f;
pub const Vec4f = Scene.Vec4f;
pub const Mat4f = Scene.Mat4f;

pub const Rc = rc.SharedPtr(Self, Self.deinit);

transform: Mat4f.Simd = Mat4f.diag(1),
material: Material.Rc = .{},
mesh: Mesh.Rc = .{},

pub const BufferData = extern struct {
    world: Mat4f.Simd,
    view: Mat4f.Simd,
    proj: Mat4f.Simd,

    meshPositions: c.VkDeviceAddress,
    meshTriangles: c.VkDeviceAddress,

    cameraPos: [3]f32,
    numTriangles: u32,

    material: Material.Properties,
    light: Light.Properties,
    environmentColor: [3]f32,
};


pub const Self = @This();

pub fn init(self: *@This()) void {
    _ = self;
}

pub fn deinit(self: *@This(), alloc_: std.mem.Allocator) void {
    self.material.clear(alloc_);
    self.mesh.clear(alloc_);
}

pub fn render(self: *Self, scene: *Scene, submit: *r.SubmitInfo) !void {
    const staging = try submit.staging.alloc(@sizeOf(BufferData), @alignOf(BufferData));
    const data: *BufferData = @ptrCast(@alignCast(staging.slice()));

    const projMat = scene.camera.getProjectionMatrix();
    const viewMat = try scene.camera.getViewMatrix();
    var vm: [4][4]f32 = undefined;
    for (0..4) |i| {
        vm[i] = viewMat[i];
    }
    const viewed = Mat4f.mulMatVec(viewMat, Vec4f.Simd{1, 1, 1, 1});
    var projected = Mat4f.mulMatVec(projMat, viewed);
    projected /= @as(Vec4f.Simd, @splat(projected[3]));

    data.world = self.transform;
    data.view = try scene.camera.getViewMatrix();
    data.proj = scene.camera.getProjectionMatrix();

    const mesh = self.mesh.data().?;
    const numTriangles = mesh.numIndices / 3;
    data.meshPositions = mesh.buffer.deviceAddress + mesh.getVerticesOffset();
    data.meshTriangles = mesh.buffer.deviceAddress + mesh.getIndicesOffset();

    data.cameraPos = Vec4f.toDim(3, scene.camera.getPos(), 0);
    data.numTriangles = numTriangles;

    const material = self.material.data().?;
    data.material = material.properties;
    data.light = scene.light.properties;
    data.environmentColor = scene.environmentColor;

    submit.cmds.pushData(&staging.deviceAddress());

    submit.cmds.bindRenderPipeline(material.pipeline.data().?);
    submit.cmds.drawMeshTasks(numTriangles, 1, 1);
}
