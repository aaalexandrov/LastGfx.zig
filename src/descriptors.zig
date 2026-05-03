const std = @import("std");
const c = @import("cimport.zig").c;
const vk = @import("vk_gfx.zig");
const range = @import("range_allocator.zig");

pub const DescriptorHeapWriter = struct {
    descHeap: *vk.DescriptorHeap,
    memArena: std.heap.ArenaAllocator,
    updatesData: ByteArrayList,
    updateDstToUpdateIndex: U64HashMap,
    updatesSize: u64 = 0,

    const ByteArrayList = std.array_list.Aligned(u8, null);
    const U64HashMap = std.array_hash_map.AutoArrayHashMapUnmanaged(u64, u64);

    pub const Self = @This();

    pub fn init(descHeap: *vk.DescriptorHeap) !Self {
        const gfx = descHeap.deviceBuffer.gfx;
        return Self{
            .descHeap = descHeap,
            .memArena = std.heap.ArenaAllocator.init(gfx.alloc),
            .updatesData = try ByteArrayList.initCapacity(gfx.alloc, 0),
            .updateDstToUpdateIndex = try U64HashMap.init(gfx.alloc, &.{}, &.{}),
        };
    }

    pub fn deinit(self: *Self) void {
        const gfx = self.getGfx();
        self.memArena.deinit();
        self.updatesData.deinit(gfx.alloc);
        self.updateDstToUpdateIndex.deinit(gfx.alloc);
    }

    pub fn clear(self: *Self, freeMemory: bool) void {
        if (freeMemory) {
            self.memArena.reset(.free_all);
            self.updatesData.clearAndFree(self.descHeap.gfx.alloc);
            self.updateDstToUpdateIndex.clearAndFree(self.getGfx().alloc);
        } else {
            self.memArena.reset(.retain_capacity);
            self.updatesData.clearRetainingCapacity(self.getGfx().alloc);
            self.updateDstToUpdateIndex.clearRetainingCapacity(self.getGfx().alloc);
        }
        self.udpatesSize = 0;
    }

    pub fn setSampler(self: *Self, dstIndex: u64, samplerInfo: *const c.VkSamplerCreateInfo) !void {
        const updateSlice = try self.getUpdateStructSlice(dstIndex);
        @memcpy(updateSlice, std.mem.asBytes(samplerInfo));
        self.updatesSize += self.getDescriptorSizeFromUpdate(updateSlice);
    }

    pub fn setBuffer(self: *Self, dstIndex: u64, buffer: *vk.Buffer, offset: u64, size: u64) !void {
        const updateSlice = try self.getUpdateStructSlice(dstIndex);
        const descInfo: *c.VkResourceDescriptorInfoEXT = @ptrCast(@alignCast(updateSlice));
        try buffer.writeDescriptorData(descInfo, self.memArena.allocator(), offset, size);
        self.updatesSize += self.getDescriptorSizeFromUpdate(updateSlice);
    }

    pub fn setImage(self: *Self, dstIndex: u64, image: *vk.Image) !void {
        const updateSlice = try self.getUpdateStructSlice(dstIndex);
        const descInfo: *c.VkResourceDescriptorInfoEXT = @ptrCast(@alignCast(updateSlice));
        try image.writeDescriptorData(descInfo, self.memArena.allocator());
        self.updatesSize += self.getDescriptorSizeFromUpdate(updateSlice);
    }

    pub fn writeDescriptors(self: *Self, dst: []u8) !void {
        std.debug.assert(dst.len == self.updatesSize);

        const gfx = self.getGfx();

        const hostAddresses = try gfx.alloc.alloc(c.VkHostAddressRangeEXT, self.updateDstToUpdateIndex.count());
        defer gfx.alloc.free(hostAddresses);

        const updateStructSize = self.getUpdateStructSize();
        var descOffs: u64 = 0;
        for (hostAddresses, 0..) |*hostAddr, i| {
            const descSize = self.getDescriptorSizeFromUpdateIndex(updateStructSize, i);
            hostAddr.* = .{
                .address = &dst[descOffs],
                .size = descSize,
            };
            descOffs += descSize;
        }
        
        switch (self.descHeap.kind) {
            .Sampler => 
                try vk.check(gfx.writeSamplerDescriptorsEXT.?(gfx.device.handle, @intCast(hostAddresses.len), @ptrCast(@alignCast(self.updatesData.items.ptr)), hostAddresses.ptr)),
            .Resource =>
                try vk.check(gfx.writeResourceDescriptorsEXT.?(gfx.device.handle, @intCast(hostAddresses.len), @ptrCast(@alignCast(self.updatesData.items.ptr)), hostAddresses.ptr)),
        }
    }

    pub fn uploadSetDescriptors(self: *Self, cmd: *vk.Commands, staging: *vk.Buffer, offsetInBuffer: u64) !void {
        const stagingSlice = staging.hostAddress.?[offsetInBuffer .. offsetInBuffer + self.updatesSize];
        std.debug.assert(offsetInBuffer + self.updatesSize <= staging.desc.size);

        try self.writeDescriptors(stagingSlice);

        const gfx = self.getGfx();
        const copy2 = try gfx.alloc.alloc(c.VkBufferCopy2, self.updateDstToUpdateIndex.count());
        defer gfx.alloc.free(copy2);

        const updateStructSize = self.getUpdateStructSize();
        var updateDst = self.updateDstToUpdateIndex.iterator();
        while (updateDst.next()) |dstToUpdateIndex| {
            const updateIdx = dstToUpdateIndex.value_ptr.*;
            const descSize = self.getDescriptorSizeFromUpdateIndex(updateStructSize, updateIdx);
            const descIdx = dstToUpdateIndex.key_ptr.*;
            copy2[updateIdx] = .{
                .sType = c.VK_STRUCTURE_TYPE_BUFFER_COPY_2,
                .dstOffset = descIdx * descSize,
                .size = descSize,
            };
        }

        var srcOffs: u64 = offsetInBuffer;
        for (copy2) |*copy| {
            copy.srcOffset = srcOffs;
            srcOffs += copy.size;
        }

        cmd.copyBuffer(staging, &self.descHeap.deviceBuffer, copy2);
    }

    fn getGfx(self: *Self) *vk.Gfx {
        return self.descHeap.deviceBuffer.gfx;
    }

    fn getUpdateStructSize(self: *Self) u64 {
        return switch (self.descHeap.kind) {
            .Sampler => @sizeOf(c.VkSamplerCreateInfo),
            .Resource => @sizeOf(c.VkResourceDescriptorInfoEXT),
        };
    }

    fn getUpdateStructSlice(self: *Self, dstIndex: u64) ![]u8 {
        const structSize = self.getUpdateStructSize();
        const dstToOffs = try self.updateDstToUpdateIndex.getOrPut(self.getGfx().alloc, dstIndex);
        if (!dstToOffs.found_existing) {
            std.debug.assert(dstToOffs.key_ptr.* == dstIndex);
            dstToOffs.value_ptr.* = self.updatesData.items.len / structSize;
            return try self.updatesData.addManyAsSlice(self.getGfx().alloc, structSize);
        }
        const structOffs = structSize * dstToOffs.value_ptr.*;
        return self.updatesData.items[structOffs .. structOffs + structSize];
    }

    fn getDescriptorSizeFromUpdate(self: *Self, updateSlice: []const u8) u64 {
        const gfx = self.getGfx();
        return switch (self.descHeap.kind) {
            .Sampler => gfx.physical.descriptorHeapProps.samplerDescriptorSize,
            .Resource => sz: {
                const descInfo: *const c.VkResourceDescriptorInfoEXT = @ptrCast(@alignCast(updateSlice));
                break :sz switch (descInfo.type) {
                    c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
                    c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
                    c.VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT => 
                        gfx.physical.descriptorHeapProps.imageDescriptorSize,
                    c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER => 
                        gfx.physical.descriptorHeapProps.bufferDescriptorSize,
                    else =>
                        unreachable,
                };
            },
        };
    }

    fn getDescriptorSizeFromUpdateIndex(self: *Self, updateStructSize: u64, updateIdx: usize) u64 {
        const updateOffs = updateIdx * updateStructSize;
        const updateSlice = self.updatesData.items[updateOffs .. updateOffs + updateStructSize];
        const descSize = self.getDescriptorSizeFromUpdate(updateSlice);
        return descSize;
    }
};

pub const DescriptorHeapManaged = struct {
    descHeap: vk.DescriptorHeap,
    writer: vk.DescriptorHeapWriter,
    rangeAlloc: range.RangeAlloc,

    pub const Self = @This();

    pub fn init(self: *Self, gfx: *vk.Gfx, kind: vk.DescriptorHeap.Kind, numDescriptors: u64) !void {
        self.descHeap = try vk.DescriptorHeap.init(gfx, kind, numDescriptors);
        self.writer = try vk.DescriptorHeapWriter.init(&self.descHeap);
        try self.rangeAlloc.init(0, self.descHeap.deviceBuffer.size - self.descHeap.reservedSize, gfx.alloc);
    }

    pub fn deinit(self: *Self) void {
        self.rangeAlloc.deinit();
        self.writer.deinit();
        self.descHeap.deinit();
    }
};
