const std = @import("std");
const c = @import("c");
const rc = @import("../rc_ptr.zig");
const r = @import("renderer.zig");
const Scene = @import("scene.zig");
const types = @import("../types.zig");

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

    @memcpy(data.getMember("world").?.slice(), std.mem.asBytes(&self.transform));
    @memcpy(data.getMember("view").?.slice(), std.mem.asBytes(&try scene.camera.getViewMatrix()));
    @memcpy(data.getMember("proj").?.slice(), std.mem.asBytes(&scene.camera.getProjectionMatrix()));

    const mesh = self.mesh.data().?;
    const numTriangles = mesh.numIndices / 3;
    @memcpy(data.getMember("positions").?.slice(), &std.mem.toBytes(mesh.buffer.deviceAddress + mesh.getVerticesOffset()));
    @memcpy(data.getMember("triangles").?.slice(), &std.mem.toBytes(mesh.buffer.deviceAddress + mesh.getIndicesOffset()));
    data.getMember("numTriangles").?.getT(u32).?.* = numTriangles;

    data.getMember("cameraPos").?.getT([3]f32).?.* = Vec4f.toDim(3, scene.camera.getPos(), 0);

    @memcpy(data.getMember("material").?.slice(), material.propertiesBuffer);
    @memcpy(data.getMember("light").?.slice(), std.mem.asBytes(&scene.light.properties));
    data.getMember("environmentColor").?.getT([3]f32).?.* = scene.environmentColor;

    submit.cmds.pushData(&staging.deviceAddress());

    submit.cmds.bindRenderPipeline(&material.pipeline.data().?.pipeline);
    submit.cmds.drawMeshTasks(numTriangles, 1, 1);
}
