const std = @import("std");
const rc = @import("../rc_ptr.zig");
const r = @import("renderer.zig");
const vk = @import("../vk_gfx.zig");

pub const Rc = rc.SharedPtr(Self, Self.deinit);

pub const Properties = extern struct {
    color: [3]f32 = .{1, 0.5, 1},
    roughness: f32 = 0.5,
    metallic: f32 = 0.1,
};

pipeline: r.RcPipeline = .{},
properties: Properties = .{},

pub const Self = @This();

pub fn init(self: *Self) void {
    _ = self;   
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    self.pipeline.clear(alloc);
}