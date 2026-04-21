const std = @import("std");
const c = @import("cimport.zig").c;

fn DebugCallback(severity: c.VkDebugUtilsMessageSeverityFlagBitsEXT, msgType: c.VkDebugUtilsMessageTypeFlagsEXT, cbData: [*c]const c.VkDebugUtilsMessengerCallbackDataEXT, userData: ?*anyopaque) callconv(.c) c.VkBool32 {
    _ = userData;
    const severityStr = switch (severity) {
        c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT => "Verbose",
        c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT => "Info",
        c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT => "Warning",
        c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT => "Error",
        else => "Unimplemented",
    };
    const msgTypeStr = switch (msgType) {
        c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT => "General",
        c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT => "Validation",
        c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT => "Performance",
        else => "Unimplemented",
    };
    const msg: [*c]const u8 = if (cbData != null) cbData.*.pMessage else "No Message";
    std.log.info("[{s}][{s}] Msg: {s}\n", .{ severityStr, msgTypeStr, msg });
    return c.VK_FALSE;
}

pub const Gfx = struct {
    alloc: std.mem.Allocator,
    allocCB: ?*c.VkAllocationCallbacks = null,
    instance: c.VkInstance = null,
    dbgMessenger: c.VkDebugUtilsMessengerEXT = null,
    physical: PhysicalDevice,
    device: Device,
    swapchainFormat: c.VkFormat,
    swapchainColorspace: c.VkColorSpaceKHR,
    cmdDrawMeshTasksEXT: c.PFN_vkCmdDrawMeshTasksEXT = null,
    cmdPushDataEXT: c.PFN_vkCmdPushDataEXT = null,
    cmdBindSamplerHeapEXT: c.PFN_vkCmdBindSamplerHeapEXT = null,
    cmdBindResourceHeapEXT: c.PFN_vkCmdBindResourceHeapEXT = null,
    writeResourceDescriptorsEXT: c.PFN_vkWriteResourceDescriptorsEXT = null,
    writeSamplerDescriptorsEXT: c.PFN_vkWriteSamplerDescriptorsEXT = null,
    vma: c.VmaAllocator = null,

    pub const API_VERSION = c.VK_API_VERSION_1_4;
    pub const Self = @This();

    pub fn init(self: *Self, allocator: std.mem.Allocator, debug: bool) !void {
        self.alloc = allocator;
        self.allocCB = null;

        var layers = try std.ArrayList([*c]const u8).initCapacity(self.alloc, 0);
        defer layers.deinit(self.alloc);

        var exts = try std.ArrayList([*c]const u8).initCapacity(self.alloc, 0);
        defer exts.deinit(self.alloc);

        var sdlExtCount: u32 = 0;
        const sdlExts = c.SDL_Vulkan_GetInstanceExtensions(&sdlExtCount);
        try exts.appendSlice(self.alloc, sdlExts[0..sdlExtCount]);

        var dbgMessengerInfo = c.VkDebugUtilsMessengerCreateInfoEXT{
            .sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .messageSeverity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            .messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
            .pfnUserCallback = &DebugCallback,
            .pUserData = self,
        };
        if (debug) {
            try layers.append(self.alloc, "VK_LAYER_KHRONOS_validation");
            try exts.append(self.alloc, c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME);
        }

        const instInfo = c.VkInstanceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = if (debug) &dbgMessengerInfo else null,
            .pApplicationInfo = &c.VkApplicationInfo{
                .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
                .apiVersion = API_VERSION,
                .pEngineName = "LastGfx",
            },
            .enabledLayerCount = @intCast(layers.items.len),
            .ppEnabledLayerNames = layers.items.ptr,
            .enabledExtensionCount = @intCast(exts.items.len),
            .ppEnabledExtensionNames = exts.items.ptr,
        };
        try check(c.vkCreateInstance(&instInfo, self.allocCB, &self.instance));

        self.dbgMessenger = null;
        if (debug) {
            const vkCreateDebugUtilsMessengerEXT = self.getInstanceProcAddress(c.PFN_vkCreateDebugUtilsMessengerEXT, "vkCreateDebugUtilsMessengerEXT");
            if (vkCreateDebugUtilsMessengerEXT) |func| {
                try check(func(self.instance, &dbgMessengerInfo, self.allocCB, &self.dbgMessenger));
            } else {
                return error.function_not_found;
            }
        }

        self.physical = try self.selectPhysicalDevice();


        std.log.info("GPU: {s}, driver ver.{s}, conformance ver.{}.{}.{}.{}, Vulkan ver.{}.{}.{}.{}\n", .{
            self.physical.props.properties.deviceName,
            self.physical.driverProps.driverInfo,
            self.physical.driverProps.conformanceVersion.major,
            self.physical.driverProps.conformanceVersion.minor,
            self.physical.driverProps.conformanceVersion.subminor,
            self.physical.driverProps.conformanceVersion.patch,
            c.VK_API_VERSION_VARIANT(self.physical.props.properties.apiVersion),
            c.VK_API_VERSION_MAJOR(self.physical.props.properties.apiVersion),
            c.VK_API_VERSION_MINOR(self.physical.props.properties.apiVersion),
            c.VK_API_VERSION_PATCH(self.physical.props.properties.apiVersion),
        });

        self.device = try self.createDevice();

        self.swapchainFormat = c.VK_FORMAT_B8G8R8A8_SRGB;
        self.swapchainColorspace = c.VK_COLORSPACE_SRGB_NONLINEAR_KHR;

        try check(c.vmaCreateAllocator(&c.VmaAllocatorCreateInfo{
            .flags = c.VMA_ALLOCATOR_CREATE_KHR_MAINTENANCE4_BIT | c.VMA_ALLOCATOR_CREATE_KHR_MAINTENANCE5_BIT | c.VMA_ALLOCATOR_CREATE_BUFFER_DEVICE_ADDRESS_BIT,
            .instance = self.instance,
            .physicalDevice = self.physical.handle,
            .device = self.device.handle,
            .vulkanApiVersion = API_VERSION,
            .pAllocationCallbacks = self.allocCB,
        }, &self.vma));
        std.debug.assert(self.vma != null);
    }

    pub fn deinit(self: *Self) void {
        c.vmaDestroyAllocator(self.vma);
        self.physical.deinit(self.alloc);
        c.vkDestroyDevice(self.device.handle, self.allocCB);

        if (self.dbgMessenger != null) {
            const vkDestroyDebugUtilsMessengerEXT = self.getInstanceProcAddress(c.PFN_vkDestroyDebugUtilsMessengerEXT, "vkDestroyDebugUtilsMessengerEXT");
            if (vkDestroyDebugUtilsMessengerEXT) |func|
                func(self.instance, self.dbgMessenger, self.allocCB);
        }

        c.vkDestroyInstance(self.instance, self.allocCB);
    }

    fn getInstanceProcAddress(self: *Self, comptime Fn: type, name: [*c]const u8) Fn {
        return @ptrCast(c.vkGetInstanceProcAddr(self.instance, name));
    }

    fn selectPhysicalDevice(self: *Self) !PhysicalDevice {
        var numDevices: u32 = 0;
        try check(c.vkEnumeratePhysicalDevices(self.instance, &numDevices, null));

        var devices = try std.ArrayList(c.VkPhysicalDevice).initCapacity(self.alloc, 0);
        defer devices.deinit(self.alloc);
        try devices.resize(self.alloc, numDevices);

        try check(c.vkEnumeratePhysicalDevices(self.instance, &numDevices, devices.items.ptr));

        var bestProps: ?PhysicalDevice = null;

        devices: for (devices.items) |device| {
            var devProps = try PhysicalDevice.init(self.instance, device, self.alloc);
            defer if (bestProps == null or devProps.handle != bestProps.?.handle)
                devProps.deinit(self.alloc);

            if (devProps.props.properties.apiVersion < API_VERSION)
                continue;
            if (devProps.universalQueueFamily < 0)
                continue;
            extensions: for (&deviceExtensions) |reqExtName| {
                for (devProps.extensions) |*devExt| {
                    if (std.mem.orderZ(u8, reqExtName, @ptrCast(&devExt.extensionName)) == .eq)
                        continue :extensions;
                }
                continue :devices;
            }
            if (bestProps) |best| {
                if ((try deviceTypePriority(devProps.props.properties.deviceType)) <= (try deviceTypePriority(best.props.properties.deviceType)))
                    continue;
            }
            bestProps = devProps;
        }

        return bestProps.?;
    }

    var deviceExtensions = [_][*c]const u8{
            c.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
            c.VK_EXT_MESH_SHADER_EXTENSION_NAME,
            c.VK_KHR_SHADER_UNTYPED_POINTERS_EXTENSION_NAME,
            c.VK_EXT_DESCRIPTOR_HEAP_EXTENSION_NAME,
        };

    fn createDevice(self: *Self) !Device {
        var device: Device = undefined;
        try check(c.vkCreateDevice(self.physical.handle, &c.VkDeviceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                .pNext = @constCast(&c.VkPhysicalDeviceMeshShaderFeaturesEXT{
                    .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT,
                    .meshShader = c.VK_TRUE,
                .pNext = @constCast(&c.VkPhysicalDeviceVulkan12Features{
                    .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
                    .bufferDeviceAddress = c.VK_TRUE,
                    .scalarBlockLayout = c.VK_TRUE,
                    .shaderStorageBufferArrayNonUniformIndexing = c.VK_TRUE,
                    .shaderSampledImageArrayNonUniformIndexing = c.VK_TRUE,
                    .shaderStorageImageArrayNonUniformIndexing = c.VK_TRUE,
                    .pNext = @constCast(&c.VkPhysicalDeviceVulkan13Features{
                        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
                        .dynamicRendering = c.VK_TRUE,
                        .maintenance4 = c.VK_TRUE,
                        .synchronization2 = c.VK_TRUE,
                        .pNext = @constCast(&c.VkPhysicalDeviceVulkan14Features{
                            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_4_FEATURES,
                            .maintenance5 = c.VK_TRUE,
                                .pNext = @constCast(&c.VkPhysicalDeviceShaderUntypedPointersFeaturesKHR{
                                    .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_UNTYPED_POINTERS_FEATURES_KHR,
                                    .shaderUntypedPointers = c.VK_TRUE,
                                    .pNext = @constCast(&c.VkPhysicalDeviceDescriptorHeapFeaturesEXT{
                                        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_HEAP_FEATURES_EXT,
                                        .descriptorHeap = c.VK_TRUE,
                                        }),
                                    }),
                                }),
                            }),
                        }),
                    }),
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &c.VkDeviceQueueCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .queueFamilyIndex = @intCast(self.physical.universalQueueFamily),
                .queueCount = 1,
                .pQueuePriorities = &[_]f32{0},
            },
            .enabledExtensionCount = @intCast(deviceExtensions.len),
            .ppEnabledExtensionNames = &deviceExtensions,
        }, self.allocCB, &device.handle));
        c.vkGetDeviceQueue(device.handle, @intCast(self.physical.universalQueueFamily), 0, &device.universalQueue);
        std.debug.assert(device.universalQueue != null);

        self.cmdDrawMeshTasksEXT = @ptrCast(c.vkGetDeviceProcAddr(device.handle, "vkCmdDrawMeshTasksEXT"));
        std.debug.assert(self.cmdDrawMeshTasksEXT != null);

        self.cmdPushDataEXT = @ptrCast(c.vkGetDeviceProcAddr(device.handle, "vkCmdPushDataEXT"));
        std.debug.assert(self.cmdPushDataEXT != null);

        self.cmdBindSamplerHeapEXT = @ptrCast(c.vkGetDeviceProcAddr(device.handle, "vkCmdBindSamplerHeapEXT"));
        std.debug.assert(self.cmdBindSamplerHeapEXT != null);

        self.cmdBindResourceHeapEXT = @ptrCast(c.vkGetDeviceProcAddr(device.handle, "vkCmdBindResourceHeapEXT"));
        std.debug.assert(self.cmdBindResourceHeapEXT != null);

        self.writeResourceDescriptorsEXT = @ptrCast(c.vkGetDeviceProcAddr(device.handle, "vkWriteResourceDescriptorsEXT"));
        std.debug.assert(self.writeResourceDescriptorsEXT != null);

        self.writeSamplerDescriptorsEXT = @ptrCast(c.vkGetDeviceProcAddr(device.handle, "vkWriteSamplerDescriptorsEXT"));
        std.debug.assert(self.writeSamplerDescriptorsEXT != null);

        return device;
    }

    pub fn waitIdle(self: *Self) !void {
        try check(c.vkDeviceWaitIdle(self.device.handle));
    }
};

