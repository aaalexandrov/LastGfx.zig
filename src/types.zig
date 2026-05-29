const std = @import("std");

pub const TypeInfo = struct {
    name: []const u8,
    size: usize,
    alignment: usize,
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

        fn deinit(self: *@This(), registry: *TypeRegistry) void {
            switch (self.*) {
                .Struct => |str| {
                    for (str.members) |*member|
                        @as(*Member, @constCast(member)).deinit(registry);
                    registry.alloc.free(str.members);
                },
                else => {},
            }
        }
    };

    pub const Member = struct {
        name: []const u8,
        offset: usize,
        typeInfo: *const TypeInfo,

        fn deinit(self: *@This(), registry: *TypeRegistry) void {
            registry.alloc.free(self.name);
        }
    };

    pub const Self = @This();

    fn initEmpty(self: *Self, name: []const u8) !void {
        self.name = name;
        self.size = 0;
        self.alignment = 0;
        self.info = .Basic;
    }

    fn initType(self: *Self, registry: *TypeRegistry, name: []const u8, comptime T: type) !void {
        self.name = name;
        self.size = @sizeOf(T);
        self.alignment = @alignOf(T);
        self.info = switch (@typeInfo(T)) {
            .array => |arr| .{.Array = .{
                .length = arr.len,
                .elementType = try registry.get(arr.child),
            }},
            .@"struct" => |str| blk: {
                var members = try registry.alloc.alloc(Member, str.fields.len);
                inline for (0..str.fields.len) |i| {
                    members[i] = .{
                        .name = try registry.alloc.dupe(u8, str.fields[i].name),
                        .offset = @offsetOf(T, str.fields[i].name),
                        .typeInfo = try registry.get(str.fields[i].type),
                    };
                }
                break :blk .{.Struct = .{.members = members}};
            },
            .pointer => |ptr| .{.Pointer = .{
                .pointedType = try registry.get(ptr.child),
            }},
            else => .Basic,
        };
    }

    fn deinit(self: *Self, registry: *TypeRegistry) void {
        self.info.deinit(registry);
    }

    pub fn dump(self: *const Self, depth: u32) void {
        const maxDepth = 16;
        if (depth > maxDepth)
            return;
        const whitespace = (" " ** (2*(maxDepth+1)));
        std.log.info("{s}Type {s}, size: {}, align: {}, kind: {s}", .{whitespace[0..depth*2], self.name, self.size, self.alignment, @tagName(self.info)});
        switch (self.info) {
            .Array => |arr| {
                std.log.info("{s}len: {}", .{whitespace[0..(depth+1)*2], arr.length});
                arr.elementType.dump(depth + 2);
            },
            .Pointer => |ptr| {
                ptr.pointedType.dump(depth + 1);
            },
            .Struct => |str| {
                for (str.members) |*member| {
                    std.log.info("{s}member name: {s}, offset: {}", .{whitespace[0..(depth+1)*2], member.name, member.offset});
                    member.typeInfo.dump(depth + 2);
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

    pub fn getNew(self: *Self, name: []const u8) error{OutOfMemory, TypeAlreadyExists}!*TypeInfo {
        const entry = try self.types.getOrPut(self.alloc, name);
        if (entry.found_existing)
            return error.TypeAlreadyExists;
        entry.key_ptr.* = try self.alloc.dupe(u8, name);
        entry.value_ptr.* = try self.alloc.create(TypeInfo);
        try entry.value_ptr.*.initEmpty(name);
        return entry.value_ptr.*;
    }
};