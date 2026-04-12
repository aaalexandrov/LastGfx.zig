const std = @import("std");
const c = @import("cimport.zig").c;
const vk = @import("vk_gfx.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        @panic("Leaked memory detected on exit!");
    };

    //try @import("zip_tree.zig").ZipTest(gpa.allocator());

    try errify(c.SDL_Init(c.SDL_INIT_VIDEO));
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("LastGfx", 400, 300, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_VULKAN);
    defer c.SDL_DestroyWindow(window);

    var gfx: vk.Gfx = undefined;
    try gfx.init(gpa.allocator(), true);
    defer gfx.deinit();

    var swapchain = try vk.Swapchain.init(&gfx, window);
    defer swapchain.deinit();

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
    //const linearSamplerDescriptorIndex: u32 = 0;

    var buffer = try vk.Buffer.init(&gfx, &.{
        .size = 1024,
        .usage = vk.Usage.ShaderRead.Or(.HostAccess),
    }, 16);
    defer buffer.deinit();

    const color: [4]f32 = .{ 1, 0.5, 0.0, 1 };
    @as(*[4]f32, @ptrCast(@alignCast(buffer.hostAddress))).* = color;

    var image = try vk.Image.init(&gfx, &.{
        .format = c.VK_FORMAT_R8G8B8A8_UNORM,
        .width = 64,
        .height = 64,
    });
    defer image.deinit();

    var linearSampler = try vk.Sampler.init(&gfx, &.{});
    defer linearSampler.deinit();

    try resourceHeap.writeResourceDescriptors(0, &[_]vk.ResourcePtr{
        .{ .image = &image },
        .{ .buffer = &buffer },
    });
    //const imageDescriptorIndex = 0 * resourceHeap.imageDescriptorsPerSlot;
    const bufferDescriptorIndex: u32 = 1 * resourceHeap.bufferDescriptorsPerSlot;

    var cmds = try vk.Commands.init(&gfx);
    defer cmds.deinit();

    {
        try cmds.begin();

        cmds.updateDescriptorHeap(&samplerHeap);
        cmds.updateDescriptorHeap(&resourceHeap);

        c.vkCmdPipelineBarrier2(cmds.handle, &c.VkDependencyInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .imageMemoryBarrierCount = 1,
            .pImageMemoryBarriers = &c.VkImageMemoryBarrier2{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
                .image = image.handle,
                .srcAccessMask = 0,
                .dstAccessMask = c.VK_ACCESS_2_TRANSFER_WRITE_BIT,
                .srcStageMask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
                .dstStageMask = c.VK_PIPELINE_STAGE_TRANSFER_BIT,
                .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                .oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
                .newLayout = c.VK_IMAGE_LAYOUT_GENERAL,
                .subresourceRange = vk.wholeImage(c.VK_IMAGE_ASPECT_COLOR_BIT),
            },
        });

        var bufStaging = try vk.Buffer.init(&gfx, &.{
                .size = @intCast(image.desc.width * image.desc.height * 4), 
                .usage = vk.Usage.TransferSrc.Or(.HostAccess)
            }, 4);
        defer bufStaging.deinit();
        var pixel: [*]u8 = bufStaging.hostAddress.?;
        for (0..@intCast(image.desc.height)) |y| {
            for (0..@intCast(image.desc.width)) |x| {
                const val: u8 = @intCast((y / 8 + x / 8) % 2 * 255);
                @memcpy(pixel[0..4], &[4]u8{val, 0, val, 1});
                pixel = pixel + 4;
            }
        }

        cmds.copyBufferToImage(&bufStaging, &image, &[_]c.VkBufferImageCopy2{
            .{
                .sType = c.VK_STRUCTURE_TYPE_BUFFER_IMAGE_COPY_2,
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
        try gfx.waitIdle();
    }

    var running = true;
    var event = std.mem.zeroes(c.SDL_Event);
    while (running) {
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => {
                    running = false;
                },
                else => {},
            }
        }

        var swapchainImage: ?vk.Swapchain.ImageWithSemaphore = null;
        if (swapchain.checkSurfaceSize())
            swapchainImage = try swapchain.acquireNextImage();

        if (swapchainImage) |swapImage| {
            try vk.check(c.vkResetFences(gfx.device.handle, 1, &cmds.fence));

            try cmds.begin();

            cmds.bindDescriptorHeap(&samplerHeap);
            cmds.bindDescriptorHeap(&resourceHeap);

            c.vkCmdPipelineBarrier2(cmds.handle, &c.VkDependencyInfo{
                .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
                .imageMemoryBarrierCount = 1,
                .pImageMemoryBarriers = &c.VkImageMemoryBarrier2{
                    .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
                    .image = swapImage.image.handle,
                    .srcAccessMask = 0,
                    .dstAccessMask = c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
                    .srcStageMask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
                    .dstStageMask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
                    .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                    .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                    .oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
                    .newLayout = c.VK_IMAGE_LAYOUT_GENERAL,
                    .subresourceRange = vk.wholeImage(c.VK_IMAGE_ASPECT_COLOR_BIT),
                },
            });

            const clearValue = c.VkClearColorValue{
                .float32 = .{ 0, 0, 1, 1 },
            };
            try cmds.renderBegin(&[_]vk.RenderTarget{.{ .image = swapImage.image, .clearValue = c.VkClearValue{ .color = clearValue } }}, null);

            const viewRect = c.VkRect2D{ .extent = swapImage.image.desc.extent2D() };
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

            c.vkCmdPipelineBarrier2(cmds.handle, &c.VkDependencyInfo{
                .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
                .imageMemoryBarrierCount = 1,
                .pImageMemoryBarriers = &c.VkImageMemoryBarrier2{
                    .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
                    .image = swapImage.image.handle,
                    .srcAccessMask = c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
                    .dstAccessMask = c.VK_ACCESS_2_TRANSFER_READ_BIT,
                    .srcStageMask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
                    .dstStageMask = c.VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
                    .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                    .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                    .oldLayout = c.VK_IMAGE_LAYOUT_GENERAL,
                    .newLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
                    .subresourceRange = vk.wholeImage(c.VK_IMAGE_ASPECT_COLOR_BIT),
                },
            });

            try cmds.end();
            try cmds.submit(swapImage.semaphore);

            swapchain.present(swapImage.image, null) catch {};

            try gfx.waitIdle();
        } else {
            try swapchain.recreate();
        }
    }
}

/// Converts the return value of an SDL function to an error union.
inline fn errify(value: anytype) error{SdlError}!switch (@typeInfo(@TypeOf(value))) {
    .bool => void,
    .pointer, .optional => @TypeOf(value.?),
    .int => |info| switch (info.signedness) {
        .signed => @TypeOf(@max(0, value)),
        .unsigned => @TypeOf(value),
    },
    else => @compileError("unerrifiable type: " ++ @typeName(@TypeOf(value))),
} {
    return switch (@typeInfo(@TypeOf(value))) {
        .bool => if (!value) error.SdlError,
        .pointer, .optional => value orelse error.SdlError,
        .int => |info| switch (info.signedness) {
            .signed => if (value >= 0) @max(0, value) else error.SdlError,
            .unsigned => if (value != 0) value else error.SdlError,
        },
        else => comptime unreachable,
    };
}
