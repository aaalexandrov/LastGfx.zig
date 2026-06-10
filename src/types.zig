const std = @import("std");

pub const NamedMetadata = struct {
    map: MetadataMap = .{},

    pub const MetadataValue = AnyValue(2 * @sizeOf([*]u8), @alignOf([*]u8));
    pub const MetadataMap = std.StringHashMapUnmanaged(MetadataValue);
    pub const Self = @This();

    pub fn deinit(self: *Self, registry: *TypeRegistry) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            registry.alloc.free(entry.key_ptr.*);
            entry.value_ptr.deinit(registry);
        }
        self.map.deinit(registry.alloc);
    }

    pub fn add(self: *Self, name: []const u8, typeInfo: *const TypeInfo, value: ?[*]const u8, registry: *TypeRegistry) !*MetadataValue {
        const result = try self.map.getOrPut(registry.alloc, name);
        if (result.found_existing)
            return error.AlreadyExists;
        result.key_ptr.* = try registry.alloc.dupe(u8, name);
        try result.value_ptr.*.init(typeInfo, registry.alloc, value);
        return result.value_ptr;
    }

    pub fn addT(self: *Self, comptime T: type, name: []const u8, value: ?*const T, registry: *TypeRegistry) !*MetadataValue {
        return try self.add(name, try registry.get(T), @ptrCast(value orelse null), registry);
    }

    pub fn addDeinitMethod(self: *Self, fnDeinit: anytype, registry: *TypeRegistry) !void {
        const deinitParams = @typeInfo(@TypeOf(fnDeinit)).@"fn".params;
        //const T: type = @typeInfo(deinitParams[0].type.?).pointer.child;

        const deiniterT = struct {
            fn deinitSelf(ptr: [*]u8, _: *TypeRegistry) void {
                return fnDeinit(@alignCast(@ptrCast(ptr)));
            }
            fn deinitSelfAlloc(ptr: [*]u8, registry_: *TypeRegistry) void {
                return fnDeinit(@alignCast(@ptrCast(ptr)), registry_.alloc);
            }
        };

        const deinitMethod: TypeInfo.DeinitFn = if (comptime deinitParams.len == 1)
                deiniterT.deinitSelf
            else if (comptime deinitParams.len == 2)
                deiniterT.deinitSelfAlloc;
        _ = try self.addT(TypeInfo.DeinitFn, TypeInfo.DeinitFnName, &deinitMethod, registry);
    }

    pub fn addDeinitForType(self: *Self, comptime T: type, registry: *TypeRegistry) !void {
        const fnDeinit = @field(T, "deinit");
        return try addDeinitMethod(self, fnDeinit, registry);
    }

    pub fn contains(self: *const Self, name: []const u8) bool {
        return self.map.contains(name);
    }

    pub fn get(self: *const Self, name: []const u8) ?AnyPtr {
        const entry = self.map.getEntry(name);
        return if (entry) |ent|
                ent.value_ptr.*.ptr()
            else
                null;
    }
};

