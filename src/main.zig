const std = @import("std");
const c = @import("c");
const vk = @import("vk_gfx.zig");
const r = @import("renderer/renderer.zig");
const Font = @import("renderer/fixed_font.zig");
const Scene = @import("renderer/scene.zig");

pub fn main(init: std.process.Init) !void {
    var rend: r.Renderer = undefined;
    try rend.init(init.gpa, init.io, std.debug.runtime_safety, 1024, 256);
    defer rend.deinit() catch {};

    var window = try r.Window.init(&rend, "LastGfx", 400, 300, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_VULKAN);
    defer window.deinit() catch {};

    var depthBuffer: vk.Image = .{
        .gfx = &rend.gfx,
    };
    defer if (depthBuffer.handle != null)
        depthBuffer.deinit();
    var depthBufferNeedsTransition = false;

    try Font.initStatic(&rend, "shaders/font", rend.gfx.swapchainFormat);
    defer Font.deinitStatic(&rend);

    var image = try vk.Image.init(&rend.gfx, &.{
        .format = c.VK_FORMAT_R8G8B8A8_UNORM,
        .width = 64,
        .height = 64,
    });
    defer image.deinit();

    const linearSamplerDescriptor = try rend.getSampler(&.{});

    const imageDescriptor = try rend.setDescriptor(&.{ .image = .{ .obj = &image } });

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

        upload.cmds.imageBarrier(&image, .{}, .Graphics, .{ .transferDst = true }, .Graphics);

        const pixelsUpload = try upload.staging.alloc(@intCast(image.desc.width * image.desc.height * 4), 1);
        var pixel: [*]u8 = pixelsUpload.buffer.hostAddress.? + pixelsUpload.offset;
        for (0..@intCast(image.desc.height)) |y| {
            for (0..@intCast(image.desc.width)) |x| {
                const val: u8 = @intCast((y / 8 + x / 8) % 2 * 255);
                @memcpy(pixel[0..4], &[4]u8{ val, val, val, 1 });
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

        try initScene(&scene, &upload, imageDescriptor, linearSamplerDescriptor);

        try upload.cmds.end();
        try upload.cmds.submit(null);
        try upload.cmds.waitFinished();
    }

    var commands = try std.ArrayList(r.SubmitInfo).initCapacity(rend.gfx.alloc, 8);
    var commandsIndex: u8 = 0;
    defer {
        for (commands.items) |*cmds|
            cmds.deinit() catch {};
        commands.deinit(rend.gfx.alloc);
    }

    const transDelta: f32 = 10;
    const rotDelta: f32 = std.math.degreesToRadians(90);

    const timeStart = std.Io.Timestamp.now(init.io, .real);
    var timePrev = timeStart;
    var frames: i64 = 0;
    defer {
        const elapsed: f64 = durationToSeconds(f64, timeStart.untilNow(init.io, .real));
        std.log.info("Frames: {}, seconds: {d:1.3}, average FPS: {d:1.3}", .{ frames, elapsed, @as(f64, @floatFromInt(frames)) / elapsed });
    }
    var printBuf: [1024]u8 = undefined;

    var running = true;
    var event = std.mem.zeroes(c.SDL_Event);
    while (running) {
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_KEY_DOWN => switch (event.key.key) {
                    c.SDLK_V => {
                        window.swapchain.setPresentModeIndex((window.swapchain.presentModeIndex + 1) % @as(u8, @intCast(window.swapchain.presentModes.len)));
                        std.log.info("Present mode {} of {}", .{ window.swapchain.presentModeIndex + 1, window.swapchain.presentModes.len });
                    },
                    c.SDLK_I => {
                        window.swapchain.setNumImages(window.swapchain.numImages % window.swapchain.maxNumImages + 1);
                        std.log.info("Attempting to set number of swapchain images to {} of {} max", .{ window.swapchain.numImages, window.swapchain.maxNumImages });
                    },
                    else => {},
                },
                else => {},
            }
        }

        const timeNow = std.Io.Timestamp.now(init.io, .real);
        const timeDelta = durationToSeconds(f32, timePrev.durationTo(timeNow));
        timePrev = timeNow;

        var swapchainImage: ?*vk.Image = null;
        if (window.swapchain.isValid()) {
            const submit = &commands.items[commandsIndex];
            try submit.cmds.waitFinished();
            try submit.reset();
            swapchainImage = try window.swapchain.acquireNextImage(&submit.submitSemaphore);
        }

        if (swapchainImage) |swapImage| {
            pollCameraInput(&scene.camera, transDelta * timeDelta, rotDelta * timeDelta);

            const submit = &commands.items[commandsIndex];
            const cmds = &submit.cmds;
            try cmds.begin();

            submit.bindDescriptorHeaps();

            cmds.imageBarrier(swapImage, .{}, .Graphics, .{ .attachmentWrite = true }, .Graphics);

            if (depthBufferNeedsTransition) {
                cmds.imageBarrier(&depthBuffer, .{}, .Graphics, .{ .attachmentWrite = true }, .Graphics);
                depthBufferNeedsTransition = false;
            }

            const clearValue = c.VkClearColorValue{
                .float32 = .{ 0, 0, 1, 1 },
            };
            try cmds.renderBegin(&[_]vk.RenderTarget{.{ .image = swapImage, .clearValue = c.VkClearValue{ .color = clearValue } }}, .{ .image = &depthBuffer, .clearValue = .{ .depthStencil = .{ .depth = 1e100 } } });

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

            try scene.render(submit);

            const fpsStr = try std.fmt.bufPrint(&printBuf, "fps:{d:1.2}", .{1.0 / timeDelta});
            const pixelSize: [2]f32 = .{
                1.0 / @as(f32, @floatFromInt(swapImage.desc.width)),
                1.0 / @as(f32, @floatFromInt(swapImage.desc.height)),
            };
            try font.render(fpsStr, .{ 20, 20 }, pixelSize, .{ 1, 1, 0, 1 }, submit);

            cmds.renderEnd();

            cmds.imageBarrier(swapImage, .{ .attachmentWrite = true }, .Graphics, .{ .present = true }, .Graphics);

            try cmds.end();
            try submit.submit(&submit.submitSemaphore);
            commandsIndex = (commandsIndex + 1) % @as(@TypeOf(commandsIndex), @intCast(commands.items.len));

            window.swapchain.present(swapImage, null) catch {};

            frames += 1;
        } else {
            try window.swapchain.recreate();
            if (depthBuffer.handle != null) {
                depthBuffer.deinit();
                depthBuffer.handle = null;
            }
            if (window.swapchain.isValid()) {
                const desc = &window.swapchain.images[0].desc;
                scene.camera.aspect = @as(f32, @floatFromInt(desc.width)) / @as(f32, @floatFromInt(desc.height));
                depthBuffer = try vk.Image.init(&rend.gfx, &.{
                    .width = desc.width,
                    .height = desc.height,
                    .format = c.VK_FORMAT_D32_SFLOAT,
                    .usage = .{
                        .attachmentRead = true,
                        .attachmentWrite = true,
                    },
                });
                depthBufferNeedsTransition = true;
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

fn initScene(scene: *Scene, upload: *r.SubmitInfo, albedo: vk.HeapDescriptor, sampler: vk.HeapDescriptor) !void {
    var pipelineFlat = try scene.renderer.pipelines.getPipeline(&.{ 
        .name = "shaders/flat", 
        .data = .{ 
            .graphics = .{ 
                .cullMode = c.VK_CULL_MODE_BACK_BIT, 
                .depthWrite = true, 
                .depthCompareOp = c.VK_COMPARE_OP_LESS, 
                .depthAttachmentFormat = c.VK_FORMAT_D32_SFLOAT, 
                .colorAttachments = @constCast(&[_]vk.Pipeline.GraphicsState.ColorAttachment{.{
                    .format = scene.renderer.gfx.swapchainFormat,
                }})
            } 
        } 
    });
    defer pipelineFlat.clear(scene.alloc());

    const Material = @import("renderer/material.zig");
    var materialFlat: Material.Rc = .{};
    try materialFlat.allocate(scene.alloc(), .{});
    defer materialFlat.clear(scene.alloc());

    try materialFlat.data().?.setPipeline(&pipelineFlat, scene.alloc());

    var materialProps = materialFlat.data().?.getProperties().?;
    materialProps.getMember("color").?.getT([3]f32).?.* = .{1, 1, 1};
    materialProps.getMember("roughness").?.getT(f32).?.* = 0.5;
    materialProps.getMember("metallic").?.getT(f32).?.* = 0.1;
    materialProps.getMember("albedo").?.getMember("index").?.getT(u32).?.* = albedo.index;
    materialProps.getMember("textureSampler").?.getMember("index").?.getT(u32).?.* = sampler.index;

    const cubeVerts: [8][3]f32 = .{
        .{ -1, -1, -1 },
        .{ -1, -1, 1 },
        .{ -1, 1, -1 },
        .{ -1, 1, 1 },
        .{ 1, -1, -1 },
        .{ 1, -1, 1 },
        .{ 1, 1, -1 },
        .{ 1, 1, 1 },
    };

    const cubeIndices: [6 * 2 * 3]u32 = .{
        0, 1, 2,
        2, 1, 3,
        5, 4, 6,
        5, 6, 7,
        0, 2, 4,
        4, 2, 6,
        3, 1, 5,
        3, 5, 7,
        1, 0, 4,
        1, 4, 5,
        2, 3, 6,
        6, 3, 7,
    };

    const Mesh = @import("renderer/mesh.zig");
    var meshCube: Mesh.Rc = .{};
    try meshCube.allocate(scene.alloc(), try Mesh.initData(upload, 3 * @sizeOf(f32), @ptrCast(&cubeVerts), &cubeIndices));
    defer meshCube.clear(scene.alloc());

    var cubeObj: Scene.Object.Rc = .{};
    try cubeObj.allocate(scene.alloc(), .{});
    defer cubeObj.clear(scene.alloc());

    const cube = cubeObj.data().?;
    cube.material.assign(&materialFlat, scene.alloc());
    cube.mesh.assign(&meshCube, scene.alloc());

    try scene.objects.append(scene.alloc(), .{});
    scene.objects.items[scene.objects.items.len - 1].assign(&cubeObj, scene.alloc());

    scene.camera.translate(Scene.Vec3f.Simd{ 0, 0, 5 });
}

fn durationToSeconds(comptime T: type, duration: std.Io.Duration) T {
    return @as(T, @floatFromInt(duration.toNanoseconds())) / @as(T, @floatFromInt(std.time.ns_per_s));
}

fn pollCameraInput(camera: *Scene.Camera, transDelta: f32, rotDelta: f32) void {
    const keyState = c.SDL_GetKeyboardState(null);

    var trans = Scene.Vec3f.splat(0);
    if (keyState[c.SDL_SCANCODE_A])
        trans[0] -= transDelta;
    if (keyState[c.SDL_SCANCODE_D])
        trans[0] += transDelta;
    if (keyState[c.SDL_SCANCODE_R])
        trans[1] -= transDelta;
    if (keyState[c.SDL_SCANCODE_F])
        trans[1] += transDelta;
    if (keyState[c.SDL_SCANCODE_W])
        trans[2] -= transDelta;
    if (keyState[c.SDL_SCANCODE_S])
        trans[2] += transDelta;
    camera.translate(trans);

    var rot = Scene.Vec3f.splat(0);
    if (keyState[c.SDL_SCANCODE_G])
        rot[0] -= rotDelta;
    if (keyState[c.SDL_SCANCODE_T])
        rot[0] += rotDelta;
    if (keyState[c.SDL_SCANCODE_E])
        rot[1] -= rotDelta;
    if (keyState[c.SDL_SCANCODE_Q])
        rot[1] += rotDelta;
    if (keyState[c.SDL_SCANCODE_Z])
        rot[2] -= rotDelta;
    if (keyState[c.SDL_SCANCODE_C])
        rot[2] += rotDelta;
    camera.rotate(rot);
}
