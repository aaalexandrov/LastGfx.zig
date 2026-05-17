const std = @import("std");
const r = @import("renderer.zig");
const vk = @import("../vk_gfx.zig");

pub const Properties = struct {
    color: [3]f32 = .{1, 0.5, 1},
    roughness: f32 = 0.5,
    metallic: f32 = 0.1,
};

pipeline: r.RcPipeline = .{},
properties: Properties = .{},