pub const PhysicalDevice = struct {
    handle: c.VkPhysicalDevice = null,
    props: c.VkPhysicalDeviceProperties2 = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2 },
    extensions: []c.VkExtensionProperties = &.{},
    driverProps: c.VkPhysicalDeviceDriverProperties = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES },
    descriptorHeapProps: c.VkPhysicalDeviceDescriptorHeapPropertiesEXT = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_HEAP_PROPERTIES_EXT },
    universalQueueFamily: i32 = -1,

    pub const Self = @This();
    fn init(instance: c.VkInstance, physDev: c.VkPhysicalDevice, alloc: std.mem.Allocator) !Self {
        var phys = PhysicalDevice{
            .handle = physDev,
        };

        phys.props.pNext = &phys.driverProps;
        phys.driverProps.pNext = &phys.descriptorHeapProps;
        c.vkGetPhysicalDeviceProperties2(phys.handle, &phys.props);

        var numExtensions: u32 = 0;
        try check(c.vkEnumerateDeviceExtensionProperties(phys.handle, null, &numExtensions, null));
        phys.extensions = try alloc.alloc(c.VkExtensionProperties, numExtensions);
        try check(c.vkEnumerateDeviceExtensionProperties(phys.handle, null, &numExtensions, phys.extensions.ptr));

        var numQueueFamilies: u32 = 0;
        c.vkGetPhysicalDeviceQueueFamilyProperties(physDev, &numQueueFamilies, null);
        var queues = try std.ArrayList(c.VkQueueFamilyProperties).initCapacity(alloc, 0);
        defer queues.deinit(alloc);
        try queues.resize(alloc, numQueueFamilies);
        c.vkGetPhysicalDeviceQueueFamilyProperties(physDev, &numQueueFamilies, queues.items.ptr);
        const universalMask = c.VK_QUEUE_GRAPHICS_BIT | c.VK_QUEUE_COMPUTE_BIT | c.VK_QUEUE_TRANSFER_BIT;
        for (queues.items, 0..) |familyProps, familyIndex| {
            const canPresent = c.SDL_Vulkan_GetPresentationSupport(instance, physDev, @intCast(familyIndex));
            if ((familyProps.queueFlags & universalMask) == universalMask and canPresent) {
                phys.universalQueueFamily = @intCast(familyIndex);
                break;
            }
        }

        return phys;
    }

    fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        alloc.free(self.extensions);
    }
};

pub const Device = struct {
    handle: c.VkDevice,
    universalQueue: c.VkQueue,
};

pub const RenderTarget = struct {
    image: *Image,
    clearValue: ?c.VkClearValue = null,

    pub const Self = @This();
    fn attachment(self: *const Self) c.VkRenderingAttachmentInfo {
        return .{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .imageView = self.image.view,
            .imageLayout = c.VK_IMAGE_LAYOUT_GENERAL,
            .loadOp = if (self.clearValue) |_| c.VK_ATTACHMENT_LOAD_OP_CLEAR else c.VK_ATTACHMENT_LOAD_OP_LOAD,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .clearValue = if (self.clearValue) |clr| clr else std.mem.zeroes(c.VkClearValue),
        };
    }
};

