const std = @import("std");
const c = @import("cimport.zig").c;
const vk = @import("vk_gfx.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        @panic("Leaked memory detected on exit!");
    };

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

    var cmds = try vk.Commands.init(&gfx);
    defer cmds.deinit();

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

        const swapImage = try swapchain.acquireNextImage();

        try vk.check(c.vkResetFences(gfx.device.handle, 1, &cmds.fence));

        try cmds.begin();

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
        try cmds.renderBegin(&[_]vk.RenderTarget{.{.image = swapImage.image, .clearValue = c.VkClearValue{.color = clearValue}}}, null);

        const viewRect = c.VkRect2D{.extent = swapImage.image.desc.extent2D()};
        cmds.setViewport(&c.VkViewport{
            .x = @floatFromInt(viewRect.offset.x),
            .y = @floatFromInt(viewRect.offset.y),
            .width = @floatFromInt(viewRect.extent.width),
            .height = @floatFromInt(viewRect.extent.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        });
        cmds.setScissor(&viewRect);

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

        try swapchain.present(swapImage.image, null);

        try gfx.waitIdle();
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
