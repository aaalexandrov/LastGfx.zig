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
    }

    pub fn deinit(self: *Self) void {
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

    pub const PhysicalDevice = struct {
        handle: c.VkPhysicalDevice = null,
        props: c.VkPhysicalDeviceProperties,
        universalQueueFamily: i32 = -1,

        fn init(instance: c.VkInstance, physDev: c.VkPhysicalDevice, alloc: std.mem.Allocator) PhysicalDevice {
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

    pub fn selectPhysicalDevice(self: *Self) !PhysicalDevice {
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
