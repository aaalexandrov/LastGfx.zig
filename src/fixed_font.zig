const std = @import("std");
const c = @import("cimport.zig").c;
const vk = @import("vk_gfx.zig");
const zstbi = @import("zstbi");
const r = @import("renderer.zig");

image: vk.Image,
name: []u8,

pub var pipeline: vk.Pipeline = undefined;

pub const Self = @This();

pub fn init(fontName: []const u8, fontImage: vk.Image) !Self {
    return Self{
        .image = fontImage,
        .name = try fontImage.gfx.alloc.dupe(u8, fontName),
    };
}

pub fn initFromFile(imagePath: [:0]const u8, submit: *r.SubmitInfo) !Self {
    const glyphSize = try glyphSizeFromPath(imagePath);
    var loaded = try zstbi.Image.loadFromFile(imagePath, 4);
    defer loaded.deinit();

    std.debug.assert(loaded.width % glyphSize[0] == 0);
    std.debug.assert(loaded.height % glyphSize[1] == 0);
 
    const staging = try submit.staging.alloc(loaded.width * loaded.height * 4, 16);
    const pixels = staging.slice();

    const cellsX = loaded.width / glyphSize[0];
    const cellsY = loaded.height / glyphSize[1];

    var image = try vk.Image.init(submit.cmds.gfx, &vk.Image.Descriptor{
        .width = @intCast(glyphSize[0]),
        .height = @intCast(glyphSize[1]),
        .depth = -@as(i32, @intCast(cellsX * cellsY)),
        .format = c.VK_FORMAT_R8G8B8A8_UNORM,
        .usage = .{.imageRead = true, .transferDst = true},
    });

    submit.cmds.imageBarrier(&image, .{}, .Graphics, .{.imageRead = true, .transferDst = true}, .Graphics);

    var dstOffs: usize = 0;
    for (0..cellsY) |cy| {
        for (0..cellsX) |cx| {
            for (0..glyphSize[1]) |row| {
                const srcOffs = ((cy * glyphSize[1] + row) * loaded.width + cx * glyphSize[0]) * 4;
                @memcpy(pixels[dstOffs..dstOffs+glyphSize[0] * 4], loaded.data[srcOffs..srcOffs + glyphSize[0] * 4]);
                dstOffs += glyphSize[0] * 4;
            }
        }
    }

    submit.cmds.copyBufferToImage(staging.buffer, &image, &[_]c.VkBufferImageCopy2{
        .{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_IMAGE_COPY_2,
            .bufferOffset = staging.offset,
            .imageSubresource = .{
                .aspectMask = image.desc.imageAspect(),
                .layerCount = @intCast(-image.desc.depth),
            },
            .imageExtent = image.desc.extent3D(),            
        },
    });

    return try init(imagePath, image);
}

pub fn deinit(self: *Self) void {
    self.image.gfx.alloc.free(self.name);
    self.image.deinit();
}

pub fn initStatic(renderer: *r.Renderer, shaderPath: []const u8) !void {
    pipeline = try renderer.loadGraphicsPipeline(shaderPath);
}

pub fn deinitStatic(renderer: *r.Renderer) void {
    pipeline.deinit(&renderer.gfx);
}

// pub fn render(str: []const u8, startPos: [2]u32, pixelSize: [2]f32, color: [4]f32, submit: *r.SubmitInfo) !void {

// }

fn glyphSizeFromPath(imagePath: [:0]const u8) ![2]u32 {
    var nameSplit = std.mem.splitScalar(u8, imagePath, '.');
    var name = nameSplit.next().?;
    for (name, 0..) |ch, i| {
        if ('0' <= ch and ch <= '9') {
            name = name[i..name.len];
            break;
        }
    }
    var part = std.mem.splitScalar(u8, name, 'x');
    const widthStr = part.next().?;
    const heightStr = part.next().?;
    const width = try std.fmt.parseInt(u32, widthStr, 10);
    const height = try std.fmt.parseInt(u32, heightStr, 10);
    return [2]u32{width, height};
}