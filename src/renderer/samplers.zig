const std = @import("std");
const vk = @import("../vk_gfx.zig");
const desc = @import("../descriptors.zig");
const ha = @import("../hash_apply.zig");

pub const SamplerCache = std.array_hash_map.ArrayHashMap(
    vk.Sampler.Descriptor, 
    vk.HeapDescriptor, 
    struct {
        pub const hash = ha.getHashApplyStratFn(vk.Sampler.Descriptor, @This(), .DeepRecursive, ha.autoHashFloat);
        pub const eql = std.array_hash_map.getAutoEqlFn(vk.Sampler.Descriptor, @This());
    },
    true
);

cache: SamplerCache,
samplerHeap: *desc.DescriptorHeapManaged,

const Self = @This();

pub fn init(self: *Self, samplerHeap: *desc.DescriptorHeapManaged) !void {
    self.samplerHeap = samplerHeap;
    self.cache = try SamplerCache.init(self.alloc(), &.{}, &.{});
}

pub fn deinit(self: *Self) !void {
    var it = self.cache.iterator();
    while (it.next()) |entry| 
        try self.samplerHeap.freeDescriptor(entry.value_ptr.*);
    self.cache.deinit(self.alloc());
}

pub fn get(self: *Self, samplerDesc: *const vk.Sampler.Descriptor) !vk.HeapDescriptor {
    const cacheRes = try self.cache.getOrPut(self.alloc(), samplerDesc.*);
    if (!cacheRes.found_existing) 
        cacheRes.value_ptr.* = try self.samplerHeap.setDescriptor(&.{.sampler = samplerDesc.*});
    return cacheRes.value_ptr.*;
}

fn alloc(self: *Self) std.mem.Allocator {
    return self.samplerHeap.heap.deviceBuffer.gfx.alloc;
}