pub const Commands = struct {
    handle: c.VkCommandBuffer = null,
    pool: c.VkCommandPool = null,
    fence: c.VkFence = null,
    gfx: *Gfx,

    pub const Self = @This();
    pub fn init(gfx: *Gfx) !Self {
        var self: Self = .{ .gfx = gfx };
        try check(c.vkCreateCommandPool(gfx.device.handle, &c.VkCommandPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = @intCast(gfx.physical.universalQueueFamily),
        }, gfx.allocCB, &self.pool));
        try check(c.vkAllocateCommandBuffers(gfx.device.handle, &c.VkCommandBufferAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = self.pool,
            .commandBufferCount = 1,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        }, &self.handle));
        try check(c.vkCreateFence(gfx.device.handle, &c.VkFenceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
        }, gfx.allocCB, &self.fence));
        return self;
    }

    pub fn deinit(self: *Self) void {
        c.vkDestroyFence(self.gfx.device.handle, self.fence, self.gfx.allocCB);
        c.vkFreeCommandBuffers(self.gfx.device.handle, self.pool, 1, &self.handle);
        c.vkDestroyCommandPool(self.gfx.device.handle, self.pool, self.gfx.allocCB);
    }

    pub fn begin(self: *Self) !void {
        try check(c.vkResetFences(self.gfx.device.handle, 1, &self.fence));
        try check(c.vkBeginCommandBuffer(self.handle, &c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        }));
    }

    pub fn bindDescriptorHeap(self: *Self, descHeap: *const DescriptorHeap) void {
        const bindInfo = c.VkBindHeapInfoEXT{
            .sType = c.VK_STRUCTURE_TYPE_BIND_HEAP_INFO_EXT,
            .reservedRangeOffset = descHeap.deviceBuffer.desc.size - descHeap.reservedSize,
            .reservedRangeSize = descHeap.reservedSize,
            .heapRange = .{ 
                .address = descHeap.deviceBuffer.deviceAddress, 
                .size = descHeap.deviceBuffer.desc.size 
            },
        };
        switch (descHeap.kind) {
            .Sampler => self.gfx.cmdBindSamplerHeapEXT.?(self.handle, &bindInfo),
            .Resource => self.gfx.cmdBindResourceHeapEXT.?(self.handle, &bindInfo),
        }
    }

    pub fn updateDescriptorHeap(self: *Self, descHeap: *const DescriptorHeap) void {
        self.copyBuffer(&descHeap.cpuBuffer, &descHeap.deviceBuffer, &[_]c.VkBufferCopy2{
            .{
                .sType = c.VK_STRUCTURE_TYPE_BUFFER_COPY_2,
                .srcOffset = 0,
                .dstOffset = 0,
                .size = descHeap.deviceBuffer.desc.size - descHeap.reservedSize,
            },
        });
    }

    pub fn renderBegin(self: *Self, colorTargets: []const RenderTarget, depthStencilTarget: ?RenderTarget) !void {
        var colorAttachments = try std.ArrayList(c.VkRenderingAttachmentInfo).initCapacity(self.gfx.alloc, colorTargets.len);
        defer colorAttachments.deinit(self.gfx.alloc);
        for (colorTargets) |clrTarget| {
            try colorAttachments.append(self.gfx.alloc, clrTarget.attachment());
        }

        var depthAttachment: c.VkRenderingAttachmentInfo = undefined;
        if (depthStencilTarget) |depthStencil| {
            depthAttachment = depthStencil.attachment();
        }

        c.vkCmdBeginRendering(self.handle, &c.VkRenderingInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO,
            .layerCount = 1,
            .renderArea = c.VkRect2D{ .extent = colorTargets[0].image.desc.extent2D() },
            .colorAttachmentCount = @intCast(colorAttachments.items.len),
            .pColorAttachments = colorAttachments.items.ptr,
            .pDepthAttachment = if (depthStencilTarget) |_| &depthAttachment else null,
            .pStencilAttachment = if (depthStencilTarget) |_| &depthAttachment else null,
        });
    }

    pub fn setViewport(self: *Self, viewport: *const c.VkViewport) void {
        c.vkCmdSetViewport(self.handle, 0, 1, viewport);
    }

    pub fn setScissor(self: *Self, rect: *const c.VkRect2D) void {
        c.vkCmdSetScissor(self.handle, 0, 1, rect);
    }

    pub fn bindRenderPipeline(self: *Self, pipeline: *const Pipeline) void {
        c.vkCmdBindPipeline(self.handle, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.handle);
    }

    pub fn pushDataBytes(self: *Self, data: []const u8, offset: u32) void {
        self.gfx.cmdPushDataEXT.?(self.handle, &c.VkPushDataInfoEXT{
            .sType = c.VK_STRUCTURE_TYPE_PUSH_DATA_INFO_EXT,
            .offset = offset,
            .data = .{
                .address = data.ptr,
                .size = data.len,
            },
        });
    }

    pub fn pushData(self: *Self, arg: anytype) void {
        comptime if (@typeInfo(@TypeOf(arg)) != .pointer)
            @compileError("pushData argument has to be a pointer");

        const bytes = @as([*]const u8, @ptrCast(arg))[0..@sizeOf(@TypeOf(arg.*))];
        self.pushDataBytes(bytes, 0);
    }

    pub fn drawMeshTasks(self: *Self, groupCountX: u32, groupCountY: u32, groupCountZ: u32) void {
        self.gfx.cmdDrawMeshTasksEXT.?(self.handle, groupCountX, groupCountY, groupCountZ);
    }

    pub fn renderEnd(self: *Self) void {
        c.vkCmdEndRendering(self.handle);
    }

    pub fn end(self: *Self) !void {
        try check(c.vkEndCommandBuffer(self.handle));
    }

    fn stageWithDefault(stage: c.VkPipelineStageFlags2, default: c.VkPipelineStageFlags2) c.VkPipelineStageFlags2 {
        return
            if (stage != 0)
                stage
            else 
                default;
    }

    pub fn bufferBarrier(self: *Self, buffer: *const Buffer, prevUsage: Usage, prevPipelineKind: Pipeline.Kind, nextUsage: Usage, nextPipelineKind: Pipeline.Kind) void {
        c.vkCmdPipelineBarrier2(self.handle, &c.VkDependencyInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .bufferMemoryBarrierCount = 1,
            .pBufferMemoryBarriers = &c.VkBufferMemoryBarrier2{
                .sType = c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER_2,
                .srcStageMask = stageWithDefault(Buffer.stageFlags(prevUsage, prevPipelineKind), c.VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT),
                .dstStageMask = stageWithDefault(Buffer.stageFlags(nextUsage, nextPipelineKind), c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT),
                .srcAccessMask = Buffer.accessFlags(prevUsage),
                .dstAccessMask = Buffer.accessFlags(nextUsage),
                .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                .buffer = buffer.handle,
                .offset = 0,
                .size = buffer.desc.size,
            },
        });
    }

    pub fn imageBarrier(self: *Self, image: *const Image, prevUsage: Usage, prevPipelineKind: Pipeline.Kind, nextUsage: Usage, nextPipelineKind: Pipeline.Kind) void {
        c.vkCmdPipelineBarrier2(self.handle, &c.VkDependencyInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .imageMemoryBarrierCount = 1,
            .pImageMemoryBarriers = &c.VkImageMemoryBarrier2{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
                .srcStageMask = stageWithDefault(Image.stageFlags(prevUsage, image.desc.format, prevPipelineKind), c.VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT),
                .dstStageMask = stageWithDefault(Image.stageFlags(nextUsage, image.desc.format, nextPipelineKind), c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT),
                .srcAccessMask = Image.accessFlags(prevUsage, image.desc.format),
                .dstAccessMask = Image.accessFlags(nextUsage, image.desc.format),
                .oldLayout = Image.imageLayout(prevUsage),
                .newLayout = Image.imageLayout(nextUsage),
                .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                .image = image.handle,
                .subresourceRange = wholeImage(image.desc.imageAspect()),
            },
        });
    }

    pub fn copyBuffer(self: *Self, srcBuffer: *const Buffer, dstBuffer: *const Buffer, regions: []const c.VkBufferCopy2) void {
        c.vkCmdCopyBuffer2(self.handle, &c.VkCopyBufferInfo2{
            .sType = c.VK_STRUCTURE_TYPE_COPY_BUFFER_INFO_2,
            .srcBuffer = srcBuffer.handle,
            .dstBuffer = dstBuffer.handle,
            .regionCount = @intCast(regions.len),
            .pRegions = regions.ptr,
        });
    }

    pub fn copyImage(self: *Self, srcImage: *const Image, dstImage: *const Image, regions: []const c.VkImageCopy2) void {
        c.vkCmdCopyImage2(self.handle, &c.VkCopyImageInfo2{
            .sType = c.VK_STRUCTURE_TYPE_COPY_IMAGE_INFO_2,
            .srcImage = srcImage.handle,
            .srcImageLayout = srcImage.layout(),
            .dstImage = dstImage.handle,
            .dstImageLayout = dstImage.layout(),
            .regionCount = @intCast(regions.len),
            .pRegions = regions.ptr,
        });
    }

    pub fn copyBufferToImage(self: *Self, srcBuffer: *const Buffer, dstImage: *const Image, regions: []const c.VkBufferImageCopy2) void {
        c.vkCmdCopyBufferToImage2(self.handle, &c.VkCopyBufferToImageInfo2{
            .sType = c.VK_STRUCTURE_TYPE_COPY_BUFFER_TO_IMAGE_INFO_2,
            .srcBuffer = srcBuffer.handle,
            .dstImage = dstImage.handle,
            .dstImageLayout = c.VK_IMAGE_LAYOUT_GENERAL,
            .regionCount = @intCast(regions.len),
            .pRegions = regions.ptr,
        });
    }

    pub fn copyImageToBuffer(self: *Self, srcImage: *const Image, dstBuffer: *const Buffer, regions: []const c.VkBufferImageCopy2) void {
        c.vkCmdCopyImageToBuffer2(self.handle, &c.VkCopyImageToBufferInfo2{
            .sType = c.VK_STRUCTURE_TYPE_COPY_IMAGE_TO_BUFFER_INFO_2,
            .srcImage = srcImage.handle,
            .srcImageLayout = srcImage.layout(),
            .dstBuffer = dstBuffer.handle,
            .regionCount = @intCast(regions.len),
            .pRegions = regions.ptr,
        });
    }

    pub fn submit(self: *Self, waitSemaphore: c.VkSemaphore) !void {
        try check(c.vkQueueSubmit2(
            self.gfx.device.universalQueue,
            1,
            &c.VkSubmitInfo2{
                .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
                .waitSemaphoreInfoCount = @intFromBool(waitSemaphore != null),
                .pWaitSemaphoreInfos = &c.VkSemaphoreSubmitInfo{
                    .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
                    .semaphore = waitSemaphore,
                    .stageMask = c.VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT,
                },
                .commandBufferInfoCount = 1,
                .pCommandBufferInfos = &c.VkCommandBufferSubmitInfo{
                    .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
                    .commandBuffer = self.handle,
                },
            },
            self.fence,
        ));
    }

    pub fn waitFinished(self: *Self) !void {
        try check(c.vkWaitForFences(
            self.gfx.device.handle,
            1, 
            &self.fence, 
            c.VK_TRUE, 
            std.math.maxInt(u64)
        ));
    }

    pub fn isFinished(self: *Self) !bool {
        check(c.vkGetFenceStatus(
            self.gfx.device.handle, 
            self.fence
        )) catch |err| switch (err) {
            error.vk_not_ready => return false,
            else => return err,
        };
        return true;
    }
};

