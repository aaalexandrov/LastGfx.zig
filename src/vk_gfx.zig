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

    pub const API_VERSION = c.VK_API_VERSION_1_4;
    pub const Self = @This();

    pub fn init(self: *Self, allocator: std.mem.Allocator, debug: bool) !void {
        self.alloc = allocator;
        self.allocCB = null;

        var layers = std.ArrayList([*c]const u8).init(self.alloc);
        defer layers.deinit();

        var exts = std.ArrayList([*c]const u8).init(self.alloc);
        defer exts.deinit();

        var sdlExtCount: u32 = 0;
        const sdlExts = c.SDL_Vulkan_GetInstanceExtensions(&sdlExtCount);
        for (0..sdlExtCount) |e| {
            try exts.append(sdlExts[e]);
        }

        var dbgMessengerInfo = c.VkDebugUtilsMessengerCreateInfoEXT{
            .sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .messageSeverity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            .messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
            .pfnUserCallback = &DebugCallback,
            .pUserData = self,
        };
        if (debug) {
            try layers.append("VK_LAYER_KHRONOS_validation");
            try exts.append(c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME);
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
        try check_vk(c.vkCreateInstance(&instInfo, self.allocCB, &self.instance));

        self.dbgMessenger = null;
        if (debug) {
            const vkCreateDebugUtilsMessengerEXT = self.getInstanceProcAddress(c.PFN_vkCreateDebugUtilsMessengerEXT, "vkCreateDebugUtilsMessengerEXT");
            if (vkCreateDebugUtilsMessengerEXT) |func| {
                try check_vk(func(self.instance, &dbgMessengerInfo, self.allocCB, &self.dbgMessenger));
            } else {
                return error.function_not_found;
            }
        }

        self.physical = try self.selectPhysicalDevice();
        std.log.info("GPU: {s}, Vulkan ver.{}.{}.{}.{}\n", .{
            self.physical.props.deviceName,
            c.VK_API_VERSION_VARIANT(self.physical.props.apiVersion),
            c.VK_API_VERSION_MAJOR(self.physical.props.apiVersion),
            c.VK_API_VERSION_MINOR(self.physical.props.apiVersion),
            c.VK_API_VERSION_PATCH(self.physical.props.apiVersion),
        });

        self.device = try self.createDevice();
    }

    pub fn deinit(self: *Self) void {
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
        try check_vk(c.vkEnumeratePhysicalDevices(self.instance, &numDevices, null));

        var devices = std.ArrayList(c.VkPhysicalDevice).init(self.alloc);
        defer devices.deinit();
        try devices.resize(numDevices);

        try check_vk(c.vkEnumeratePhysicalDevices(self.instance, &numDevices, devices.items.ptr));

        var bestProps: ?PhysicalDevice = null;

        for (devices.items) |device| {
            const devProps = PhysicalDevice.init(self.instance, device, self.alloc);
            if (devProps.props.apiVersion < API_VERSION)
                continue;
            if (devProps.universalQueueFamily < 0)
                continue;
            if (bestProps) |best| {
                if ((try deviceTypePriority(devProps.props.deviceType)) <= (try deviceTypePriority(best.props.deviceType)))
                    continue;
            }
            bestProps = devProps;
        }

        return bestProps.?;
    }

    fn createDevice(self: *Self) !Device {
        var device: Device = undefined;
        const exts = [_][*c]const u8{
            "VK_KHR_swapchain",
        };
        try check_vk(c.vkCreateDevice(self.physical.handle, &c.VkDeviceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &c.VkDeviceQueueCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .queueFamilyIndex = @intCast(self.physical.universalQueueFamily),
                .queueCount = 1,
                .pQueuePriorities = &[_]f32{0},
            },
            .enabledExtensionCount = @intCast(exts.len),
            .ppEnabledExtensionNames = &exts,
        }, self.allocCB, &device.handle));
        c.vkGetDeviceQueue(device.handle, @intCast(self.physical.universalQueueFamily), 0, &device.universalQueue);
        std.debug.assert(device.universalQueue != null);
        return device;
    }

    const ImageViewOpts = struct {
        image: c.VkImage,
        format: c.VkFormat,
        flags: c.VkImageViewCreateFlags = 0,
        viewType: c.VkImageViewType = c.VK_IMAGE_VIEW_TYPE_2D,
        components: c.VkComponentMapping = .{
            .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
        },
        subresourceRange: c.VkImageSubresourceRange = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseArrayLayer = 0,
            .layerCount = c.VK_REMAINING_ARRAY_LAYERS,
            .baseMipLevel = 0,
            .levelCount = c.VK_REMAINING_MIP_LEVELS,
        },
    };
    fn createImageView(self: *Self, opts: ImageViewOpts) !c.VkImageView {
            var view: c.VkImageView = null;
            try check_vk(c.vkCreateImageView(
                self.device.handle, 
                &c.VkImageViewCreateInfo{
                    .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                    .flags = opts.flags,
                    .image = opts.image,
                    .viewType = opts.viewType,
                    .format = opts.format,
                    .components = opts.components,
                    .subresourceRange = opts.subresourceRange,
                }, 
                self.allocCB, 
                &view
            ));
            return view;
    }
};

