const std = @import("std");
const vk = @import("../vk_gfx.zig");
const rc = @import("../rc_ptr.zig");
const ha = @import("../hash_apply.zig");
const types = @import("../types.zig");
const spv = @import("../spirv_reflect.zig");

pub const Pipeline = struct {
    pipeline: vk.Pipeline,
    pushType: *const types.TypeInfo,
    reflection: types.TypeRegistry,

    pub fn deinit(self: *@This()) void {
        self.reflection.deinit();
        self.pipeline.deinit();
    }
};

pub const RcPipeline = rc.SharedPtr(Pipeline, rc.DeinitCallContext);

pub const PipelineInfo = struct {
    name: []const u8,
    data: union(enum) {
        graphics: vk.Pipeline.GraphicsState,
        compute: void,
    },
};

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
        if (!cacheRes.found_existing)
            cacheRes.value_ptr.* = .{};
        cacheRes.value_ptr.assign(&res, self.gfx.alloc);
    }
    return res;
}

pub fn loadPipeline(self: *Self, info: *const PipelineInfo) !Pipeline {
    var pipeline = switch (info.data) {
        .graphics => |*state| 
            try self.loadGraphicsPipeline(info.name, state),
        .compute => 
            try self.loadComputePipeline(info.name),
    };
    try @import("uniforms.zig").annotatePipelineTypeInfo(&pipeline);
    return pipeline;
}

fn loadShader(self: *Self, path: []const u8, suffix: []const u8, reflection: *types.TypeRegistry) !vk.Shader {
    var pathBuf: [std.fs.max_path_bytes]u8 = undefined;

    const loadPath = try std.fmt.bufPrint(&pathBuf, "{s}{s}", .{path, suffix});

    const code = try std.Io.Dir.cwd().readFileAllocOptions(self.gfx.io, loadPath, self.gfx.alloc, .unlimited, std.mem.Alignment.of(u32), null);
    defer self.gfx.alloc.free(code);
    const spvCode = std.mem.bytesAsSlice(u32, code);

    const shader = try vk.Shader.initCode(self.gfx, spvCode, loadPath);

    _ = try spv.reflect(spvCode, reflection);

    return shader;
}

pub fn loadGraphicsPipeline(self: *Self, path: []const u8, state: *const vk.Pipeline.GraphicsState) !Pipeline {
    var pipeline: Pipeline = undefined;
    pipeline.reflection = try types.TypeRegistry.init(self.gfx.alloc);
    errdefer pipeline.reflection.deinit();

    var shaderMesh = try loadShader(self, path, ".mesh.spv", &pipeline.reflection);
    defer shaderMesh.deinit(self.gfx);

    var shaderFrag = try loadShader(self, path, ".frag.spv", &pipeline.reflection);
    defer shaderFrag.deinit(self.gfx);

    pipeline.pipeline = try vk.Pipeline.initGraphics(self.gfx, &shaderMesh, &shaderFrag, state, path);
    pipeline.pushType = pipeline.reflection.find("constants").?;
    return pipeline;
}

pub fn loadComputePipeline(self: *Self, path: []const u8) !Pipeline {
    var pipeline: Pipeline = undefined;
    pipeline.reflection = try types.TypeRegistry.init(self.gfx.alloc);
    errdefer pipeline.reflection.deinit();

    var shaderCompute = try loadShader(self, path, ".comp.spv", &pipeline.reflection);
    defer shaderCompute.deinit(self.gfx);

    pipeline.pipeline = try vk.Pipeline.initCompute(self.gfx, &shaderCompute, path);
    return pipeline;
}
