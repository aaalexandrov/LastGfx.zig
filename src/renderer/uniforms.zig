const std = @import("std");
const types = @import("../types.zig");

const Pipelines = @import("pipelines.zig");
const Scene = @import("scene.zig");

const Material = @import("material.zig");
const Mesh = @import("mesh.zig");
const Light = @import("light.zig");

pub const Vec3f = Scene.Vec3f;
pub const Vec4f = Scene.Vec4f;
pub const Mat4f = Scene.Mat4f;

pub const ResolveData = struct {
    scene: *Scene,
    object: *Scene.Object,
};

pub const ResolveFunc = fn (ptr: types.AnyPtr, data: *const ResolveData) void;

pub const UpdatedUniform = struct {
    typeInfo: *const types.TypeInfo,
    offset: u32,
    updateFunc: *const ResolveFunc,
};

pub const UniformUpdates = []const UpdatedUniform;

pub fn annotatePipelineTypeInfo(pipeline: *Pipelines.Pipeline) !void {
    annotateType(@constCast(pipeline.pushType), 0, &pipeline.reflection, null) catch unreachable;
}

fn annotateType(typeInfo: *types.TypeInfo, offset: u32, registry: *types.TypeRegistry, updates: ?*std.ArrayListUnmanaged(UpdatedUniform)) !void {
    std.debug.assert(!(updates == null and offset != 0));
    var localUpdates: std.ArrayListUnmanaged(UpdatedUniform) = .empty;
    defer localUpdates.deinit(registry.alloc);
    const effectiveUpdates = updates orelse &localUpdates;

    switch (typeInfo.info) {
        .Pointer => |ptr| {
            try annotateType(@constCast(ptr.pointedType), 0, registry, null);
        },
        .Array => |arr| {
            for (0..arr.length) |i| {
                try annotateType(@constCast(arr.elementType), @intCast(offset + i * arr.elementType.size), registry, effectiveUpdates);
            }
        },
        .Struct => |str| {
            for (str.members) |*member| {
                if (ResolveTable.get(member.name)) |func| {
                    try effectiveUpdates.append(registry.alloc, .{
                        .typeInfo = member.typeInfo,
                        .offset = @intCast(offset + member.offset),
                        .updateFunc = func,
                    });
                } else {
                    try annotateType(@constCast(member.typeInfo), @intCast(offset + member.offset), registry, effectiveUpdates);
                }
            }
        },
        else => {},
    }

    if (effectiveUpdates == &localUpdates and localUpdates.items.len > 0) {
        _ = try typeInfo.metadata.addT(UniformUpdates, "UniformUpdates", &try localUpdates.toOwnedSlice(registry.alloc), registry);
    }
}


const ResolvePairs: []const struct{[]const u8, *const ResolveFunc} = &.{
    .{ "world", getWorld },
    .{ "view", getView },
    .{ "proj", getProj },
    .{ "positions", getPositions },
    .{ "triangles", getTriangles },
    .{ "numTriangles", getNumTriangles },
    .{ "cameraPos", getCameraPos },
    .{ "material", getMaterial },
    .{ "light", getLight },
    .{ "environmentColor", getEnvironmentColor },
};

var ResolveTable: std.StaticStringMap(*const ResolveFunc) = .initComptime(ResolvePairs);

fn getWorld(ptr: types.AnyPtr, data: *const ResolveData) void {
    @memcpy(ptr.slice(), std.mem.asBytes(&data.object.transform));
}

fn getView(ptr: types.AnyPtr, data: *const ResolveData) void {
    @memcpy(ptr.slice(), std.mem.asBytes(&(data.scene.camera.getViewMatrix() catch unreachable)));
}

fn getProj(ptr: types.AnyPtr, data: *const ResolveData) void {
    @memcpy(ptr.slice(), std.mem.asBytes(&data.scene.camera.getProjectionMatrix()));
}

fn getPositions(ptr: types.AnyPtr, data: *const ResolveData) void {
    const mesh = data.object.mesh.data().?;
    @memcpy(ptr.slice(), &std.mem.toBytes(mesh.buffer.deviceAddress + mesh.getVerticesOffset()));
}

fn getTriangles(ptr: types.AnyPtr, data: *const ResolveData) void {
    const mesh = data.object.mesh.data().?;
    @memcpy(ptr.slice(), &std.mem.toBytes(mesh.buffer.deviceAddress + mesh.getIndicesOffset()));
}

fn getNumTriangles(ptr: types.AnyPtr, data: *const ResolveData) void {
    const mesh = data.object.mesh.data().?;
    ptr.getT(u32).?.* = mesh.numIndices / 3;
}

fn getCameraPos(ptr: types.AnyPtr, data: *const ResolveData) void {
    ptr.getT([3]f32).?.* = Vec4f.toDim(3, data.scene.camera.getPos(), undefined);
}

fn getMaterial(ptr: types.AnyPtr, data: *const ResolveData) void {
    const material = data.object.material.data().?;
    @memcpy(ptr.slice(), material.propertiesBuffer);
}

fn getLight(ptr: types.AnyPtr, data: *const ResolveData) void {
    @memcpy(ptr.slice(), std.mem.asBytes(&data.scene.light.properties));
}

fn getEnvironmentColor(ptr: types.AnyPtr, data: *const ResolveData) void {
    ptr.getT([3]f32).?.* = data.scene.environmentColor;
}