const std = @import("std");
const c = @import("cimport.zig").c;
const vk = @import("vk_gfx.zig");
const zstbi = @import("zstbi");

pub const UploadBuffer = struct {
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

pub const SubmitInfo = struct {
    cmds: vk.Commands,
    submitSemaphore: vk.Semaphore,
    staging: UploadBuffer,

    const Self = @This();
    pub fn init(gfx: *vk.Gfx, stagingSize: u64) !Self {
        return Self{
            .cmds = try vk.Commands.init(gfx),
            .submitSemaphore = try vk.Semaphore.init(gfx, null),
            .staging = try UploadBuffer.init(gfx, stagingSize),
        };
    }
    pub fn deinit(self: *Self) !void {
        try self.cmds.waitFinished();
        self.cmds.deinit();
        self.submitSemaphore.deinit();
        self.staging.deinit();
    }

    pub fn loadTexture(self: *Self, filename: [:0]const u8, usage: vk.Usage) !vk.Image {
        std.debug.assert(usage.transferDst);

        var loaded = try zstbi.Image.loadFromFile(filename, 4);
        defer loaded.deinit();

        const image = try vk.Image.init(self.cmds.gfx, &.{
            .format = c.VK_FORMAT_R8G8B8A8_UNORM,
            .width = @intCast(loaded.width),
            .height = @intCast(loaded.height),
            .usage = usage,
        });

        const pixels = try self.staging.alloc(loaded.width * loaded.height * 4);
        @memcpy(pixels.slice(), loaded.data[0 .. pixels.size]);

        self.cmds.imageBarrier(&image, .{}, .Graphics, .{.transferDst = true}, .Graphics);
        
        self.cmds.copyBufferToImage(pixels.buffer, &image, &[_]c.VkBufferImageCopy2{
            .{
                .sType = c.VK_STRUCTURE_TYPE_BUFFER_IMAGE_COPY_2,
                .bufferOffset = pixels.offset,
                .imageSubresource = .{
                    .aspectMask = image.desc.imageAspect(),
                    .layerCount = 1,
                },
                .imageExtent = image.desc.extent3D(),
            },
        });

        return image;
    }    
};

pub const Window = struct {
    window: ?*c.SDL_Window,
    swapchain: vk.Swapchain,

    pub const Self = @This();

    pub fn init(renderer: *Renderer, title: [:0]const u8, width: i32, height: i32, flags: c.SDL_WindowFlags) !Self {
        var self: Self = undefined;
        self.window = c.SDL_CreateWindow(title, width, height, flags);
        self.swapchain = try vk.Swapchain.init(&renderer.gfx, self.window);
        return self;
    }

    pub fn deinit(self: *Self) !void {
        try self.swapchain.deinit();
        c.SDL_DestroyWindow(self.window);
    }
};

pub const Renderer = struct {
    gfx: vk.Gfx,
    resourceHeap: vk.DescriptorHeap,
    samplerHeap: vk.DescriptorHeap,

    pub const Self = @This();

    pub fn init(self: *Self, alloc: std.mem.Allocator, debug: bool, numResourceDescriptors: ?u64, numSamplerDescriptors: ?u64) !void {
        try vk.sdl_errify(c.SDL_Init(c.SDL_INIT_VIDEO));
        if (!c.SDL_Vulkan_LoadLibrary(null))
            return error.SDLCouldNotLoadVulkan;

        zstbi.init(alloc);

        self.gfx = try vk.Gfx.init(alloc, debug);
        self.resourceHeap = try vk.DescriptorHeap.init(&self.gfx, .Resource, numResourceDescriptors orelse self.gfx.physical.maxResourceDescriptors());
        self.samplerHeap = try vk.DescriptorHeap.init(&self.gfx, .Sampler, numSamplerDescriptors orelse self.gfx.physical.maxSamplerDescriptors());
    }

    pub fn deinit(self: *Self) void {
        self.samplerHeap.deinit();
        self.resourceHeap.deinit();
        self.gfx.deinit();

        zstbi.deinit();

        c.SDL_Vulkan_UnloadLibrary();
        c.SDL_Quit();
    }

    pub fn loadGraphicsPipeline(self: *Self, path: []const u8) !vk.Pipeline {
        const meshName = try std.mem.joinZ(self.gfx.alloc, "", &[_][]const u8{ path, ".mesh.spv" });
        defer self.gfx.alloc.free(meshName);
        var shaderMesh = try vk.Shader.init(&self.gfx, meshName);
        defer shaderMesh.deinit(&self.gfx);

        const fragName = try std.mem.joinZ(self.gfx.alloc, "", &[_][]const u8{ path, ".frag.spv" });
        defer self.gfx.alloc.free(fragName);
        var shaderFrag = try vk.Shader.init(&self.gfx, fragName);
        defer shaderFrag.deinit(&self.gfx);

        const pipeline = try vk.Pipeline.initGraphics(&self.gfx, &shaderMesh, &shaderFrag, path);
        return pipeline;
    }
};