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
    defer swapchain.deinit(&gfx);

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

        // const surf = try errify(c.SDL_GetWindowSurface(window));
        // try errify(c.SDL_FillSurfaceRect(surf, null, c.SDL_MapSurfaceRGB(surf, 0x5F, 0x5F, 0x5F)));
        //try errify(c.SDL_UpdateWindowSurface(window));
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
