const std = @import("std");
const c = @import("c");
const vk = @import("vk_gfx.zig");
const r = @import("renderer/renderer.zig");
const Font = @import("renderer/fixed_font.zig");
const Scene = @import("renderer/scene.zig");

pub fn main(init: std.process.Init) !void {
    var rend : r.Renderer = undefined;
    try rend.init(init.gpa, init.io, std.debug.runtime_safety, 1024, 256);
    defer rend.deinit();

    var window = try r.Window.init(&rend, "LastGfx", 400, 300, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_VULKAN);
    defer window.deinit() catch {};

    try Font.initStatic(&rend, "shaders/font", rend.gfx.swapchainFormat);
    defer Font.deinitStatic(&rend);

    var pipeline = try rend.pipelines.getPipeline(&.{
        .name = "shaders/triangle", 
        .data = .{.graphics = .{
            .colorAttachments = @constCast(&[_]vk.Pipeline.GraphicsState.ColorAttachment{
                .{
                    .format = rend.gfx.swapchainFormat,
                }
            })
        }}
    });
    defer pipeline.clear(rend.gfx.alloc);


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

    const linearSamplerDescriptor = try rend.setDescriptor(&.{.sampler=.{}});

    const imageDescriptor = try rend.setDescriptor(&.{.image = .{.obj = &image}});

    const InputBuffer = extern struct {
        color: [4]f32,
        texIndex: u32,
        samplerIndex: u32,
    };
    const bufContent = InputBuffer {
        .color = .{ 1, 0.5, 0.0, 1 },
        .texIndex = imageDescriptor.index,
        .samplerIndex = linearSamplerDescriptor.index,
    };
    @as(*InputBuffer, @ptrCast(@alignCast(buffer.hostAddress))).* = bufContent;

    var font: Font = undefined;
    defer font.deinit(&rend) catch {};

    var scene: Scene = undefined;
    try scene.init(&rend);
    defer scene.deinit();

    {
        var upload = try r.SubmitInfo.init(&rend, 1024 * 1024);
        defer upload.deinit() catch {};

        try upload.cmds.begin();

        try font.initFromFile("data/font_rgba_10x20.png", linearSamplerDescriptor, &upload);

        try upload.uploadDescriptors(&upload.cmds);

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

        try initScene(&scene, &upload);

        try upload.cmds.end();
        try upload.cmds.submit(null);
        try upload.cmds.waitFinished();
    }

    const timeStart = std.Io.Timestamp.now(init.io, .real);
    var frames: i64 = 0;
    defer {
        const elapsed: f64 = @as(f64, @floatFromInt(timeStart.untilNow(init.io, .real).toMilliseconds())) / @as(f64, @floatFromInt(std.time.ms_per_s));
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
            try submit.reset();
            swapchainImage = try window.swapchain.acquireNextImage(&submit.submitSemaphore);
        }

        if (swapchainImage) |swapImage| {
            const submit = &commands.items[commandsIndex];
            const cmds = &submit.cmds;
            try cmds.begin();

            submit.bindDescriptorHeaps();

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

            cmds.pushData(&buffer.deviceAddress);

            cmds.bindRenderPipeline(pipeline.data().?);
            cmds.drawMeshTasks(3, 1, 1);

            try scene.render(submit);

            const pixelSize: [2]f32 = .{
                1.0 / @as(f32, @floatFromInt(swapImage.desc.width)),
                1.0 / @as(f32, @floatFromInt(swapImage.desc.height)),
            };
            try font.render("Kekekekekekekekekekekekekekekekekekekekekekekekekekekekekekekekekekz", .{50, 50}, pixelSize, .{1, 1, 0, 1}, submit);

            cmds.renderEnd();

            cmds.imageBarrier(swapImage, .{.attachmentWrite = true}, .Graphics, .{.present = true}, .Graphics);

            try cmds.end();
            try submit.submit(&submit.submitSemaphore);
            commandsIndex = (commandsIndex + 1) % @as(@TypeOf(commandsIndex), @intCast(commands.items.len));

            window.swapchain.present(swapImage, null) catch {};

            frames += 1;
        } else {
            try window.swapchain.recreate();
            if (window.swapchain.isValid()) {
                const desc = &window.swapchain.images[0].desc;
                scene.camera.aspect = @as(f32, @floatFromInt(desc.width)) / @as(f32, @floatFromInt(desc.height));
            }

            for (commands.items) |*cmd|
                try cmd.deinit();
            try commands.resize(rend.gfx.alloc, window.swapchain.images.len);
            for (commands.items) |*cmd|
                cmd.* = try r.SubmitInfo.init(&rend, 64 * 1024);

            commandsIndex = 0;
        }
    }
}

fn initScene(scene: *Scene, upload: *r.SubmitInfo) !void {
    var pipelineFlat = try scene.renderer.pipelines.getPipeline(&.{
        .name = "shaders/flat", 
        .data = .{.graphics = .{
            .colorAttachments = @constCast(&[_]vk.Pipeline.GraphicsState.ColorAttachment{
                .{
                    .format = scene.renderer.gfx.swapchainFormat,
                }
            })
        }}
    });
    defer pipelineFlat.clear(scene.alloc());

    const Material = @import("renderer/material.zig");
    var materialFlat: Material.Rc = .{};
    try materialFlat.allocate(scene.alloc(), .{});
    defer materialFlat.clear(scene.alloc());

    materialFlat.data().?.pipeline.assign(&pipelineFlat, scene.alloc());

    const cubeVerts: [8][3]f32 = .{
        .{-1, -1, -1},
        .{-1, -1,  1},
        .{-1,  1, -1},
        .{-1,  1,  1},
        .{ 1, -1, -1},
        .{ 1, -1,  1},
        .{ 1,  1, -1},
        .{ 1,  1,  1},
    };

    const cubeIndices: [6*2*3]u32 = .{
        0, 1, 2,
        2, 1, 3,
        5, 4, 6,
        5, 6, 7,
        0, 2, 4,
        4, 2, 6,
        3, 1, 5,
        3, 5, 7,
        0, 1, 4,
        4, 1, 5,
        3, 2, 6,
        3, 6, 7,
    };

    const Mesh = @import("renderer/mesh.zig");
    var meshCube: Mesh.Rc = .{};
    try meshCube.allocate(scene.alloc(), try Mesh.initData(upload, 3*@sizeOf(f32), @ptrCast(&cubeVerts), &cubeIndices));
    defer meshCube.clear(scene.alloc());

    var cubeObj: Scene.Object.Rc = .{};
    try cubeObj.allocate(scene.alloc(), .{});
    defer cubeObj.clear(scene.alloc());

    const cube = cubeObj.data().?;
    cube.material.assign(&materialFlat, scene.alloc());
    cube.mesh.assign(&meshCube, scene.alloc());

    try scene.objects.append(scene.alloc(), .{});
    scene.objects.items[scene.objects.items.len - 1].assign(&cubeObj, scene.alloc());

    scene.camera.translate(Scene.Vec3f.Simd{0, 0, 5});
}