pub const PhysicalDevice = struct {
    handle: c.VkPhysicalDevice = null,
    props: c.VkPhysicalDeviceProperties,
    universalQueueFamily: i32 = -1,

    pub const Self = @This();
    fn init(instance: c.VkInstance, physDev: c.VkPhysicalDevice, alloc: std.mem.Allocator) Self {
        var phys: PhysicalDevice = undefined;
        phys.handle = physDev;
        c.vkGetPhysicalDeviceProperties(physDev, &phys.props);
        phys.universalQueueFamily = -1;

        var numQueueFamilies: u32 = 0;
        c.vkGetPhysicalDeviceQueueFamilyProperties(physDev, &numQueueFamilies, null);
        var queues = std.ArrayList(c.VkQueueFamilyProperties).init(alloc);
        defer queues.deinit();
        queues.resize(numQueueFamilies) catch @panic("OOM");
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
};

pub const Device = struct {
    handle: c.VkDevice,
    universalQueue: c.VkQueue,
};

pub const Commands = struct {
    handle: c.VkCommandBuffer = null,
    pool: c.VkCommandPool = null,
    fence: c.VkFence = null,
    gfx: *Gfx,

    pub const Self = @This();
    pub fn init(gfx: *Gfx) !Self {
        var self: Self = .{.gfx = gfx};
        try check_vk(c.vkCreateCommandPool(
            gfx.device.handle, 
            &c.VkCommandPoolCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
                .queueFamilyIndex = @intCast(gfx.physical.universalQueueFamily),
            }, 
            gfx.allocCB, 
            &self.pool
        ));
        try check_vk(c.vkAllocateCommandBuffers(
            gfx.device.handle, 
            &c.VkCommandBufferAllocateInfo{
                .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                .commandPool = self.pool,
                .commandBufferCount = 1,
                .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            }, 
            &self.handle
        ));
        try check_vk(c.vkCreateFence(
            gfx.device.handle, 
            &c.VkFenceCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
                .flags = 0,
            }, 
            gfx.allocCB, 
            &self.fence
        ));
        return self;
    }

    pub fn deinit(self: *Self) void {
        c.vkDestroyFence(self.gfx.device.handle, self.fence, self.gfx.allocCB);
        c.vkFreeCommandBuffers(self.gfx.device.handle, self.pool, 1, &self.handle);
        c.vkDestroyCommandPool(self.gfx.device.handle, self.pool, self.gfx.allocCB);
    }

    pub fn begin(self: *Self) !void {
        try check_vk(c.vkBeginCommandBuffer(
            self.handle, 
            &c.VkCommandBufferBeginInfo{
                .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                .flags = 0,
            }
        ));
    }

    pub fn end(self: *Self) !void {
        try check_vk(c.vkEndCommandBuffer(self.handle));
    }

    pub fn submit(self: *Self) !void {
        try check_vk(c.vkQueueSubmit2(
            self.gfx.device.universalQueue,
            1, 
            &c.VkSubmitInfo2{
                .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
            },
            self.fence
        ));
    }
};

