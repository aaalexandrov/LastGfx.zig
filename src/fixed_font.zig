const std = @import("std");
const c = @import("c");
const vk = @import("vk_gfx.zig");
const r = @import("renderer.zig");

image: vk.Image,
imageDescriptor: vk.HeapDescriptor,
samplerDescriptor: vk.HeapDescriptor,
name: []const u8,

pub var pipeline: vk.Pipeline = undefined;

pub const Self = @This();

pub fn init(self: *Self, renderer: *r.Renderer, fontName: []const u8, fontImage: vk.Image, samplerDesc: vk.HeapDescriptor) !void {
    self.image = fontImage;
    self.imageDescriptor = try renderer.resources.setDescriptor(&.{.image = .{.obj = &self.image}});
    self.samplerDescriptor = samplerDesc;
    self.name = try self.image.gfx.alloc.dupe(u8, fontName);
}

pub fn initFromFile(self: *Self, imagePath: [:0]const u8, samplerDesc: vk.HeapDescriptor, submit: *r.SubmitInfo) !void {
    const glyphSize = try glyphSizeFromPath(imagePath);
    var loaded = try r.STBImage.load(imagePath, 4);
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

    return try init(self, submit.renderer, imagePath, image, samplerDesc);
}

pub fn deinit(self: *Self, renderer: *r.Renderer) !void {
    self.image.gfx.alloc.free(self.name);
    try renderer.resources.freeDescriptor(self.imageDescriptor);
    self.image.deinit();
}

pub fn initStatic(renderer: *r.Renderer, shaderPath: []const u8, attachmentFormat: c.VkFormat) !void {
    pipeline = try renderer.loadGraphicsPipeline(shaderPath, &vk.Pipeline.GraphicsState{
        .colorAttachments = @constCast(&[_]vk.Pipeline.GraphicsState.ColorAttachment{
            .{
                .format = attachmentFormat,
                .blend = .srcAlpha,
            },
        }),
    });
}

pub fn deinitStatic(renderer: *r.Renderer) void {
    pipeline.deinit(&renderer.gfx);
}

fn getCharLayer(self: *Self, ch: u8) u32 {
    const lastChar: u32 = @intCast(-self.image.desc.depth - 1);
    if (ch < ' ')
        return lastChar;
    return @min(ch - ' ', lastChar);
}

pub fn render(self: *Self, str: []const u8, startPos: [2]f32, pixelSize: [2]f32, color: [4]f32, submit: *r.SubmitInfo) !void {

    const BufferData = extern struct {
        inColor: [4]f32,
        texIndex: u32,
        samplerIndex: u32,
        quadSize: [2]f32,
        numCharacters: u32,
    };

    const CharData = extern struct {
        coordinates: [2]f32,
        layer: u32,
    };

    const quadSize: [2]f32 = .{
        @as(f32, @floatFromInt(self.image.desc.width)) * pixelSize[0],
        @as(f32, @floatFromInt(self.image.desc.height)) * pixelSize[1],
    };

    const buffer = try submit.staging.alloc(@sizeOf(BufferData) + @sizeOf(CharData) * str.len, 16);
    const bufferData: [*]BufferData = @ptrCast(@alignCast(buffer.buffer.hostAddress.?));
    bufferData[0].inColor = color;
    bufferData[0].texIndex = self.imageDescriptor.index;
    bufferData[0].samplerIndex = self.samplerDescriptor.index;
    bufferData[0].quadSize = quadSize;
    bufferData[0].numCharacters = @intCast(str.len);

    const characters: [*]CharData = @ptrCast(&bufferData[1]);

    var pos: [2]f32 = .{
        startPos[0] * pixelSize[0],
        startPos[1] * pixelSize[1],
    };
    for (str, 0..) |ch, i| {
        characters[i] = .{
            .coordinates = pos,
            .layer = self.getCharLayer(ch),
        };
        pos[0] += quadSize[0];
    }
    
    submit.cmds.bindRenderPipeline(&Self.pipeline);

    submit.cmds.pushData(&buffer.deviceAddress());
    submit.cmds.drawMeshTasks(@intCast((str.len + 31) / 32), 1, 1);
}

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