pub const Swapchain = struct {
    handle: c.VkSwapchainKHR = null,
    surface: c.VkSurfaceKHR = null,
    images: []Image = &.{},
    semaphores: []SemaphoreData = &.{},
    gfx: *Gfx,
    window: ?*c.SDL_Window,
    capabilitiesHasValidExtent: bool = true,
    presentModes: []c.VkPresentModeKHR = &[_]c.VkPresentModeKHR{},
    presentModeIndex: u8 = 0,
    activePresentModeIndex: u8 = 0,

    pub const SemaphoreData = struct {
        handle: c.VkSemaphore = null,
        imageIndex: ?u8 = null,
    };
    pub const Self = @This();
    pub const ImageWithSemaphore = struct {
        image: *Image, 
        semaphore: c.VkSemaphore,
        imageIndex: u32,
    };

    pub fn init(gfx: *Gfx, window: ?*c.SDL_Window) !Self {
        var self: Self = .{ .gfx = gfx, .window = window };
        if (!c.SDL_Vulkan_CreateSurface(window, gfx.instance, gfx.allocCB, &self.surface))
            unreachable;

        var numPresentModes: u32 = 0;
        try check(c.vkGetPhysicalDeviceSurfacePresentModesKHR(gfx.physical.handle, self.surface, &numPresentModes, null));
        self.presentModes = try gfx.alloc.alloc(c.VkPresentModeKHR, numPresentModes);
        try check(c.vkGetPhysicalDeviceSurfacePresentModesKHR(gfx.physical.handle, self.surface, &numPresentModes, self.presentModes.ptr));
        self.presentModeIndex = self.getPresentModeIndex(c.VK_PRESENT_MODE_IMMEDIATE_KHR) orelse 0;

        return self;
    }

    fn initSwapchain(self: *Self) !void {
        std.debug.assert(self.handle == null);

        if (!self.isWindowRenderable())
            return;

        var surfaceCaps: c.VkSurfaceCapabilitiesKHR = undefined;
        try check(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.gfx.physical.handle, self.surface, &surfaceCaps));

        if (surfaceCaps.maxImageExtent.width == 0 or surfaceCaps.maxImageExtent.height == 0)
            return;

        self.capabilitiesHasValidExtent = surfaceCaps.currentExtent.width <= surfaceCaps.maxImageExtent.width and surfaceCaps.currentExtent.height <= surfaceCaps.maxImageExtent.height;
        if (!self.capabilitiesHasValidExtent)
            _ = c.SDL_GetWindowSize(self.window, @ptrCast(&surfaceCaps.currentExtent.width), @ptrCast(&surfaceCaps.currentExtent.height));

        const swapchainInfo = c.VkSwapchainCreateInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = self.surface,
            .queueFamilyIndexCount = 1,
            .pQueueFamilyIndices = &[_]u32{@intCast(self.gfx.physical.universalQueueFamily)},
            .presentMode = self.presentModes[self.presentModeIndex],
            .imageFormat = self.gfx.swapchainFormat,
            .imageColorSpace = self.gfx.swapchainColorspace,
            .imageExtent = surfaceCaps.currentExtent,
            .imageArrayLayers = 1,
            .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            .imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .minImageCount = surfaceCaps.minImageCount,
            .preTransform = surfaceCaps.currentTransform,
            .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        };
        try check(c.vkCreateSwapchainKHR(self.gfx.device.handle, &swapchainInfo, self.gfx.allocCB, &self.handle));

        self.activePresentModeIndex = self.presentModeIndex;

        var numImages: u32 = 0;
        try check(c.vkGetSwapchainImagesKHR(self.gfx.device.handle, self.handle, &numImages, null));
        const images = try self.gfx.alloc.alloc(c.VkImage, numImages);
        defer self.gfx.alloc.free(images);
        try check(c.vkGetSwapchainImagesKHR(self.gfx.device.handle, self.handle, &numImages, images.ptr));
        self.images = try self.gfx.alloc.alloc(Image, numImages);
        for (images, 0..) |img, i| {
            const desc = Image.Descriptor{
                .format = swapchainInfo.imageFormat,
                .width = @intCast(swapchainInfo.imageExtent.width),
                .height = @intCast(swapchainInfo.imageExtent.height),
                .usage = Usage{.present = true, .attachmentRead = true, .attachmentWrite = true, .imageRead = true},
            };
            self.images[i] = try Image.initExisting(self.gfx, &desc, img);
        }

        self.semaphores = try self.gfx.alloc.alloc(SemaphoreData, numImages + 1);
        for (self.semaphores) |*sem| {
            sem.* = .{};
            try check(c.vkCreateSemaphore(self.gfx.device.handle, &c.VkSemaphoreCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            }, self.gfx.allocCB, &sem.handle));
        }
        std.debug.assert(self.semaphores.len <= @bitSizeOf(u32));
    }

    fn deinitSwapchain(self: *Self) void {
        if (self.handle == null)
            return;
        for (self.images) |*img| {
            img.deinit();
        }
        for (self.semaphores) |*sem| {
            c.vkDestroySemaphore(self.gfx.device.handle, sem.handle, self.gfx.allocCB);
        }
        self.gfx.alloc.free(self.images);
        self.gfx.alloc.free(self.semaphores);
        c.vkDestroySwapchainKHR(self.gfx.device.handle, self.handle, self.gfx.allocCB);
        self.handle = null;
    }

    pub fn deinit(self: *Self) void {
        self.deinitSwapchain();
        self.gfx.alloc.free(self.presentModes);
        c.SDL_Vulkan_DestroySurface(self.gfx.instance, self.surface, self.gfx.allocCB);
    }

    pub fn recreate(self: *Self) !void {
        self.deinitSwapchain();
        try self.initSwapchain();
    }

    pub fn getPresentModeIndex(self: *Self, mode: c.VkPresentModeKHR) ?u8 {
        for (self.presentModes, 0..) |m, i| {
            if (m == mode)
                return @intCast(i);
        }
        return null;
    }

    pub fn isWindowRenderable(self: *Self) bool {
        const windowFlags = c.SDL_GetWindowFlags(self.window);
        return windowFlags & (c.SDL_WINDOW_OCCLUDED | c.SDL_WINDOW_HIDDEN | c.SDL_WINDOW_MINIMIZED) == 0;
    }

    pub fn isValid(self: *Self) bool {
        if (self.handle == null or !self.isWindowRenderable())
            return false;
        if (self.presentModeIndex != self.activePresentModeIndex)
            return false;
        if (self.capabilitiesHasValidExtent)
            return true;

        var width: i32 = -1;
        var height: i32 = -1;
        _ = c.SDL_GetWindowSize(self.window, &width, &height);

        return width == self.images[0].desc.width and height == self.images[0].desc.height;
    }

    pub fn acquireNextImage(self: *Self) !?ImageWithSemaphore {
        if (self.handle == null)
            return null;
        var semaphoreIndex: u32 = std.math.maxInt(u32);
        for (self.semaphores, 0..) |*sem, i| {
            if (sem.imageIndex == null) {
                semaphoreIndex = @intCast(i);
                break;
            }
        }
        std.debug.assert(semaphoreIndex < self.semaphores.len);
        var imgIndex: u32 = 0;
        check(c.vkAcquireNextImage2KHR(self.gfx.device.handle, &c.VkAcquireNextImageInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_ACQUIRE_NEXT_IMAGE_INFO_KHR,
            .swapchain = self.handle,
            .deviceMask = 1,
            .timeout = std.math.maxInt(u64),
            .semaphore = self.semaphores[semaphoreIndex].handle,
        }, &imgIndex)) catch |err| switch (err) {
            error.vk_suboptimal_khr, error.vk_error_out_of_date_khr => 
                return null,
            else => |anotherErr| 
                return anotherErr,
        };
        for (self.semaphores) |*sem| {
            if (sem.imageIndex == @as(u8, @intCast(imgIndex))) {
                sem.imageIndex = null;
                break;
            }
        }
        self.semaphores[semaphoreIndex].imageIndex = @intCast(imgIndex);
        return .{ 
            .image = &self.images[imgIndex], 
            .semaphore = self.semaphores[semaphoreIndex].handle, 
            .imageIndex = imgIndex, 
        };
    }

    pub fn present(self: *Self, image: *Image, waitSemaphore: c.VkSemaphore) !void {
        const imgIndex = image - self.images.ptr;
        try check(c.vkQueuePresentKHR(self.gfx.device.universalQueue, &c.VkPresentInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .swapchainCount = 1,
            .pSwapchains = &self.handle,
            .pImageIndices = @ptrCast(&imgIndex),
            .waitSemaphoreCount = @intFromBool(waitSemaphore != null),
            .pWaitSemaphores = &[_]c.VkSemaphore{waitSemaphore},
        }));
    }
};

