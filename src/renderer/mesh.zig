const std = @import("std");
const rc = @import("../rc_ptr.zig");
const r = @import("renderer.zig");
const vk = @import("../vk_gfx.zig");
const c = @import("c");

pub const Rc = rc.SharedPtr(Self, rc.DeinitCallContext);

vertexSize: u32,
numVertices: u32,
numIndices: u32,
buffer: vk.Buffer,

pub const Self = @This();

pub fn init(gfx: *vk.Gfx, vertexSize: u32, numVertices: u32, numIndices: u32) !Self {
    var self = Self{
        .vertexSize = vertexSize,
        .numVertices = numVertices,
        .numIndices = numIndices,
        .buffer = undefined,
    };
    self.buffer = try vk.Buffer.init(gfx, &.{
        .size = self.getIndicesSize() + self.getVerticesSize(), 
        .usage = .{.transferDst = true, .storageRead = true}
    });
    return self;
}

pub fn initData(submit: *r.SubmitInfo, vertexSize: u32, vertexData: []const u8, indices: [] const u32) !Self {
    std.debug.assert(vertexData.len % vertexSize == 0);
    var self = try init(&submit.renderer.gfx, vertexSize, @intCast(vertexData.len / vertexSize), @intCast(indices.len));

    const staging = try submit.staging.alloc(self.buffer.desc.size, self.buffer.desc.alignment);
    const stagingMem = staging.slice();
    @memcpy(stagingMem[self.getIndicesOffset()..][0..self.getIndicesSize()], std.mem.sliceAsBytes(indices));
    @memcpy(stagingMem[self.getVerticesOffset()..][0..self.getVerticesSize()], vertexData);

    submit.cmds.copyBuffer(staging.buffer, &self.buffer, &[_]c.VkBufferCopy2{
        .{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_COPY_2,
            .srcOffset = staging.offset,
            .dstOffset = 0,
            .size = self.buffer.desc.size,
        },
    });

    return self;
}

pub fn deinit(self: *Self) void {
    self.buffer.deinit();
}

pub fn getVerticesSize(self: *Self) u64 {
    return self.vertexSize * self.numVertices;
}

pub fn getIndicesSize(self: *Self) u64 {
    return @sizeOf(u32) * self.numIndices;
}

pub fn getVerticesOffset(self: *Self) u64 {
    _ = self;
    return 0;
}

pub fn getIndicesOffset(self: *Self) u64 {
    return self.getVerticesSize();
}