pub const TypeInfo = struct {
    name: []const u8,
    size: usize,
    alignment: usize,
    metadata: NamedMetadata,
    info: Info,

    pub const Info = union(enum) {
        Basic: void,
        Array: struct {
            length: usize,
            elementType: *const TypeInfo,
        },
        Struct: struct {
            members: []const Member,
        },
        Pointer: struct {
            pointedType: *const TypeInfo,
        },
        Fn: struct {
            returnType: *const TypeInfo,
            paramTypes: []*const TypeInfo,
        },

        fn deinit(self: *@This(), registry: *TypeRegistry) void {
            switch (self.*) {
                .Struct => |str| {
                    for (str.members) |*member|
                        @as(*Member, @constCast(member)).deinit(registry);
                    registry.alloc.free(str.members);
                },
                .Fn => |func| {
                    registry.alloc.free(func.paramTypes);
                },
                else => {},
            }
        }
    };

    pub const Member = struct {
        name: []const u8,
        offset: usize,
        typeInfo: *const TypeInfo,
        metadata: NamedMetadata,

        fn deinit(self: *@This(), registry: *TypeRegistry) void {
            registry.alloc.free(self.name);
            self.metadata.deinit(registry);
        }
    };

    pub const DeinitFn = *const fn (value: [*]u8, registry: *TypeRegistry) void;
    pub const DeinitFnName: []const u8 = "#deinit";

    pub const Self = @This();

    fn initEmpty(self: *Self, name: []const u8) !void {
        self.name = name;
        self.size = 0;
        self.alignment = 0;
        self.metadata = .{};
        self.info = .Basic;
    }

    fn initType(self: *Self, registry: *TypeRegistry, name: []const u8, comptime T: type) !void {
        self.name = name;
        self.size = switch (@typeInfo(T)) {
            .@"fn", .@"opaque" => 0,
            else => @sizeOf(T),
        };
        self.alignment = switch (@typeInfo(T)) {
            .@"opaque" => 0,
            else => @alignOf(T),
        };
        self.metadata = .{};
        self.info = switch (@typeInfo(T)) {
            .array => |arr| .{ .Array = .{
                .length = arr.len,
                .elementType = try registry.get(arr.child),
            } },
            .@"struct" => |str| blk: {
                var members = try registry.alloc.alloc(Member, str.fields.len);
                inline for (0..str.fields.len) |i| {
                    members[i] = .{
                        .name = try registry.alloc.dupe(u8, str.fields[i].name),
                        .offset = @offsetOf(T, str.fields[i].name),
                        .typeInfo = try registry.get(str.fields[i].type),
                        .metadata = .{},
                    };
                }
                break :blk .{ .Struct = .{ .members = members } };
            },
            .pointer => |ptr| .{ .Pointer = .{
                .pointedType = try registry.get(ptr.child),
            } },
            .@"fn" => |func| blk: {
                var params = try registry.alloc.alloc(*const TypeInfo, func.params.len);
                inline for (0..func.params.len) |i| {
                    params[i] = try registry.get(func.params[i].type.?);
                }
                break :blk .{.Fn = .{
                    .returnType = try registry.get(func.return_type.?), 
                    .paramTypes = params,
                }};
            },
            else => .Basic,
        };
    }

    fn deinit(self: *Self, registry: *TypeRegistry) void {
        self.metadata.deinit(registry);
        self.info.deinit(registry);
    }

    pub fn getMember(self: *const Self, name: []const u8) ?*const Member {
        switch (self.info) {
            .Struct => |str| {
                for (str.members) |*member| {
                    if (std.mem.eql(u8, name, member.name))
                        return member;
                }
            },
            else => {},
        }
        return null;
    }

    pub fn dump(self: *const Self, depth: u32) void {
        const maxDepth = 16;
        if (depth > maxDepth)
            return;
        const whitespace = (" " ** (2 * (maxDepth + 1)));
        std.log.info("{s}Type {s}, size: {}, align: {}, kind: {s}", .{ whitespace[0 .. depth * 2], self.name, self.size, self.alignment, @tagName(self.info) });
        switch (self.info) {
            .Array => |arr| {
                std.log.info("{s}len: {}", .{ whitespace[0 .. (depth + 1) * 2], arr.length });
                arr.elementType.dump(depth + 2);
            },
            .Pointer => |ptr| {
                ptr.pointedType.dump(depth + 1);
            },
            .Struct => |str| {
                for (str.members) |*member| {
                    std.log.info("{s}member name: {s}, offset: {}", .{ whitespace[0 .. (depth + 1) * 2], member.name, member.offset });
                    member.typeInfo.dump(depth + 2);
                }
            },
            .Fn => |func| {
                std.log.info("{s}return type: ", .{ whitespace[0 .. (depth + 1) * 2] });
                func.returnType.dump(depth + 2);
                std.log.info("{s}param types: ", .{ whitespace[0 .. (depth + 1) * 2] });
                for (func.paramTypes) |paramType| {
                    paramType.dump(depth + 2);
                }
            },
            .Basic => {},
        }
    }
};

pub const TypeRegistry = struct {
    alloc: std.mem.Allocator,
    types: TypeInfoMap,

    const TypeInfoMap = std.array_hash_map.String(*TypeInfo);

    pub const Self = @This();

    pub fn init(alloc: std.mem.Allocator) !Self {
        return Self{
            .alloc = alloc,
            .types = try TypeInfoMap.init(alloc, &.{}, &.{}),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.types.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self);
            self.alloc.free(entry.key_ptr.*);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.types.deinit(self.alloc);
    }

    pub fn find(self: *Self, name: []const u8) ?*TypeInfo {
        return self.types.get(name);
    }

    pub fn get(self: *Self, comptime T: type) error{OutOfMemory}!*const TypeInfo {
        const entry = try self.types.getOrPut(self.alloc, @typeName(T));
        if (entry.found_existing)
            return entry.value_ptr.*;
        entry.key_ptr.* = try self.alloc.dupe(u8, @typeName(T));
        const typeInfo = try self.alloc.create(TypeInfo);
        entry.value_ptr.* = typeInfo;
        // initType can cause the hash map to reallocate, invalidating the entry, so we can't use it below this call
        try typeInfo.initType(self, entry.key_ptr.*, T);
        return typeInfo;
    }

    pub fn getNew(self: *Self, name: []const u8) error{ OutOfMemory, TypeAlreadyExists }!*TypeInfo {
        const entry = try self.types.getOrPut(self.alloc, name);
        if (entry.found_existing)
            return error.TypeAlreadyExists;
        entry.key_ptr.* = try self.alloc.dupe(u8, name);
        entry.value_ptr.* = try self.alloc.create(TypeInfo);
        try entry.value_ptr.*.initEmpty(entry.key_ptr.*);
        return entry.value_ptr.*;
    }
};

