const std = @import("std");
const c = @import("cimport.zig").c;
const vk = @import("vk_gfx.zig");
const zstbi = @import("zstbi");
const descr = @import("descriptors.zig");

fn ListNode(List: type, T: type) type {
    return struct {
        data: T,
        node: List.Node = .{},

        pub const Self = @This();

        pub fn getFromNode(n: *List.Node) *Self {
            return @fieldParentPtr("node", n);
        }

        pub fn getFromData(d: *T) *Self {
            return @fieldParentPtr("data", d);
        }
    };
}

pub const BufferArena = struct {
    buffer: vk.Buffer,
    offset: u64 = 0,

    pub const Alloc = struct {
        buffer: *vk.Buffer, 
        offset: u64,
        size: u64,

        pub fn slice(self: *const @This()) []u8 {
            return self.buffer.hostAddress.?[self.offset..self.offset + self.size];
        }

        pub fn deviceAddress(self: *const @This()) u64 {
            return self.buffer.deviceAddress + self.offset;
        }

        pub fn descriptorData(self: *const @This()) vk.DescriptorData {
            return .{
                .buffer = .{
                    .obj = self.buffer,
                    .offset = self.offset,
                    .size = self.size,
                },
            };
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
    buffers: std.DoublyLinkedList = .{},
    gfx: *vk.Gfx,

    pub const Self = @This();
    pub const BufferNode = ListNode(std.DoublyLinkedList, BufferArena);

    pub fn init(gfx: *vk.Gfx) Self {
        return Self{
            .gfx = gfx,
        };
    }

    pub fn deinit(self: *Self) void {
        while (self.buffers.popFirst()) |node| {
            var bufNode = BufferNode.getFromNode(node);
            bufNode.data.buffer.deinit();
            self.gfx.alloc.destroy(bufNode);
        }
    }

    pub fn get(self: *Self, bufDesc: *const vk.Buffer.Descriptor) !*BufferArena {
        var node = self.buffers.first;
        while (node) |n| {
            const bufNode = BufferNode.getFromNode(n);
            if (isDescriptorCompatible(&bufNode.data.buffer.desc, bufDesc)) {
                self.buffers.remove(n);
                return &bufNode.data;
            }
            node = n.next;
        }
        const newNode = try self.gfx.alloc.create(BufferNode);
        newNode.* = .{
            .data = try BufferArena.init(self.gfx, bufDesc),
        };
        return &newNode.data;
    }

    pub fn relinquish(self: *Self, newBuffer: *BufferArena) void {
        const newNode = BufferNode.getFromData(newBuffer);
        var node = self.buffers.first;
        while (node) |n| {
            const bufNode = BufferNode.getFromNode(n);
            if (bufNode.data.buffer.desc.size > newBuffer.buffer.desc.size) {
                self.buffers.insertBefore(n, &newNode.node);
                break;
            }
            node = n.next;
        } else {
            self.buffers.append(&newNode.node);
        }
    }

    fn isDescriptorCompatible(existing: *const vk.Buffer.Descriptor, requested: *const vk.Buffer.Descriptor) bool {
        return 
            existing.usage == requested.usage and 
            existing.size >= requested.size and 
            existing.alignment >= requested.alignment;
    }
};

pub const BufferAllocator = struct {
    buffers: std.DoublyLinkedList = .{},
    bufferDesc: vk.Buffer.Descriptor,
    currentBuffer: ?*BufferNode = null,
    pool: *BufferPool,

    pub const Self = @This();
    pub const BufferNode = BufferPool.BufferNode;

    pub fn init(pool: *BufferPool, bufferDesc: *const vk.Buffer.Descriptor) !Self {
        return Self{
            .bufferDesc = bufferDesc.*,
            .pool = pool,
        };
    }

    pub fn reset(self: *Self) void {
        while (self.buffers.popFirst()) |n| {
            const bufNode = BufferNode.getFromNode(n);
            bufNode.data.reset();
            if (bufNode.data.buffer.desc.equal(&self.bufferDesc)) {
                self.pool.relinquish(&bufNode.data);
            } else {
                bufNode.data.deinit();
                self.pool.gfx.alloc.destroy(bufNode);
            }
        }
        self.currentBuffer = null;
    }

    pub fn alloc(self: *Self, size: u64, alignment: u64) !BufferArena.Alloc {
        std.debug.assert((self.currentBuffer == null) == (self.buffers.first == null));
        var node = self.buffers.first;
        while (node) |n| {
            const bufNode = BufferNode.getFromNode(n);
            const bufAlloc = bufNode.data.alloc(size, alignment) catch |err| switch (err) {
                error.BufferNotBigEnough => {
                    node = n.next;
                    if (bufNode == self.currentBuffer)
                        break;
                    continue;
                }
            };
            self.currentBuffer = bufNode;
            return bufAlloc;
        }
        const bufDesc = vk.Buffer.Descriptor{
            .size = @max(size, self.bufferDesc.size),
            .alignment = @max(alignment, self.bufferDesc.alignment),
            .usage = self.bufferDesc.usage,
        };
        const bufNode = BufferNode.getFromData(try self.pool.get(&bufDesc));
        self.buffers.append(&bufNode.node);
        self.currentBuffer = bufNode;
        return bufNode.data.alloc(size, alignment) catch unreachable;
    }
};

pub const SubmitInfo = struct {
    preCmds: vk.Commands,
    cmds: vk.Commands,
    submitSemaphore: vk.Semaphore,
    staging: BufferAllocator,
    transientDescriptors: DescriptorArray,
    renderer: *Renderer,

    const DescriptorArray = std.array_list.Aligned(vk.HeapDescriptor, null);
    pub const Self = @This();
    pub fn init(renderer: *Renderer, stagingSize: u64) !Self {
        return Self{
            .preCmds = try vk.Commands.init(&renderer.gfx),
            .cmds = try vk.Commands.init(&renderer.gfx),
            .submitSemaphore = try vk.Semaphore.init(&renderer.gfx, null),
            .staging = 
                try BufferAllocator.init(&renderer.bufferPool, &.{ 
                    .size = stagingSize,
                    .usage = .{.hostWrite = true, .storageRead = true, .transferSrc = true},
                }),
            .transientDescriptors = try DescriptorArray.initCapacity(renderer.gfx.alloc, 0),
            .renderer = renderer,
        };
    }
    pub fn deinit(self: *Self) !void {
        try self.cmds.waitFinished();
        try self.reset();
        self.transientDescriptors.deinit(self.renderer.gfx.alloc);
        self.preCmds.deinit();
        self.cmds.deinit();
        self.submitSemaphore.deinit();
    }

    pub fn reset(self: *Self) !void {
        self.staging.reset();
        for (self.transientDescriptors.items) |desc|
            try self.renderer.freeDescriptor(desc);
        self.transientDescriptors.clearRetainingCapacity();
    }

    pub fn submit(self: *Self, waitSemaphore: ?*vk.Semaphore) !void {
        const hasDescriptorUploads = self.renderer.resources.hasPendingUploads() or self.renderer.samplers.hasPendingUploads();
        if (hasDescriptorUploads) {
            try self.preCmds.begin();
            try self.uploadDescriptors(&self.preCmds);
            try self.preCmds.end();
            try self.renderer.gfx.submit(
                @constCast(&[_]*vk.Commands{&self.preCmds, &self.cmds}),
                waitSemaphore
            );
        } else {
            try self.cmds.submit(waitSemaphore);
        }
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

    pub fn uploadHeapDescriptors(self: *Self, descHeap: *DescriptorHeapManaged, cmds: *vk.Commands) !void {
        if (descHeap.writer.updatesSize == 0)
            return;
        const upload = try self.staging.alloc(descHeap.writer.updatesSize, 1);
        try descHeap.writer.uploadSetDescriptors(cmds, upload.buffer, upload.offset);
        descHeap.writer.clear(false);
    }

    pub fn uploadDescriptors(self: *Self, cmds: *vk.Commands) !void {
        try self.uploadHeapDescriptors(&self.renderer.samplers, cmds);
        try self.uploadHeapDescriptors(&self.renderer.resources, cmds);
    }

    pub fn bindDescriptorHeaps(self: *Self) void {
        self.cmds.bindDescriptorHeap(&self.renderer.samplers.heap);
        self.cmds.bindDescriptorHeap(&self.renderer.resources.heap);
    }

    pub fn setTransientDescriptor(self: *Self, descData: *const vk.DescriptorData) !vk.HeapDescriptor {
        const desc = try self.renderer.setDescriptor(descData);
        try self.transientDescriptors.append(self.renderer.gfx.alloc, desc);
        return desc;
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

const DescriptorHeapManaged = descr.DescriptorHeapManaged;

pub const Renderer = struct {
    gfx: vk.Gfx,
    resources: DescriptorHeapManaged,
    samplers: DescriptorHeapManaged,
    bufferPool: BufferPool,

    pub const Self = @This();

    pub fn init(self: *Self, alloc: std.mem.Allocator, debug: bool, numResourceDescriptors: ?u32, numSamplerDescriptors: ?u32) !void {
        try vk.sdl_errify(c.SDL_Init(c.SDL_INIT_VIDEO));
        if (!c.SDL_Vulkan_LoadLibrary(null))
            return error.SDLCouldNotLoadVulkan;

        zstbi.init(alloc);

        try self.gfx.init(alloc, debug);
        try self.resources.init(&self.gfx, .Resource, numResourceDescriptors orelse @intCast(self.gfx.physical.maxResourceDescriptors()));
        try self.samplers.init(&self.gfx, .Sampler, numSamplerDescriptors orelse @intCast(self.gfx.physical.maxSamplerDescriptors()));
        self.bufferPool = BufferPool.init(&self.gfx);
    }

    pub fn deinit(self: *Self) void {
        self.bufferPool.deinit();
        self.samplers.deinit();
        self.resources.deinit();
        self.gfx.deinit();

        zstbi.deinit();

        c.SDL_Vulkan_UnloadLibrary();
        c.SDL_Quit();
    }

    fn getHeapForDescriptorType(self: *Self, descType: vk.DescriptorType) *DescriptorHeapManaged {
        return switch (descType) {
            .sampler => &self.samplers,
            .buffer, .image => &self.resources,
        };
    }

    pub fn setDescriptor(self: *Self, descData: *const vk.DescriptorData) !vk.HeapDescriptor {
        const heap = self.getHeapForDescriptorType(descData.*);
        return heap.setDescriptor(descData);
    }

    pub fn freeDescriptor(self: *Self, desc: vk.HeapDescriptor) !void {
        const heap = self.getHeapForDescriptorType(desc.type);
        try heap.freeDescriptor(desc);
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