pub const Shader = struct {
    handle: c.VkShaderModule = null,
    filename: [:0]const u8 = "",

    pub const Self = @This();

    pub fn init(gfx: *Gfx, filename: [:0]const u8) !Self {
        var exePathBuf: [std.fs.max_path_bytes]u8 = undefined;
        const exePath = try std.fs.selfExeDirPath(&exePathBuf);
        const relativePath = try std.fs.path.join(gfx.alloc, &.{ exePath, filename });
        defer gfx.alloc.free(relativePath);
        const code = try std.fs.cwd().readFileAllocOptions(gfx.alloc, relativePath, 10 * 1024 * 1024, null, std.mem.Alignment.of(u32), null);
        defer gfx.alloc.free(code);
        std.debug.assert(code.len % 4 == 0);
        var self = try initCode(gfx, @as([*]const u32, @ptrCast(@alignCast(code.ptr)))[0..(code.len)]);
        self.filename = try gfx.alloc.dupeZ(u8, filename);
        return self;
    }

    pub fn initCode(gfx: *Gfx, code: []const u32) !Self {
        var self = Self{};
        try check(c.vkCreateShaderModule(gfx.device.handle, &c.VkShaderModuleCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pCode = code.ptr,
            .codeSize = code.len,
        }, gfx.allocCB, &self.handle));
        return self;
    }

    pub fn deinit(self: *Self, gfx: *Gfx) void {
        gfx.alloc.free(self.filename);
        c.vkDestroyShaderModule(gfx.device.handle, self.handle, gfx.allocCB);
    }
};

pub const Pipeline = struct {
    handle: c.VkPipeline = null,
    name: [:0]const u8 = "",
    kind: Kind,

    pub const Kind = enum {
        Graphics,
        Compute,
    };

    pub const Self = @This();

    pub fn initGraphics(gfx: *Gfx, meshShader: *const Shader, fragShader: *const Shader, name: [:0]const u8) !Self {
        var self = Self{
            .kind = .Graphics,
        };
        var stages = [_]c.VkPipelineShaderStageCreateInfo{
            c.VkPipelineShaderStageCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .stage = c.VK_SHADER_STAGE_MESH_BIT_EXT,
                .module = meshShader.handle,
                .pName = "main",
            },
            c.VkPipelineShaderStageCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
                .module = fragShader.handle,
                .pName = "main",
            },
        };
        var dynStates = [_]c.VkDynamicState{
            c.VK_DYNAMIC_STATE_VIEWPORT,
            c.VK_DYNAMIC_STATE_SCISSOR,
        };
        try check(c.vkCreateGraphicsPipelines(gfx.device.handle, null, 1, &c.VkGraphicsPipelineCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .flags = 0,
            .stageCount = @intCast(stages.len),
            .pStages = &stages,
            .pDynamicState = &c.VkPipelineDynamicStateCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
                .dynamicStateCount = @intCast(dynStates.len),
                .pDynamicStates = &dynStates,
            },
            .pMultisampleState = &c.VkPipelineMultisampleStateCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
                .minSampleShading = 1.0,
                .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
            },
            .pRasterizationState = &c.VkPipelineRasterizationStateCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
                .polygonMode = c.VK_POLYGON_MODE_FILL,
                .lineWidth = 1.0,
                .cullMode = c.VK_CULL_MODE_NONE,
                .frontFace = c.VK_FRONT_FACE_CLOCKWISE,
            },
            .pColorBlendState = &c.VkPipelineColorBlendStateCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
                .attachmentCount = 1,
                .pAttachments = &c.VkPipelineColorBlendAttachmentState{
                    .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
                },
            },
            .pViewportState = &c.VkPipelineViewportStateCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
                .viewportCount = 1,
                .scissorCount = 1,
            },
            .pNext = @constCast(&c.VkPipelineRenderingCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
                .colorAttachmentCount = 1,
                .pColorAttachmentFormats = &gfx.swapchainFormat,
                .pNext = @constCast(&c.VkPipelineCreateFlags2CreateInfo{
                    .sType = c.VK_STRUCTURE_TYPE_PIPELINE_CREATE_FLAGS_2_CREATE_INFO,
                    .flags = c.VK_PIPELINE_CREATE_2_DESCRIPTOR_HEAP_BIT_EXT,
                }),
            }),
        }, gfx.allocCB, &self.handle));
        self.name = try gfx.alloc.dupeZ(u8, name);
        return self;
    }

    pub fn initCompute(gfx: *Gfx, compShader: *const Shader, name: [:0]const u8) !Self {
        var self = Self{
            .kind = .Compute,
        };
        try check(c.vkCreateComputePipelines(gfx.device.handle, null, 1, &c.VkComputePipelineCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            .flags = c.VK_PIPELINE_CREATE_2_DESCRIPTOR_HEAP_BIT_EXT,
            .layout = gfx.pipelineLayout.handle,
            .stage = c.VkPipelineShaderStageCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .stage = c.VK_SHADER_STAGE_COMPUTE_BIT,
                .module = compShader.handle,
                .pName = "main",
            },
        }, gfx.allocCB, &self.handle));
        self.name = try gfx.alloc.dupeZ(u8, name);
        return self;
    }

    pub fn deinit(self: *Self, gfx: *Gfx) void {
        gfx.alloc.free(self.name);
        c.vkDestroyPipeline(gfx.device.handle, self.handle, gfx.allocCB);
    }
};

pub const Usage = packed struct {
    transferSrc: bool = false,
    transferDst: bool = false,
    hostRead: bool = false,
    hostWrite: bool = false,
    imageRead: bool = false,
    storageRead: bool = false,
    storageWrite: bool = false,
    attachmentRead: bool = false,
    attachmentWrite: bool = false,
    samplerHeap: bool = false,
    resourceHeap: bool = false,
    present: bool = false,

    pub const Underlying = @typeInfo(Self).@"struct".backing_integer.?;
    pub const Self = @This();
    pub fn all(val: bool) Self {
        var self: Self = .{};
        inline for (@typeInfo(Self).@"struct".fields) |field| {
            @field(self, field.name) = val;
        }
        return self;
    }

    pub fn And(self: Self, rhs: Self) Self {
        return @bitCast(@as(Underlying, @bitCast(self)) & @as(Underlying, @bitCast(rhs)));
    }
    pub fn Or(self: Self, rhs: Self) Self {
        return @bitCast(@as(Underlying, @bitCast(self)) | @as(Underlying, @bitCast(rhs)));
    }
    pub fn Not(self: Self) Self {
        return @bitCast(~@as(Underlying, @bitCast(self)) & @as(Underlying, @bitCast(all(true))));
    }
};

fn getVmaAllocationCreateFlags(usage: Usage) c.VmaAllocationCreateFlags {
    var allocationFlags: c.VmaAllocationCreateFlags = 0;
    if (usage.hostRead or usage.hostWrite)
        allocationFlags |= c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT | c.VMA_ALLOCATION_CREATE_MAPPED_BIT;
    return allocationFlags;
}

