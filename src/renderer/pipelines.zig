const std = @import("std");
const vk = @import("../vk_gfx.zig");
const rc = @import("../rc_ptr.zig");
const ha = @import("../hash_apply.zig");

pub const PipelineInfo = struct {
    name: []const u8,
    data: union(enum) {
        graphics: vk.Pipeline.GraphicsState,
        compute: void,
    },
};

pub const RcPipeline = rc.SharedPtr(vk.Pipeline, struct { 
        fn deinit(pipeline: *vk.Pipeline, _: std.mem.Allocator) void {
            pipeline.deinit();
        }
    }.deinit);

pub const PipelineCache = std.array_hash_map.ArrayHashMap(
    PipelineInfo, 
    RcPipeline.WeakPtr, 
    struct {
        pub const hash = ha.getHashApplyStratFn(PipelineInfo, @This(), .DeepRecursive, ha.autoHashFloat);
        pub const eql = std.array_hash_map.getAutoEqlFn(PipelineInfo, @This());
    },
    true
);

pub const Self = @This();

cache: PipelineCache = undefined,
gfx: *vk.Gfx,

pub fn init(self: *Self, gfx: *vk.Gfx) !void {
    self.gfx = gfx;
    self.cache = try PipelineCache.init(gfx.alloc, &.{}, &.{});
}

pub fn deinit(self: *Self) void {
    var it = self.cache.iterator();
    while (it.next()) |entry|
        entry.value_ptr.clear(self.gfx.alloc);
    self.cache.deinit(self.gfx.alloc);
}

pub fn getPipeline(self: *Self, info: *const PipelineInfo) !RcPipeline {
    const cacheRes = try self.cache.getOrPut(self.gfx.alloc, info.*);
    var res: RcPipeline = .{};
    if (cacheRes.found_existing)
        res.assign(cacheRes.value_ptr, self.gfx.alloc);
    if (res.data() == null) {
        try res.allocate(self.gfx.alloc, try self.loadPipeline(info));
        cacheRes.value_ptr.* = .{};
        cacheRes.value_ptr.assign(&res, self.gfx.alloc);
    }
    return res;
}

pub fn loadPipeline(self: *Self, info: *const PipelineInfo) !vk.Pipeline {
    return switch (info.data) {
        .graphics => |*state| 
            self.loadGraphicsPipeline(info.name, state),
        .compute => 
            self.loadComputePipeline(info.name),
    };
}

pub fn loadGraphicsPipeline(self: *Self, path: []const u8, state: *const vk.Pipeline.GraphicsState) !vk.Pipeline {
    var shaderMesh = mesh: {
        const meshName = try std.mem.joinZ(self.gfx.alloc, "", &[_][]const u8{ path, ".mesh.spv" });
        defer self.gfx.alloc.free(meshName);
        break :mesh try vk.Shader.init(self.gfx, meshName);
    };
    defer shaderMesh.deinit(self.gfx);

    var shaderFrag = frag: {
        const fragName = try std.mem.joinZ(self.gfx.alloc, "", &[_][]const u8{ path, ".frag.spv" });
        defer self.gfx.alloc.free(fragName);
        break :frag try vk.Shader.init(self.gfx, fragName);
    };
    defer shaderFrag.deinit(self.gfx);

    const pipeline = try vk.Pipeline.initGraphics(self.gfx, &shaderMesh, &shaderFrag, state, path);
    return pipeline;
}

pub fn loadComputePipeline(self: *Self, path: []const u8) !vk.Pipeline {
    var shaderCompute = compute: {
        const computeName = try std.mem.joinZ(self.gfx.alloc, "", &[_][]const u8{ path, ".comp.spv" });
        defer self.gfx.alloc.free(computeName);
        break :compute try vk.Shader.init(self.gfx, computeName);
    };
    defer shaderCompute.deinit(self.gfx);

    const pipeline = try vk.Pipeline.initCompute(self.gfx, &shaderCompute, path);
    return pipeline;
}
