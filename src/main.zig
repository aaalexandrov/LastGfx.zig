const std = @import("std");
const c = @import("cimport.zig").c;
const vk = @import("vk_gfx.zig");
const r = @import("renderer.zig");
const Font = @import("fixed_font.zig");
const Range = @import("range_allocator.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        @panic("Leaked memory detected on exit!");
    };

    try Range.RangeAllocTest(gpa.allocator());

    const activateDebugLayers = @import("builtin").mode == .Debug or @import("builtin").mode == .ReleaseSafe;
    var rend : r.Renderer = undefined;
    try rend.init(gpa.allocator(), activateDebugLayers, 1024, 256);
    defer rend.deinit();

    var window = try r.Window.init(&rend, "LastGfx", 400, 300, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_VULKAN);
    defer window.deinit() catch {};

    try Font.initStatic(&rend, "shaders/font");
    defer Font.deinitStatic(&rend);

    var pipeline = try rend.loadGraphicsPipeline("shaders/triangle");
    defer pipeline.deinit(&rend.gfx);


    var buffer = try vk.Buffer.init(&rend.gfx, &.{
        .size = 1024,
        .usage = vk.Usage{.storageRead = true, .hostWrite = true},
    });
    defer buffer.deinit();

    var image = try vk.Image.init(&rend.gfx, &.{
        .format = c.VK_FORMAT_R8G8B8A8_UNORM,
        .width = 64,
        .height = 64,
    });
    defer image.deinit();

    const linearSamplerDescriptorIndex: u32 = 0;

    const imageDescriptorIndex = 0 * rend.resourceHeap.imageDescriptorsPerSlot;
    //const fontImageDescriptorIndex = 1 * resourceHeap.imageDescriptorsPerSlot;
    const bufferDescriptorIndex: u32 = 2 * rend.resourceHeap.bufferDescriptorsPerSlot;

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

    var font: Font = undefined;
    defer font.deinit();

    {
        var upload = try r.SubmitInfo.init(&rend, 1024 * 1024);
        defer upload.deinit() catch {};

        try upload.cmds.begin();

        font = try Font.initFromFile("data/font_rgba_10x20.png", &upload);

        try rend.samplerHeap.writeSamplerDescriptors(linearSamplerDescriptorIndex, &[_]c.VkSamplerCreateInfo{vk.Sampler.createInfo(&.{})});
        const samplerUpload = try upload.staging.alloc(rend.samplerHeap.updateSrcSlots.items.len, 1);
        try upload.cmds.updateDescriptorHeap(&rend.samplerHeap, samplerUpload.buffer, samplerUpload.offset);

        try rend.resourceHeap.writeResourceDescriptors(imageDescriptorIndex, &[_]vk.ResourcePtr{
            .{ .image = &image },
            .{ .image = &font.image },
            .{ .buffer = &buffer },
        });
        const resourcesUpload = try upload.staging.alloc(rend.resourceHeap.updateSrcSlots.items.len, 1);
        try upload.cmds.updateDescriptorHeap(&rend.resourceHeap, resourcesUpload.buffer, resourcesUpload.offset);

        upload.cmds.imageBarrier(&image, .{}, .Graphics, .{.transferDst = true}, .Graphics);

        const pixelsUpload = try upload.staging.alloc(@intCast(image.desc.width * image.desc.height * 4), 1);
        var pixel: [*]u8 = pixelsUpload.buffer.hostAddress.? + pixelsUpload.offset;
        for (0..@intCast(image.desc.height)) |y| {
            for (0..@intCast(image.desc.width)) |x| {
                const val: u8 = @intCast((y / 8 + x / 8) % 2 * 255);
                @memcpy(pixel[0..4], &[4]u8{val, 0, val, 1});
                pixel = pixel + 4;
            }
        }

        upload.cmds.copyBufferToImage(pixelsUpload.buffer, &image, &[_]c.VkBufferImageCopy2{
            .{
                .sType = c.VK_STRUCTURE_TYPE_BUFFER_IMAGE_COPY_2,
                .bufferOffset = pixelsUpload.offset,
                .imageSubresource = .{
                    .aspectMask = image.desc.imageAspect(),
                    .layerCount = 1,
                },
                .imageExtent = image.desc.extent3D(),
            },
        });

        try upload.cmds.end();
        try upload.cmds.submit(null);
        try upload.cmds.waitFinished();
    }

    const timeStartMS = std.time.milliTimestamp();
    var frames: i64 = 0;
    defer {
        const elapsed: f64 = @as(f64, @floatFromInt(std.time.milliTimestamp() - timeStartMS)) / @as(f64, @floatFromInt(std.time.ms_per_s));
        std.log.info("Frames: {}, seconds: {d:1.3}, average FPS: {d:1.3}", .{frames, elapsed, @as(f64, @floatFromInt(frames)) / elapsed});
    }

    var commands = try std.ArrayList(r.SubmitInfo).initCapacity(rend.gfx.alloc, 8);
    var commandsIndex: u8 = 0;
    defer {
        for (commands.items) |*cmds| 
            cmds.deinit() catch {};
        commands.deinit(rend.gfx.alloc);
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
                            window.swapchain.setPresentModeIndex((window.swapchain.presentModeIndex + 1) % @as(u8, @intCast(window.swapchain.presentModes.len)));
                            std.log.info("Present mode {} of {}", .{window.swapchain.presentModeIndex + 1, window.swapchain.presentModes.len});
                        },
                        c.SDLK_I => {
                            window.swapchain.setNumImages(window.swapchain.numImages % window.swapchain.maxNumImages + 1);
                            std.log.info("Attempting to set number of swapchain images to {} of {} max", .{window.swapchain.numImages, window.swapchain.maxNumImages});
                        },
                        else => {},
                    },
                else => {},
            }
        }

        var swapchainImage: ?*vk.Image = null;
        if (window.swapchain.isValid()) {
            const submit = &commands.items[commandsIndex];
            try submit.cmds.waitFinished();
            submit.staging.reset();
            swapchainImage = try window.swapchain.acquireNextImage(&submit.submitSemaphore);
        }

        if (swapchainImage) |swapImage| {
            const submit = &commands.items[commandsIndex];
            const cmds = &submit.cmds;
            try cmds.begin();

            cmds.bindDescriptorHeap(&rend.samplerHeap);
            cmds.bindDescriptorHeap(&rend.resourceHeap);

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
            try cmds.submit(&submit.submitSemaphore);
            commandsIndex = (commandsIndex + 1) % @as(@TypeOf(commandsIndex), @intCast(commands.items.len));

            window.swapchain.present(swapImage, null) catch {};

            frames += 1;
        } else {
            try window.swapchain.recreate();

            for (commands.items) |*cmd|
                try cmd.deinit();
            try commands.resize(rend.gfx.alloc, window.swapchain.images.len);
            for (commands.items) |*cmd|
                cmd.* = try r.SubmitInfo.init(&rend, 64 * 1024);

            commandsIndex = 0;
        }
    }
}