pub const AnyPtr = struct {
    typeInfo: *const TypeInfo,
    ptr: [*]u8,

    pub const Self = @This();
    pub fn init(typeInfo: *const TypeInfo, ptr: [*]u8) Self {
        return Self{
            .typeInfo = typeInfo,
            .ptr = ptr,
        };
    }

    pub fn initT(T: type, registry: *TypeRegistry, obj: *T) !Self {
        return Self{
            .typeInfo = try registry.get(T),
            .ptr = @ptrCast(obj),
        };
    }

    pub fn slice(self: *const Self) []u8 {
        return self.ptr[0..self.typeInfo.size];
    }

    pub fn get(self: *const Self, typeInfo: *const TypeInfo) ?[*]u8 {
        return if (typeInfo == self.typeInfo)
            self.ptr
        else
            null;
    }

    pub fn getT(self: *const Self, T: type) ?*T {
        return if (std.mem.eql(u8, @typeName(T), self.typeInfo.name))
            @ptrCast(@alignCast(self.ptr))
        else
            null;
    }

    pub fn dereference(self: *const Self) ?Self {
        if (self.ptr != null and self.typeInfo.info == .Pointer) {
            return .{
                .typeInfo = self.typeInfo.info.Pointer.pointedType,
                .ptr = std.mem.bytesToValue([*]u8, self.ptr[0..@sizeOf([*]u8)]),
            };
        }
        return null;
    }

    pub fn deinitValue(self: *const Self, registry: *TypeRegistry) bool {
        const deinitPtr = self.typeInfo.metadata.get(TypeInfo.DeinitFnName) orelse return false;
        const deinitFn = (deinitPtr.getT(TypeInfo.DeinitFn) orelse return false).*;
        deinitFn(self.ptr, registry);
        return true;
    }

    pub fn getMember(self: *const Self, name: []const u8) ?Self {
        if (self.typeInfo.getMember(name)) |member| {
            return Self{
                .typeInfo = member.typeInfo,
                .ptr = self.ptr + member.offset,
            };
        }
        return null;
    }

    pub fn getArrayLen(self: *const Self) ?usize {
        switch (self.typeInfo.info) {
            .Array => |arr| return arr.length,
            else => {},
        }
        return null;
    }

    pub fn getArrayElement(self: *const Self, n: usize) ?Self {
        switch (self.typeInfo.info) {
            .Array => |arr| {
                if (n < arr.length) {
                    return Self{
                        .typeInfo = arr.elementType,
                        .ptr = self.ptr + n * arr.elementType.size,
                    };
                }
            },
            else => {},
        }
        return null;
    }
};

pub fn AnyValue(comptime size: usize, comptime alignment: usize) type {
    comptime if (size < @sizeOf([*]u8)) 
        unreachable;
    comptime if (alignment < @alignOf([*]u8))
        unreachable;
    return struct {
        typeInfo: *const TypeInfo,
        value: [size]u8 align(alignment),

        pub const Size = size;
        pub const Alignment = alignment;
        pub const Self = @This();

        pub fn init(self: *Self, typeInfo: *const TypeInfo, alloc: std.mem.Allocator, value: ?[*] const u8) !void {
            self.typeInfo = typeInfo;
            const val: [*]u8 = if (self.inPlace())
                @ptrCast(&self.value)
            else blk: {
                const valuePtr: *[*]u8 align(alignment) = @ptrCast(&self.value);
                valuePtr.* = alloc.rawAlloc(
                    typeInfo.size, 
                    std.mem.Alignment.fromByteUnits(typeInfo.alignment), 
                    @returnAddress()
                ).?;
                break :blk valuePtr.*;
            };
            if (value) |v|
                @memcpy(val[0..typeInfo.size], v);
        }

        pub fn initT(self: *Self, T: type, registry: *TypeRegistry, value: ?*const T) !void {
            try self.init(try registry.get(T), registry.alloc, @ptrCast(value));
        }

        pub fn deinit(self: *Self, registry: *TypeRegistry) void {
            const anyPtr = self.ptr();
            _ = anyPtr.deinitValue(registry);
            if (!self.inPlace()) {
                const valuePtr: *[*]u8 = @ptrCast(&self.value);
                registry.alloc.rawFree(
                    valuePtr.*[0..self.typeInfo.size], 
                    std.mem.Alignment.fromByteUnits(self.typeInfo.alignment), 
                    @returnAddress()
                );
            }
        }

        pub fn ptr(self: *const Self) AnyPtr {
            return AnyPtr.init(
                self.typeInfo,
                if (self.inPlace()) 
                        @constCast(@ptrCast(&self.value))
                    else 
                        @as(*[*]u8, @constCast(@ptrCast(&self.value))).*
            );
        }

        fn inPlace(self: *const Self) bool {
            return self.typeInfo.size <= size and self.typeInfo.alignment <= alignment;
        }
    };
}