pub const Swapchain = struct {
    handle: c.VkSwapchainKHR = null,
    surface: c.VkSurfaceKHR = null,
    images: []Image = &.{},
    semaphores: []c.VkSemaphore = &.{},
    semaphoreIndex: u32 = 0,
    gfx: *Gfx,

    pub const Self = @This();

    pub fn init(gfx: *Gfx, window: ?*c.SDL_Window) !Self {
        var self: Self = .{.gfx = gfx};
        if (!c.SDL_Vulkan_CreateSurface(window, gfx.instance, gfx.allocCB, &self.surface))
            unreachable;

        var surfaceCaps: c.VkSurfaceCapabilitiesKHR = undefined;
        try check_vk(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(gfx.physical.handle, self.surface, &surfaceCaps));

        if (surfaceCaps.currentExtent.width > surfaceCaps.maxImageExtent.width or surfaceCaps.currentExtent.height > surfaceCaps.maxImageExtent.height)
            _ = c.SDL_GetWindowSize(window, @ptrCast(&surfaceCaps.currentExtent.width), @ptrCast(&surfaceCaps.currentExtent.height));

        const swapchainInfo =c.VkSwapchainCreateInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = self.surface,
            .queueFamilyIndexCount = 1,
            .pQueueFamilyIndices = &[_]u32{@intCast(gfx.physical.universalQueueFamily)},
            .presentMode = c.VK_PRESENT_MODE_FIFO_KHR,
            .imageFormat = c.VK_FORMAT_B8G8R8A8_SRGB,
            .imageColorSpace = c.VK_COLORSPACE_SRGB_NONLINEAR_KHR,
            .imageExtent = surfaceCaps.currentExtent,
            .imageArrayLayers = 1,
            .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            .imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .minImageCount = surfaceCaps.minImageCount,
            .preTransform = surfaceCaps.currentTransform,
            .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        };
        try check_vk(c.vkCreateSwapchainKHR(gfx.device.handle, &swapchainInfo, gfx.allocCB, &self.handle));

        var numImages: u32 = 0;
        try check_vk(c.vkGetSwapchainImagesKHR(gfx.device.handle, self.handle, &numImages, null));
        const images = try gfx.alloc.alloc(c.VkImage, numImages);
        defer gfx.alloc.free(images);
        try check_vk(c.vkGetSwapchainImagesKHR(gfx.device.handle, self.handle, &numImages, images.ptr));
        self.images = try gfx.alloc.alloc(Image, numImages);
        self.semaphores = try gfx.alloc.alloc(c.VkSemaphore, numImages);
        for (images, 0..) |img, i| {
            const view = try gfx.createImageView(.{.image = img, .format = swapchainInfo.imageFormat});
            self.images[i] = try Image.init(gfx, img, view, false);
            try check_vk(c.vkCreateSemaphore(
                gfx.device.handle, 
                &c.VkSemaphoreCreateInfo{
                    .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
                }, 
                gfx.allocCB, 
                &self.semaphores[i]
            ));
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.images, self.semaphores) |*img, sem| {
            img.deinit();
            c.vkDestroySemaphore(self.gfx.device.handle, sem, self.gfx.allocCB);
        }
        self.gfx.alloc.free(self.images);
        self.gfx.alloc.free(self.semaphores);
        c.vkDestroySwapchainKHR(self.gfx.device.handle, self.handle, self.gfx.allocCB);
        c.SDL_Vulkan_DestroySurface(self.gfx.instance, self.surface, self.gfx.allocCB);
    }

    pub fn acquireNextImage(self: *Self) !struct { image: *Image, semaphore: c.VkSemaphore } {
        self.semaphoreIndex = @rem(self.semaphoreIndex + 1, @as(u32, @intCast(self.semaphores.len)));
        var imgIndex: u32 = 0;
        try check_vk(c.vkAcquireNextImage2KHR(
            self.gfx.device.handle, 
            &c.VkAcquireNextImageInfoKHR{
                .sType = c.VK_STRUCTURE_TYPE_ACQUIRE_NEXT_IMAGE_INFO_KHR,
                .swapchain = self.handle,
                .deviceMask = 1,
                .timeout = std.math.maxInt(u64),
                .semaphore = self.semaphores[self.semaphoreIndex],
            }, 
            &imgIndex
        ));
        return .{.image = &self.images[imgIndex], .semaphore = self.semaphores[self.semaphoreIndex]};
    }

    pub fn present(self: *Self, image: *Image) !void {
        const imgIndex = image - self.images.ptr;
        try check_vk(c.vkQueuePresentKHR(
            self.gfx.device.universalQueue,
            &c.VkPresentInfoKHR{
                .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
                .swapchainCount = 1,
                .pSwapchains = &self.handle,
                .pImageIndices = @ptrCast(&imgIndex),
            }
        ));
    }
};

pub const Image = struct {
    handle: c.VkImage = null,
    view: c.VkImageView = null,
    ownImage: bool = true,
    gfx: *Gfx,

    pub const Self = @This();
    pub fn init(gfx: *Gfx, image: c.VkImage, view: c.VkImageView, ownImage: bool) !Image {
        const img: Image = .{
            .handle = image,
            .view = view,
            .ownImage = ownImage,
            .gfx = gfx,
        };

        return img;
    }

    pub fn deinit(self: *Self) void {
        c.vkDestroyImageView(self.gfx.device.handle, self.view, self.gfx.allocCB);
        if (self.ownImage)
            c.vkDestroyImage(self.gfx.device.handle, self.handle, self.gfx.allocCB);
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

pub fn check_vk(result: c.VkResult) !void {
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
