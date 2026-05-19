const std = @import("std");

pub const Properties = extern struct {
    direction: [3]f32 = .{0.5773, 0.5773, 0.5773},
    color: [3]f32 = .{1, 1, 1},
};

properties: Properties = .{},