pub const Buffer = struct {
    handle: c.VkBuffer = null,
    allocation: c.VmaAllocation = null,
    deviceAddress: c.VkDeviceAddress = 0,
    hostAddress: ?[*]u8 = null,
    desc: Descriptor,
    gfx: *Gfx,

    pub const Descriptor = struct {
        size: u64 = 0,
        usage: Usage = .{ .storageRead = true, .transferDst = true },
    };

    pub const Self = @This();

    pub fn init(gfx: *Gfx, desc: *const Descriptor, alignment: u64) !Self {
        var self = Buffer{
            .desc = desc.*,
            .gfx = gfx,
        };

        var allocInfo: c.VmaAllocationInfo = undefined;

        const bufferUsage = usageFlags(desc.usage);
        try check(c.vmaCreateBufferWithAlignment(
            gfx.vma, 
            &c.VkBufferCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                .size = desc.size,
                .pNext = &c.VkBufferUsageFlags2CreateInfo{
                    .sType = c.VK_STRUCTURE_TYPE_BUFFER_USAGE_FLAGS_2_CREATE_INFO,
                    .usage = bufferUsage,
                },
            }, 
            &c.VmaAllocationCreateInfo{
                .flags = getVmaAllocationCreateFlags(desc.usage),
                .usage = c.VMA_MEMORY_USAGE_AUTO,
            },
            alignment,
            &self.handle,
            &self.allocation, 
            &allocInfo
        ));

        if ((bufferUsage & c.VK_BUFFER_USAGE_2_SHADER_DEVICE_ADDRESS_BIT) != 0) {
            self.deviceAddress = c.vkGetBufferDeviceAddress(gfx.device.handle, &c.VkBufferDeviceAddressInfo{
                .sType = c.VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO,
                .buffer = self.handle,
            });
            std.debug.assert(self.deviceAddress != 0);
        }
        self.hostAddress = @ptrCast(allocInfo.pMappedData);

        return self;
    }

    pub fn deinit(self: *Self) void {
        c.vmaDestroyBuffer(self.gfx.vma, self.handle, self.allocation);
    }

    pub fn getDeviceAddressRange(self: *const Self) c.VkDeviceAddressRangeEXT {
        return .{
            .address = self.deviceAddress,
            .size = self.desc.size,
        };
    }

    fn writeDescriptorData(self: *const Self, resourceData: *DescriptorHeap.ResourceData, descInfo: *c.VkResourceDescriptorInfoEXT) void {
        resourceData.* = .{ .buffer = self.getDeviceAddressRange() };
        descInfo.* = .{
            .sType = c.VK_STRUCTURE_TYPE_RESOURCE_DESCRIPTOR_INFO_EXT,
            .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .data = .{
                .pAddressRange = &resourceData.buffer
            },
        };
    }

    fn usageFlags(usage: Usage) c.VkBufferUsageFlags2 {
        var bufUsage: c.VkBufferUsageFlags2 = c.VK_BUFFER_USAGE_2_SHADER_DEVICE_ADDRESS_BIT;
        if (usage.samplerHeap or usage.resourceHeap)
            bufUsage |= c.VK_BUFFER_USAGE_2_DESCRIPTOR_HEAP_BIT_EXT;
        if (usage.storageRead or usage.storageWrite)
            bufUsage |= c.VK_BUFFER_USAGE_2_STORAGE_BUFFER_BIT;
        if (usage.transferSrc)
            bufUsage |= c.VK_BUFFER_USAGE_2_TRANSFER_SRC_BIT;
        if (usage.transferDst)
            bufUsage |= c.VK_BUFFER_USAGE_2_TRANSFER_DST_BIT;
        return bufUsage;
    }

    fn accessFlags(usage: Usage) c.VkAccessFlags2 {
        var access: c.VkAccessFlags2 = 0;
        if (usage.storageRead)
            access |= c.VK_ACCESS_2_SHADER_STORAGE_READ_BIT;
        if (usage.storageWrite)
            access |= c.VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT;
        if (usage.transferSrc)
            access |= c.VK_ACCESS_2_TRANSFER_READ_BIT;
        if (usage.transferDst)
            access |= c.VK_ACCESS_2_TRANSFER_WRITE_BIT;
        if (usage.hostRead)
            access |= c.VK_ACCESS_2_HOST_READ_BIT;
        if (usage.hostWrite)
            access |= c.VK_ACCESS_2_HOST_WRITE_BIT;
        if (usage.samplerHeap)
            access |= c.VK_ACCESS_2_SAMPLER_HEAP_READ_BIT_EXT;
        if (usage.resourceHeap)
            access |= c.VK_ACCESS_2_RESOURCE_HEAP_READ_BIT_EXT;

        return access;
    }

    fn stageFlags(usage: Usage, pipelineKind: Pipeline.Kind) c.VkPipelineStageFlags2 {
        var stages: c.VkPipelineStageFlags2 = 0;
        if (usage.transferSrc or usage.transferDst)
            stages |= c.VK_PIPELINE_STAGE_2_TRANSFER_BIT;
        if (usage.storageRead or usage.storageWrite or usage.samplerHeap or usage.resourceHeap) {
            stages |= 
                switch (pipelineKind) {
                    .Graphics => c.VK_PIPELINE_STAGE_2_MESH_SHADER_BIT_EXT | c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
                    .Compute => c.VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT,
                };
        }
        if (usage.hostRead or usage.hostWrite)
            stages |= c.VK_PIPELINE_STAGE_2_HOST_BIT;
        return stages;
    }
};

pub fn isDepthStencilFormat(format: c.VkFormat) bool {
    return switch (format) {
        c.VK_FORMAT_D16_UNORM, 
        c.VK_FORMAT_D16_UNORM_S8_UINT,
        c.VK_FORMAT_D24_UNORM_S8_UINT,
        c.VK_FORMAT_D32_SFLOAT,
        c.VK_FORMAT_D32_SFLOAT_S8_UINT,
        c.VK_FORMAT_X8_D24_UNORM_PACK32 => true,
        else => false,
    };
}

pub fn isStencilFormat(format: c.VkFormat) bool {
    return switch (format) {
        c.VK_FORMAT_S8_UINT,
        c.VK_FORMAT_D16_UNORM_S8_UINT,
        c.VK_FORMAT_D24_UNORM_S8_UINT,
        c.VK_FORMAT_D32_SFLOAT_S8_UINT => true,
        else => false,
    };
}

pub const Image = struct {
    handle: c.VkImage = null,
    allocation: c.VmaAllocation = null,
    view: c.VkImageView = null,
    hostAddress: ?[*]u8 = null,
    desc: Descriptor,
    gfx: *Gfx,

    pub const Descriptor = struct {
        format: c.VkFormat = c.VK_FORMAT_UNDEFINED,
        width: i32 = 1,
        height: i32 = 0,
        depth: i32 = 0,
        mips: i8 = 1,
        usage: Usage = Usage{.imageRead = true, .transferDst = true },

        pub fn extent2D(self: *const @This()) c.VkExtent2D {
            return .{ .width = @intCast(self.width), .height = @intCast(@max(self.height, 1)) };
        }
        pub fn extent3D(self: *const @This()) c.VkExtent3D {
            return .{ .width = @intCast(self.width), .height = @intCast(@max(self.height, 1)), .depth = @intCast(@max(self.depth, 1)) };
        }

        pub fn imageAspect(self: *const @This()) c.VkImageAspectFlags {
            return Image.imageAspect(self.format);
        }
    };

    pub const Self = @This();
    pub fn init(gfx: *Gfx, desc: *const Descriptor) !Self {
        var self = Self{
            .desc = desc.*,
            .gfx = gfx,
        };

        var allocInfo: c.VmaAllocationInfo = undefined;
        const imageFlags: c.VkImageCreateFlags = 0;

        try check(c.vmaCreateImage(
            gfx.vma, 
            &c.VkImageCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
                .flags = imageFlags,
                .imageType = imageType(self.desc.height, self.desc.depth),
                .format = desc.format,
                .extent = desc.extent3D(),
                .mipLevels = @intCast(desc.mips),
                .arrayLayers = if (desc.depth < 0) @intCast(-desc.depth) else 1,
                .samples = c.VK_SAMPLE_COUNT_1_BIT,
                .tiling = 
                    if (desc.usage.hostRead or desc.usage.hostWrite) 
                        c.VK_IMAGE_TILING_LINEAR 
                    else 
                        c.VK_IMAGE_TILING_OPTIMAL,
                .usage = usageFlags(desc.usage, desc.format),
                .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
                .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            },
            &c.VmaAllocationCreateInfo{
                .flags = getVmaAllocationCreateFlags(desc.usage),
                .usage = c.VMA_MEMORY_USAGE_AUTO,
            },
            &self.handle,
            &self.allocation,
            &allocInfo
        ));

        self.hostAddress = @ptrCast(allocInfo.pMappedData);

        if (desc.usage.attachmentRead or desc.usage.attachmentWrite)
            try check(c.vkCreateImageView(gfx.device.handle, &self.viewCreateInfo(), gfx.allocCB, &self.view));

        return self;
    }

    pub fn initExisting(gfx: *Gfx, desc: *const Descriptor, image: c.VkImage) !Image {
        var self = Self{
            .handle = image,
            .desc = desc.*,
            .gfx = gfx,
        };

        if (desc.usage.attachmentRead or desc.usage.attachmentWrite)
            try check(c.vkCreateImageView(gfx.device.handle, &self.viewCreateInfo(), gfx.allocCB, &self.view));

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.view != null)
            c.vkDestroyImageView(self.gfx.device.handle, self.view, self.gfx.allocCB);
        if (self.allocation != null)
            c.vmaDestroyImage(self.gfx.vma, self.handle, self.allocation);
    }

    fn viewCreateInfo(self: *const Self) c.VkImageViewCreateInfo {
        return .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .flags = 0,
            .image = self.handle,
            .viewType = imageViewType(self.desc.height, self.desc.depth),
            .format = self.desc.format,
            .components = .{
                .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = wholeImage(imageAspect(self.desc.format)),
        };
    }

    fn writeDescriptorData(self: *const Self, resourceData: *DescriptorHeap.ResourceData, descInfo: *c.VkResourceDescriptorInfoEXT) void {
        resourceData.* = .{
            .image = .{
                .viewCreateInfo = self.viewCreateInfo(),
                .descInfo = .{
                    .sType = c.VK_STRUCTURE_TYPE_IMAGE_DESCRIPTOR_INFO_EXT,
                    .pView = &resourceData.image.viewCreateInfo,
                    .layout = c.VK_IMAGE_LAYOUT_GENERAL,
                },
            },
        };
        descInfo.* = .{
            .sType = c.VK_STRUCTURE_TYPE_RESOURCE_DESCRIPTOR_INFO_EXT,
            .type = descriptorType(self.desc.usage),
            .data = .{
                .pImage = &resourceData.image.descInfo, 
            },
        };
    }

    fn imageType(height: i32, depth: i32) c.VkImageType {
        return 
            if (depth > 0)
                c.VK_IMAGE_TYPE_3D
            else if (height > 0)
                c.VK_IMAGE_TYPE_2D
            else
                c.VK_IMAGE_TYPE_1D;
    }

    fn imageViewType(height: i32, depth: i32) c.VkImageViewType {
        return 
            if (depth > 0)
                c.VK_IMAGE_VIEW_TYPE_3D
            else if (height > 0) 
                if (depth < 0)
                    c.VK_IMAGE_VIEW_TYPE_2D_ARRAY
                else
                    c.VK_IMAGE_VIEW_TYPE_2D
            else
                if (depth < 0)
                    c.VK_IMAGE_VIEW_TYPE_1D_ARRAY
                else
                    c.VK_IMAGE_VIEW_TYPE_1D;
    }

    fn usageFlags(usage: Usage, format: c.VkFormat) c.VkImageUsageFlags {
        var imgUsage: c.VkImageUsageFlags = 0;
        if (usage.transferSrc)
            imgUsage |= c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        if (usage.transferDst)
            imgUsage |= c.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        if (usage.imageRead)
            imgUsage |= c.VK_IMAGE_USAGE_SAMPLED_BIT;
        if (usage.storageRead or usage.storageWrite)
            imgUsage |= c.VK_IMAGE_USAGE_STORAGE_BIT;
        if (usage.attachmentRead or usage.attachmentWrite)
            imgUsage |= 
                if (isDepthStencilFormat(format)) 
                    c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT 
                else 
                    c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        return imgUsage;
    }

    fn imageAspect(format: c.VkFormat) c.VkImageAspectFlags {
        return 
            if (isDepthStencilFormat(format))
                c.VK_IMAGE_ASPECT_DEPTH_BIT
            else if (isStencilFormat(format))
                c.VK_IMAGE_ASPECT_STENCIL_BIT
            else 
                c.VK_IMAGE_ASPECT_COLOR_BIT;
    }

    fn imageLayout(usage: Usage) c.VkImageLayout {
        return
            if (usage.present)
                c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
            else if (usage == Usage{})
                c.VK_IMAGE_LAYOUT_UNDEFINED
            else
                c.VK_IMAGE_LAYOUT_GENERAL;
    }

    fn descriptorType(usage: Usage) c.VkDescriptorType {
        return 
            if (usage.storageRead or usage.storageWrite)
                c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE
            else if (usage.imageRead)
                c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE
            else if (usage.attachmentRead or usage.attachmentWrite)
                c.VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT
            else
                unreachable;
    }

    fn accessFlags(usage: Usage, format: c.VkFormat) c.VkAccessFlags2 {
        var access: c.VkAccessFlags2 = 0;

        if (usage.imageRead)
            access |= c.VK_ACCESS_2_SHADER_SAMPLED_READ_BIT;
        if (usage.storageRead)
            access |= c.VK_ACCESS_2_SHADER_STORAGE_READ_BIT;
        if (usage.storageWrite)
            access |= c.VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT;
        if (usage.transferSrc or usage.present)
            access |= c.VK_ACCESS_2_TRANSFER_READ_BIT;
        if (usage.transferDst)
            access |= c.VK_ACCESS_2_TRANSFER_WRITE_BIT;
        if (usage.hostRead)
            access |= c.VK_ACCESS_2_HOST_READ_BIT;
        if (usage.hostWrite)
            access |= c.VK_ACCESS_2_HOST_WRITE_BIT;
        if (usage.attachmentRead)
            access |= 
                if (isDepthStencilFormat(format))
                    c.VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT
                else
                    c.VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT;
        if (usage.attachmentWrite)
            access |=
                if (isDepthStencilFormat(format))
                    c.VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT
                else
                    c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT;

        return access;
    }

    fn stageFlags(usage: Usage, format: c.VkFormat, pipelineKind: Pipeline.Kind) c.VkPipelineStageFlags2 {
        var stage: c.VkPipelineStageFlags2 = 0;
        if (usage.transferSrc or usage.transferDst)
            stage |= c.VK_PIPELINE_STAGE_2_TRANSFER_BIT;
        if (usage.present)
            stage |= c.VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT;
        if (usage.imageRead or usage.storageRead or usage.storageWrite)
            stage |= 
                switch (pipelineKind) {
                    .Graphics => c.VK_PIPELINE_STAGE_2_MESH_SHADER_BIT_EXT | c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
                    .Compute => c.VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT,
                };
        if (usage.attachmentRead or usage.attachmentWrite) {
            std.debug.assert(pipelineKind == .Graphics);
            stage |= 
                if (isDepthStencilFormat(format))
                    c.VK_PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT
                else
                    c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
        }
        return stage;
    }
};

