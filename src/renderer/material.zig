const std = @import("std");
const rc = @import("../rc_ptr.zig");
const r = @import("renderer.zig");
const vk = @import("../vk_gfx.zig");
const types = @import("../types.zig");

pub const Rc = rc.SharedPtr(Self, Self);

pipeline: r.RcPipeline = .{},

propertiesType: ?*const types.TypeInfo = null,
propertiesBuffer: []align(PropertiesAlignment) u8 = &.{},

pub const PropertiesAlignment = 16;
pub const Self = @This();

pub fn init(self: *Self) void {
    _ = self;   
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    self.freeProperties(alloc);
    self.pipeline.clear(alloc);
}

fn freeProperties(self: *Self, alloc: std.mem.Allocator) void {
    std.debug.assert((self.propertiesBuffer.len > 0) == (self.propertiesType != null));
    if (self.propertiesBuffer.len > 0) {
        alloc.free(self.propertiesBuffer);
        self.propertiesBuffer = &.{};
    }
    self.propertiesType = null;
}

pub fn getProperties(self: *Self) ?types.AnyPtr {
    if (self.propertiesType) |propsType| 
        return types.AnyPtr.init(propsType, self.propertiesBuffer.ptr);
    return null;
}

pub fn setPipeline(self: *Self, pipeline: *r.RcPipeline, alloc: std.mem.Allocator) !void {
    self.freeProperties(alloc);
    self.pipeline.assign(pipeline, alloc);
    if (self.pipeline.data()) |pipe| {
        if (pipe.reflection.find("MaterialProperties")) |materialPropsType| {
            self.propertiesType = materialPropsType;
            std.debug.assert(materialPropsType.alignment <= 16);
            const propsAlignment = comptime std.mem.Alignment.fromByteUnits(PropertiesAlignment);
            self.propertiesBuffer = try alloc.alignedAlloc(u8, propsAlignment, materialPropsType.size);
            @memset(self.propertiesBuffer, 0);
        }
    }
}