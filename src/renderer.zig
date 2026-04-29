const std = @import("std");
const c = @import("cimport.zig").c;
const vk = @import("vk_gfx.zig");
const zstbi = @import("zstbi");

pub const BufferArena = struct {
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

    pub fn init(gfx: *vk.Gfx, bufferDesc: *const vk.Buffer.Descriptor) !Self {
        return Self {
            .buffer = try vk.Buffer.init(gfx, bufferDesc),
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
    }

    pub fn alloc(self: *Self, size: u64, alignment: u64) !Alloc {
        std.debug.assert(std.math.isPowerOfTwo(alignment));
        const bufAddr = 
            if (self.buffer.desc.usage.hostRead or self.buffer.desc.usage.hostWrite)
                @as(u64, @intFromPtr(self.buffer.hostAddress))
            else
                self.buffer.deviceAddress;
        const alignedOffs = ((bufAddr + self.offset + alignment - 1) & ~(alignment - 1)) - bufAddr;
        std.debug.assert(alignedOffs >= self.offset);

        if (alignedOffs + size > self.buffer.desc.size)
            return error.BufferNotBigEnough;
        const start = alignedOffs;
        self.offset = alignedOffs + size;
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

pub const BufferPool = struct {
    buffers: std.ArrayList(*BufferArena),
    bufferDesc: vk.Buffer.Descriptor,
    bufferIndex: u32 = 0,
    gfx: *vk.Gfx,

    pub const Self = @This();

    pub fn init(gfx: *vk.Gfx, bufferDesc: *const vk.Buffer.Descriptor) !Self {
        return Self{
            .buffers = try std.ArrayList(*BufferArena).initCapacity(gfx.alloc, 0),
            .bufferDesc = bufferDesc.*,
            .gfx = gfx,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.buffers.items) |arena| {
            arena.deinit();
            self.gfx.alloc.destroy(arena);
        }
        self.buffers.deinit(self.gfx.alloc);
    }

    pub fn reset(self: *Self) void {
        if (self.buffers.items.len > 0) {
            for (self.buffers.items[0..self.bufferIndex + 1]) |buf|
                buf.reset();
        }
        self.bufferIndex = 0;
    }

    pub fn alloc(self: *Self, size: u64, alignment: u64) !BufferArena.Alloc {
        var bufAlloc = self.tryAllocExisting(size, alignment);
        if (bufAlloc == null) {
            const bufDesc = vk.Buffer.Descriptor{
                .size = @max(size, self.bufferDesc.size),
                .alignment = @max(alignment, self.bufferDesc.alignment),
                .usage = self.bufferDesc.usage,
            };
            const bufArena = try self.gfx.alloc.create(BufferArena);
            bufArena.* = try BufferArena.init(self.gfx, &bufDesc);
            try self.buffers.append(self.gfx.alloc, bufArena);
            self.bufferIndex = @intCast(self.buffers.items.len - 1);
            bufAlloc = try self.buffers.items[self.bufferIndex].alloc(size, alignment);
        }
        return bufAlloc.?;
    }

    fn tryAllocExisting(self: *Self, size: u64, alignment: u64) ?BufferArena.Alloc {
        for (0..self.buffers.items.len) |i| {
            var idx = self.bufferIndex + i;
            if (idx >= self.buffers.items.len)
                idx -= self.buffers.items.len;
            const bufAlloc = self.buffers.items[idx].alloc(size, alignment) catch |err| switch (err) {
                error.BufferNotBigEnough => continue,
            };
            self.bufferIndex = @intCast(idx);
            return bufAlloc;
        }
        return null;
    }
};

pub const SubmitInfo = struct {
    cmds: vk.Commands,
    submitSemaphore: vk.Semaphore,
    staging: BufferPool,

    const Self = @This();
    pub fn init(gfx: *vk.Gfx, stagingSize: u64) !Self {
        return Self{
            .cmds = try vk.Commands.init(gfx),
            .submitSemaphore = try vk.Semaphore.init(gfx, null),
            .staging = 
                try BufferPool.init(gfx, &.{ 
                    .size = stagingSize,
                    .usage = .{.hostWrite = true, .transferSrc = true},
                }),
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

        const pixels = try self.staging.alloc(loaded.width * loaded.height * 4, 1);
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

        try self.gfx.init(alloc, debug);
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
        var shaderMesh = mesh: {
            const meshName = try std.mem.joinZ(self.gfx.alloc, "", &[_][]const u8{ path, ".mesh.spv" });
            defer self.gfx.alloc.free(meshName);
            break :mesh try vk.Shader.init(&self.gfx, meshName);
        };
        defer shaderMesh.deinit(&self.gfx);

        var shaderFrag = frag: {
            const fragName = try std.mem.joinZ(self.gfx.alloc, "", &[_][]const u8{ path, ".frag.spv" });
            defer self.gfx.alloc.free(fragName);
            break :frag try vk.Shader.init(&self.gfx, fragName);
        };
        defer shaderFrag.deinit(&self.gfx);

        const pipeline = try vk.Pipeline.initGraphics(&self.gfx, &shaderMesh, &shaderFrag, path);
        return pipeline;
    }

    pub fn loadComputePipeline(self: *Self, path: []const u8) !vk.Pipeline {
        var shaderCompute = compute: {
            const computeName = try std.mem.joinZ(self.gfx.alloc, "", &[_][]const u8{ path, ".comp.spv" });
            defer self.gfx.alloc.free(computeName);
            break :compute try vk.Shader.init(&self.gfx, computeName);
        };
        defer shaderCompute.deinit(&self.gfx);

        const pipeline = try vk.Pipeline.initCompute(&self.gfx, &shaderCompute, path);
        return pipeline;
    }
};