pub const Sampler = struct {
    handle: c.VkSampler = null,
    desc: Descriptor,
    gfx: *Gfx,

    pub const Descriptor = struct {
        addressMode: c.VkSamplerAddressMode = c.VK_SAMPLER_ADDRESS_MODE_REPEAT,
        magFilter: c.VkFilter = c.VK_FILTER_LINEAR,
        minFilter: c.VkFilter = c.VK_FILTER_LINEAR,
        mipmapMode: c.VkSamplerMipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR,
        maxAnisotropy: f32 = 0,
    };

    pub const Self = @This();

    pub fn init(gfx: *Gfx, desc: *const Descriptor) !Self {
        var self = Self{
            .desc = desc.*,
            .gfx = gfx
        };

        try check(c.vkCreateSampler(
            gfx.device.handle,
            &createInfo(desc),
            gfx.allocCB,
            &self.handle
        ));

        return self;
    }

    pub fn deinit(self: *Self) void {
        c.vkDestroySampler(self.gfx.device.handle, self.handle, self.gfx.allocCB);
    }

    pub fn createInfo(desc: *const Descriptor) c.VkSamplerCreateInfo {
        return .{
                .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
                .flags = 0,
                .magFilter = desc.magFilter,
                .minFilter = desc.minFilter,
                .mipmapMode = desc.mipmapMode,
                .addressModeU = desc.addressMode,
                .addressModeV = desc.addressMode,
                .addressModeW = desc.addressMode,
                .anisotropyEnable = if (desc.maxAnisotropy > 0) c.VK_TRUE else c.VK_FALSE,
                .maxAnisotropy = desc.maxAnisotropy,
                .minLod = 0,
                .maxLod = c.VK_LOD_CLAMP_NONE,
            };
    }
};

pub const ResourcePtr = union(enum) {
    none: void,
    buffer: *Buffer,
    image: *Image,
};

fn alignToPowerOf2(x: anytype) @TypeOf(x) {
    const T = @TypeOf(x);
    return @as(T, @intCast(1)) << @intCast(@bitSizeOf(T) - @clz(x - 1));
}

