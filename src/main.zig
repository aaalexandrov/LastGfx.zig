const std = @import("std");
const c = @import("cimport.zig").c;
const vk = @import("vk_gfx.zig");
const rc = @import("rc_ptr.zig");
const zstbi = @import("zstbi");

const CommandsDeinit = struct {
    fn deinit(cmds: *vk.Commands, _: std.mem.Allocator) void {
        cmds.deinit();
    }
};
const CommandsPtr = rc.SharedPtr(vk.Commands, CommandsDeinit.deinit);

const UploadBuffer = struct {
    buffer: vk.Buffer,
    offset: u64 = 0,

    pub const Alloc = struct {
        buffer: *vk.Buffer, 
        offset: u64,
        size: u64,

        pub fn slice(self: @This()) []u8 {
            return self.buffer.hostAddress.?[self.offset..self.offset + self.size];
        }
    };
    pub const Self = @This();

    pub fn init(gfx: *vk.Gfx, size: u64) !Self {
        return Self {
            .buffer = try vk.Buffer.init(gfx, &.{
                .size = size,
                .usage = .{.hostWrite = true, .transferSrc = true},
            }, 16),
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
    }

    pub fn alloc(self: *Self, size: u64) !Alloc {
        if (self.offset + size > self.buffer.desc.size)
            return error.BufferNotBigEnough;
        const start = self.offset;
        self.offset += size;
        return .{
            .buffer = &self.buffer, 
            .offset = start,
            .size = size,
        };
    }

    pub fn reset(self: *Self) void {
        self.offset = 0;
    }
};

const SubmitInfo = struct {
    cmds: vk.Commands,
    swapImageSemaphore: vk.Semaphore,

    const Self = @This();
    fn init(gfx: *vk.Gfx) !Self {
        return Self{
            .cmds = try vk.Commands.init(gfx),
            .swapImageSemaphore = try vk.Semaphore.init(gfx, null),
        };
    }
    fn deinit(self: *Self) !void {
        try self.cmds.waitFinished();
        self.cmds.deinit();
        self.swapImageSemaphore.deinit();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        @panic("Leaked memory detected on exit!");
    };

    try vk.sdl_errify(c.SDL_Init(c.SDL_INIT_VIDEO));
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("LastGfx", 400, 300, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_VULKAN);
    defer c.SDL_DestroyWindow(window);

    const activateDebugLayers = @import("builtin").mode == .Debug or @import("builtin").mode == .ReleaseSafe;
    var gfx: vk.Gfx = undefined;
    try gfx.init(gpa.allocator(), activateDebugLayers);
    defer gfx.deinit();

    zstbi.init(gfx.alloc);
    defer zstbi.deinit();

    var swapchain = try vk.Swapchain.init(&gfx, window);
    defer swapchain.deinit() catch {};

    var shaderMesh = try vk.Shader.init(&gfx, "shaders/triangle.mesh.spv");
    defer shaderMesh.deinit(&gfx);

    var shaderFrag = try vk.Shader.init(&gfx, "shaders/triangle.frag.spv");
    defer shaderFrag.deinit(&gfx);

    var pipeline = try vk.Pipeline.initGraphics(&gfx, &shaderMesh, &shaderFrag, "triangle");
    defer pipeline.deinit(&gfx);

    var resourceHeap = try vk.DescriptorHeap.init(&gfx, .Resource, 16);
    defer resourceHeap.deinit();

    var samplerHeap = try vk.DescriptorHeap.init(&gfx, .Sampler, 16);
    defer samplerHeap.deinit();

    try samplerHeap.writeSamplerDescriptors(0, &[_]c.VkSamplerCreateInfo{vk.Sampler.createInfo(&.{})});
    const linearSamplerDescriptorIndex: u32 = 0;

    var buffer = try vk.Buffer.init(&gfx, &.{
        .size = 1024,
        .usage = vk.Usage{.storageRead = true, .hostWrite = true},
    }, 16);
    defer buffer.deinit();

    var image = try vk.Image.init(&gfx, &.{
        .format = c.VK_FORMAT_R8G8B8A8_UNORM,
        .width = 64,
        .height = 64,
    });
    defer image.deinit();

    try resourceHeap.writeResourceDescriptors(0, &[_]vk.ResourcePtr{
        .{ .image = &image },
        .{ .buffer = &buffer },
    });
    const imageDescriptorIndex = 0 * resourceHeap.imageDescriptorsPerSlot;
    const bufferDescriptorIndex: u32 = 1 * resourceHeap.bufferDescriptorsPerSlot;

    const InputBuffer = extern struct {
        color: [4]f32,
        texIndex: u32,
        samplerIndex: u32,
    };
    const bufContent = InputBuffer {
        .color = .{ 1, 0.5, 0.0, 1 },
        .texIndex = imageDescriptorIndex,
        .samplerIndex = linearSamplerDescriptorIndex,
    };
    @as(*InputBuffer, @ptrCast(@alignCast(buffer.hostAddress))).* = bufContent;

    {
        var staging = try UploadBuffer.init(&gfx, 1024*1024);
        defer staging.deinit();

        var cmds = try vk.Commands.init(&gfx);
        defer cmds.deinit();

        try cmds.begin();

        const samplerUpload = try staging.alloc(samplerHeap.updateSrcSlots.items.len);
        try cmds.updateDescriptorHeap(&samplerHeap, samplerUpload.buffer, samplerUpload.offset);

        const resourcesUpload = try staging.alloc(resourceHeap.updateSrcSlots.items.len);
        try cmds.updateDescriptorHeap(&resourceHeap, resourcesUpload.buffer, resourcesUpload.offset);

        cmds.imageBarrier(&image, .{}, .Graphics, .{.transferDst = true}, .Graphics);

        const pixelsUpload = try staging.alloc(@intCast(image.desc.width * image.desc.height * 4));
        var pixel: [*]u8 = staging.buffer.hostAddress.? + pixelsUpload.offset;
        for (0..@intCast(image.desc.height)) |y| {
            for (0..@intCast(image.desc.width)) |x| {
                const val: u8 = @intCast((y / 8 + x / 8) % 2 * 255);
                @memcpy(pixel[0..4], &[4]u8{val, 0, val, 1});
                pixel = pixel + 4;
            }
        }

        cmds.copyBufferToImage(pixelsUpload.buffer, &image, &[_]c.VkBufferImageCopy2{
            .{
                .sType = c.VK_STRUCTURE_TYPE_BUFFER_IMAGE_COPY_2,
                .bufferOffset = pixelsUpload.offset,
                .imageSubresource = .{
                    .aspectMask = image.desc.imageAspect(),
                    .mipLevel = 0,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
                .imageExtent = image.desc.extent3D(),
            },
        });

        try cmds.end();
        try cmds.submit(null);
        try cmds.waitFinished();
    }

    const timeStartMS = std.time.milliTimestamp();
    var frames: i64 = 0;
    defer {
        const elapsed: f64 = @as(f64, @floatFromInt(std.time.milliTimestamp() - timeStartMS)) / @as(f64, @floatFromInt(std.time.ms_per_s));
        std.log.info("Frames: {}, seconds: {d:1.3}, average FPS: {d:1.3}", .{frames, elapsed, @as(f64, @floatFromInt(frames)) / elapsed});
    }

    var commands = try std.ArrayList(SubmitInfo).initCapacity(gfx.alloc, 8);
    var commandsIndex: u8 = 0;
    defer {
        for (commands.items) |*cmds| 
            cmds.deinit() catch {};
        commands.deinit(gfx.alloc);
    }

    var running = true;
    var event = std.mem.zeroes(c.SDL_Event);
    while (running) {
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_KEY_DOWN => 
                    switch (event.key.key) {
                        c.SDLK_V => {
                            swapchain.setPresentModeIndex((swapchain.presentModeIndex + 1) % @as(u8, @intCast(swapchain.presentModes.len)));
                            std.log.info("Present mode {} of {}", .{swapchain.presentModeIndex + 1, swapchain.presentModes.len});
                        },
                        c.SDLK_I => {
                            swapchain.setNumImages(swapchain.numImages % swapchain.maxNumImages + 1);
                            std.log.info("Attempting to set number of swapchain images to {} of {} max", .{swapchain.numImages, swapchain.maxNumImages});
                        },
                        else => {},
                    },
                else => {},
            }
        }

        var swapchainImage: ?*vk.Image = null;
        if (swapchain.isValid()) {
            const submit = &commands.items[commandsIndex];
            try submit.cmds.waitFinished();
            swapchainImage = try swapchain.acquireNextImage(&submit.swapImageSemaphore);
        }

        if (swapchainImage) |swapImage| {
            const submit = &commands.items[commandsIndex];
            const cmds = &submit.cmds;
            try cmds.begin();

            cmds.bindDescriptorHeap(&samplerHeap);
            cmds.bindDescriptorHeap(&resourceHeap);

            cmds.imageBarrier(swapImage, .{}, .Graphics, .{.attachmentWrite = true}, .Graphics);

            const clearValue = c.VkClearColorValue{
                .float32 = .{ 0, 0, 1, 1 },
            };
            try cmds.renderBegin(&[_]vk.RenderTarget{.{ .image = swapImage, .clearValue = c.VkClearValue{ .color = clearValue } }}, null);

            const viewRect = c.VkRect2D{ .extent = swapImage.desc.extent2D() };
            cmds.setViewport(&c.VkViewport{
                .x = @floatFromInt(viewRect.offset.x),
                .y = @floatFromInt(viewRect.offset.y),
                .width = @floatFromInt(viewRect.extent.width),
                .height = @floatFromInt(viewRect.extent.height),
                .minDepth = 0.0,
                .maxDepth = 1.0,
            });
            cmds.setScissor(&viewRect);

            cmds.pushData(&bufferDescriptorIndex);

            cmds.bindRenderPipeline(&pipeline);
            cmds.drawMeshTasks(3, 1, 1);

            cmds.renderEnd();

            cmds.imageBarrier(swapImage, .{.attachmentWrite = true}, .Graphics, .{.present = true}, .Graphics);

            try cmds.end();
            try cmds.submit(&submit.swapImageSemaphore);
            commandsIndex = (commandsIndex + 1) % @as(@TypeOf(commandsIndex), @intCast(commands.items.len));

            swapchain.present(swapImage, null) catch {};

            frames += 1;
        } else {
            try swapchain.recreate();

            for (commands.items) |*cmd|
                try cmd.deinit();
            try commands.resize(gfx.alloc, swapchain.images.len);
            for (commands.items) |*cmd|
                cmd.* = try SubmitInfo.init(&gfx);

            commandsIndex = 0;
        }
    }
}

fn LoadTexture(gfx: *vk.Gfx, filename: [:0]u8, usage: vk.Usage, cmds: *vk.Commands, staging: *UploadBuffer) !vk.Image {
    var loaded = try zstbi.Image.loadFromFile(filename, 4);
    defer loaded.deinit();

    const image = try vk.Image.init(gfx, .{
        .format = c.VK_FORMAT_R8G8B8A8_UNORM,
        .width = loaded.width,
        .height = loaded.height,
        .usage = usage,
    });

    const pixels = try staging.alloc(loaded.width * loaded.height * 4);
    @memcpy(pixels.slice(), loaded.data[0 .. pixels.size]);

    cmds.copyBufferToImage(pixels.buffer, &image, &[_]c.VkBufferImageCopy2{
        .{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_IMAGE_COPY_2,
            .bufferOffset = pixels.offset,
            .imageSubresource = .{
                .aspectMask = image.desc.imageAspect(),
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageExtent = image.desc.extent3D(),
        },
    });

    return image;
}