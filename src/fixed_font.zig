const std = @import("std");
const vk = @import("vk_gfx.zig");
const zstbi = @import("zstbi");

image: vk.Image,
glyphSize: [2]u32,
name: []u8,

const Self = @This();

pub fn init(fontName: []const u8, glyphSize: [2]u32, fontImage: vk.Image) !Self {
    return Self{
        .image = fontImage,
        .glyphSize = glyphSize,
        .name = try fontImage.gfx.alloc.dupe(u8, fontName),
    };
}

pub fn initFromFile(imagePath: [:0]u8, submit: *SubmitInfo) !Self {

}

pub fn deinit(self: *Self) void {
    self.image.gfx.alloc.free(self.name);
    self.image.deinit();
}