pub const DescriptorHeap = struct {
    deviceBuffer: Buffer,
    cpuBuffer: Buffer,
    kind: Kind,
    maxDescriptorSize: u64,
    reservedSize: u64,
    bufferDescriptorsPerSlot: u32,
    imageDescriptorsPerSlot: u32,

    pub const Kind = enum {
        Sampler,
        Resource,
    };

    const Self = @This();

    pub fn init(gfx: *Gfx, kind: Kind, numDescriptors: u64) !Self {
        var maxHeapSize: u64 = undefined;
        var maxDescriptorSize: u64 = undefined;
        var reservedSize: u64 = undefined;
        var maxDescriptorAlignment: u64 = undefined;
        switch (kind) {
            .Sampler => {
                maxDescriptorSize = gfx.physical.descriptorHeapProps.samplerDescriptorSize;
                maxDescriptorAlignment = gfx.physical.descriptorHeapProps.samplerDescriptorAlignment;
                reservedSize = gfx.physical.descriptorHeapProps.minSamplerHeapReservedRange;
                maxHeapSize = gfx.physical.descriptorHeapProps.maxSamplerHeapSize;
            },
            .Resource => {
                maxDescriptorSize = @max(gfx.physical.descriptorHeapProps.bufferDescriptorSize, gfx.physical.descriptorHeapProps.imageDescriptorSize);
                maxDescriptorAlignment = @max(gfx.physical.descriptorHeapProps.bufferDescriptorAlignment, gfx.physical.descriptorHeapProps.imageDescriptorAlignment);
                reservedSize = gfx.physical.descriptorHeapProps.minResourceHeapReservedRange;
                maxHeapSize = gfx.physical.descriptorHeapProps.maxResourceHeapSize;
            },
        }

        std.debug.assert(std.math.isPowerOfTwo(maxDescriptorSize));
        std.debug.assert(std.math.isPowerOfTwo(maxDescriptorAlignment));
        std.debug.assert(reservedSize % maxDescriptorSize == 0);
        const bufferSize = @min(reservedSize + maxDescriptorSize * numDescriptors, maxHeapSize);

        var usage: Usage = switch (kind) {
            .Sampler => .{.samplerHeap = true},
            .Resource => .{.resourceHeap = true},
        };
        usage.transferDst = true;

        const self = Self{
            .deviceBuffer = try Buffer.init(gfx, &.{
                .size = bufferSize,
                .usage = usage,
            }, maxDescriptorAlignment),
            .cpuBuffer = try Buffer.init(gfx, &.{
                .size = bufferSize,
                .usage = Usage{.hostWrite = true, .transferSrc = true},
            }, 0),
            .kind = kind,
            .maxDescriptorSize = maxDescriptorSize,
            .reservedSize = reservedSize,
            .bufferDescriptorsPerSlot = if (kind == .Resource) @intCast(maxDescriptorSize / gfx.physical.descriptorHeapProps.bufferDescriptorSize) else 0,
            .imageDescriptorsPerSlot = if (kind == .Resource) @intCast(maxDescriptorSize / gfx.physical.descriptorHeapProps.imageDescriptorSize) else 0,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.deviceBuffer.deinit();
        self.cpuBuffer.deinit();
    }

    pub fn getNumSlots(self: *const Self) u64 {
        return (self.deviceBuffer.desc.size - self.reservedSize) / self.maxDescriptorSize;
    }

    fn getDescriptorHostAddressRange(self: *const Self, start: u64, num: u64) c.VkHostAddressRangeEXT {
        std.debug.assert(start + num <= self.getNumSlots());
        return .{
            .address = &self.cpuBuffer.hostAddress.?[start * self.maxDescriptorSize],
            .size = num * self.maxDescriptorSize,
        };
    }

    pub fn writeSamplerDescriptors(self: *Self, startIndex: u64, samplerInfos: []const c.VkSamplerCreateInfo) !void {
        std.debug.assert(self.kind == .Sampler);

        const gfx = self.deviceBuffer.gfx;

        var hostAddresses = try gfx.alloc.alloc(c.VkHostAddressRangeEXT, samplerInfos.len);
        defer gfx.alloc.free(hostAddresses);
        for (0..samplerInfos.len) |i| 
            hostAddresses[i] = self.getDescriptorHostAddressRange(startIndex + i, 1);

        try check(gfx.writeSamplerDescriptorsEXT.?(gfx.device.handle, @intCast(samplerInfos.len), samplerInfos.ptr, hostAddresses.ptr));
    }

    const ResourceData = union(enum) {
        image: struct {
            viewCreateInfo: c.VkImageViewCreateInfo,
            descInfo: c.VkImageDescriptorInfoEXT,
        },
        buffer: c.VkDeviceAddressRangeEXT,
    };

    pub fn writeResourceDescriptors(self: *Self, startSlot: u64, resources: []const ResourcePtr) !void {
        std.debug.assert(self.kind == .Resource);
        
        const gfx = self.deviceBuffer.gfx;

        var hostAddresses = try gfx.alloc.alloc(c.VkHostAddressRangeEXT, resources.len);
        defer gfx.alloc.free(hostAddresses);

        var resourceDescData = try gfx.alloc.alloc(ResourceData, resources.len);
        defer gfx.alloc.free(resourceDescData);
        var resourceDescInfos = try gfx.alloc.alloc(c.VkResourceDescriptorInfoEXT, resources.len);
        defer gfx.alloc.free(resourceDescInfos);

        for (0..resources.len) |i| {
            hostAddresses[i] = self.getDescriptorHostAddressRange(startSlot + i, 1);
            switch (resources[i]) {
                .buffer => |buf| {
                    buf.writeDescriptorData(&resourceDescData[i], &resourceDescInfos[i]);
                },
                .image => |img| {
                    img.writeDescriptorData(&resourceDescData[i], &resourceDescInfos[i]);
                },
                else => unreachable,
            }
        }

        try check(gfx.writeResourceDescriptorsEXT.?(gfx.device.handle, @intCast(resources.len), resourceDescInfos.ptr, hostAddresses.ptr));        
    }
};

fn deviceTypePriority(t: c.VkPhysicalDeviceType) !i32 {
    return switch (t) {
        c.VK_PHYSICAL_DEVICE_TYPE_CPU => 0,
        c.VK_PHYSICAL_DEVICE_TYPE_OTHER => 1,
        c.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => 2,
        c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => 3,
        c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => 4,
        else => error.unknown_physical_device_type,
    };
}

pub fn wholeImage(aspectMask: c.VkImageAspectFlags) c.VkImageSubresourceRange {
    return .{
        .aspectMask = aspectMask,
        .baseArrayLayer = 0,
        .layerCount = c.VK_REMAINING_ARRAY_LAYERS,
        .baseMipLevel = 0,
        .levelCount = c.VK_REMAINING_MIP_LEVELS,
    };
}

pub fn check(result: c.VkResult) !void {
    return switch (result) {
        c.VK_SUCCESS => {},
        c.VK_NOT_READY => error.vk_not_ready,
        c.VK_TIMEOUT => error.vk_timeout,
        c.VK_EVENT_SET => error.vk_event_set,
        c.VK_EVENT_RESET => error.vk_event_reset,
        c.VK_INCOMPLETE => error.vk_incomplete,
        c.VK_ERROR_OUT_OF_HOST_MEMORY => error.vk_error_out_of_host_memory,
        c.VK_ERROR_OUT_OF_DEVICE_MEMORY => error.vk_error_out_of_device_memory,
        c.VK_ERROR_INITIALIZATION_FAILED => error.vk_error_initialization_failed,
        c.VK_ERROR_DEVICE_LOST => error.vk_error_device_lost,
        c.VK_ERROR_MEMORY_MAP_FAILED => error.vk_error_memory_map_failed,
        c.VK_ERROR_LAYER_NOT_PRESENT => error.vk_error_layer_not_present,
        c.VK_ERROR_EXTENSION_NOT_PRESENT => error.vk_error_extension_not_present,
        c.VK_ERROR_FEATURE_NOT_PRESENT => error.vk_error_feature_not_present,
        c.VK_ERROR_INCOMPATIBLE_DRIVER => error.vk_error_incompatible_driver,
        c.VK_ERROR_TOO_MANY_OBJECTS => error.vk_error_too_many_objects,
        c.VK_ERROR_FORMAT_NOT_SUPPORTED => error.vk_error_format_not_supported,
        c.VK_ERROR_FRAGMENTED_POOL => error.vk_error_fragmented_pool,
        c.VK_ERROR_UNKNOWN => error.vk_error_unknown,
        c.VK_ERROR_OUT_OF_POOL_MEMORY => error.vk_error_out_of_pool_memory,
        c.VK_ERROR_INVALID_EXTERNAL_HANDLE => error.vk_error_invalid_external_handle,
        c.VK_ERROR_FRAGMENTATION => error.vk_error_fragmentation,
        c.VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS => error.vk_error_invalid_opaque_capture_address,
        c.VK_PIPELINE_COMPILE_REQUIRED => error.vk_pipeline_compile_required,
        c.VK_ERROR_SURFACE_LOST_KHR => error.vk_error_surface_lost_khr,
        c.VK_ERROR_NATIVE_WINDOW_IN_USE_KHR => error.vk_error_native_window_in_use_khr,
        c.VK_SUBOPTIMAL_KHR => error.vk_suboptimal_khr,
        c.VK_ERROR_OUT_OF_DATE_KHR => error.vk_error_out_of_date_khr,
        c.VK_ERROR_INCOMPATIBLE_DISPLAY_KHR => error.vk_error_incompatible_display_khr,
        c.VK_ERROR_VALIDATION_FAILED_EXT => error.vk_error_validation_failed_ext,
        c.VK_ERROR_INVALID_SHADER_NV => error.vk_error_invalid_shader_nv,
        c.VK_ERROR_IMAGE_USAGE_NOT_SUPPORTED_KHR => error.vk_error_image_usage_not_supported_khr,
        c.VK_ERROR_VIDEO_PICTURE_LAYOUT_NOT_SUPPORTED_KHR => error.vk_error_video_picture_layout_not_supported_khr,
        c.VK_ERROR_VIDEO_PROFILE_OPERATION_NOT_SUPPORTED_KHR => error.vk_error_video_profile_operation_not_supported_khr,
        c.VK_ERROR_VIDEO_PROFILE_FORMAT_NOT_SUPPORTED_KHR => error.vk_error_video_profile_format_not_supported_khr,
        c.VK_ERROR_VIDEO_PROFILE_CODEC_NOT_SUPPORTED_KHR => error.vk_error_video_profile_codec_not_supported_khr,
        c.VK_ERROR_VIDEO_STD_VERSION_NOT_SUPPORTED_KHR => error.vk_error_video_std_version_not_supported_khr,
        c.VK_ERROR_INVALID_DRM_FORMAT_MODIFIER_PLANE_LAYOUT_EXT => error.vk_error_invalid_drm_format_modifier_plane_layout_ext,
        c.VK_ERROR_NOT_PERMITTED_KHR => error.vk_error_not_permitted_khr,
        c.VK_ERROR_FULL_SCREEN_EXCLUSIVE_MODE_LOST_EXT => error.vk_error_full_screen_exclusive_mode_lost_ext,
        c.VK_THREAD_IDLE_KHR => error.vk_thread_idle_khr,
        c.VK_THREAD_DONE_KHR => error.vk_thread_done_khr,
        c.VK_OPERATION_DEFERRED_KHR => error.vk_operation_deferred_khr,
        c.VK_OPERATION_NOT_DEFERRED_KHR => error.vk_operation_not_deferred_khr,
        c.VK_ERROR_COMPRESSION_EXHAUSTED_EXT => error.vk_error_compression_exhausted_ext,
        c.VK_ERROR_INCOMPATIBLE_SHADER_BINARY_EXT => error.vk_error_incompatible_shader_binary_ext,
        else => error.vk_error_unknown,
    };
}

/// Converts the return value of an SDL function to an error union.
pub fn sdl_errify(value: anytype) error{SdlError}!switch (@typeInfo(@TypeOf(value))) {
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
