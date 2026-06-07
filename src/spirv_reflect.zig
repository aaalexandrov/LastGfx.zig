const std = @import("std");
const c = @import("c");
const types = @import("types.zig");

const TypeInfo = types.TypeInfo;
const TypeRegistry = types.TypeRegistry;

pub fn reflect(spvCode: []const u32, registry: *TypeRegistry) !void {
    var spvModule: c.SpvReflectShaderModule = undefined;
    const result = c.spvReflectCreateShaderModule(spvCode.len * @sizeOf(u32), spvCode.ptr, &spvModule);
    if (result != c.SPV_REFLECT_RESULT_SUCCESS)
        return error.SpvReflectFailed;

    for (0..spvModule.push_constant_block_count) |i| {
        const varBlock: *c.SpvReflectBlockVariable = @ptrCast(&spvModule.push_constant_blocks[i]);
        _ = try parseVarType(varBlock, registry);
    }

    c.spvReflectDestroyShaderModule(&spvModule);
}

fn parseVarType(reflVar: *c.SpvReflectBlockVariable, registry: *TypeRegistry) !*TypeInfo {
    const reflType: *c.SpvReflectTypeDescription = reflVar.type_description;
    var curType: ?*TypeInfo = null;
    const numericMask = c.SPV_REFLECT_TYPE_FLAG_BOOL | c.SPV_REFLECT_TYPE_FLAG_INT | c.SPV_REFLECT_TYPE_FLAG_FLOAT;
    if (reflType.type_flags & numericMask != 0) {
        std.debug.assert(reflType.traits.numeric.scalar.width == 32);
        if ((reflType.type_flags & c.SPV_REFLECT_TYPE_FLAG_FLOAT) != 0) {
            curType = @constCast(try registry.get(f32));
        } else if ((reflType.type_flags & c.SPV_REFLECT_TYPE_FLAG_INT) != 0) {
            curType = @constCast(if (reflType.traits.numeric.scalar.signedness == 0)
                    try registry.get(u32)
                else 
                    try registry.get(i32));
        } else {
            std.debug.assert((reflType.type_flags & c.SPV_REFLECT_TYPE_FLAG_BOOL) != 0);
            curType = @constCast(try registry.get(c.VkBool32));
        }

        if ((reflType.type_flags & c.SPV_REFLECT_TYPE_FLAG_VECTOR) != 0) {
            curType = try getArray(registry, curType.?, reflType.traits.numeric.vector.component_count);
        }

        if ((reflType.type_flags & c.SPV_REFLECT_TYPE_FLAG_MATRIX) != 0) {
            std.debug.assert((reflType.type_flags & c.SPV_REFLECT_TYPE_FLAG_VECTOR) != 0);
            std.debug.assert(curType.?.info.Array.length == reflType.traits.numeric.matrix.row_count);
            curType = try getArray(registry, curType.?, reflType.traits.numeric.matrix.column_count);
        }
    }

    if ((reflType.type_flags & c.SPV_REFLECT_TYPE_FLAG_STRUCT) != 0) {
        std.debug.assert(reflVar.member_count == reflType.member_count);
        std.debug.assert(curType == null);
        const typeName = std.mem.span(reflType.type_name);
        curType = registry.find(typeName);
        if (curType) |existing| {
            std.debug.assert(existing.info.Struct.members.len == reflType.member_count);
            return existing;
        }
        curType = try registry.getNew(typeName);
        var members = try registry.alloc.alloc(types.TypeInfo.Member, reflType.member_count);
        errdefer registry.alloc.free(members);
        for (0..members.len) |i| {
            members[i].name = try registry.alloc.dupe(u8, std.mem.span(reflVar.members[i].name));
            members[i].typeInfo = try parseVarType(reflVar.members+i, registry);
            members[i].offset = reflVar.members[i].offset;
            members[i].metadata = .{};
        }
        if (members.len > 0) {
            curType.?.size = members[members.len-1].offset + members[members.len-1].typeInfo.size;
            curType.?.alignment = members[0].typeInfo.alignment;
        }
        curType.?.info = .{.Struct = .{.members = members}};
    }

    std.debug.assert(curType != null);

    if ((reflType.type_flags & c.SPV_REFLECT_TYPE_FLAG_REF) != 0) {
        var nameBuf: [256]u8 = undefined;
        const ptrName = try std.fmt.bufPrint(&nameBuf, "*{s}", .{curType.?.name});
        var ptrType = registry.find(ptrName);
        if (ptrType) |existing| {
            std.debug.assert(existing.info.Pointer.pointedType == curType);
            return existing;
        }
        ptrType = try registry.getNew(ptrName);
        ptrType.?.size = reflVar.size;
        ptrType.?.alignment = reflVar.size;
        ptrType.?.info = .{.Pointer = .{
            .pointedType = curType.?,
        }};
        curType = ptrType;
    }

    if ((reflType.type_flags & c.SPV_REFLECT_TYPE_FLAG_ARRAY) != 0) {
        std.debug.assert(curType.?.size == reflType.traits.array.stride);
        for (0..reflType.traits.array.dims_count) |dim| {
            curType = try getArray(registry, curType.?, reflType.traits.array.dims[dim]);
        }
    }

    return curType.?;
}

fn getArray(registry: *TypeRegistry, elemType: *TypeInfo, len: usize) !*TypeInfo {
    var nameBuf: [256]u8 = undefined;
    const arrName = try std.fmt.bufPrint(&nameBuf, "[{}]{s}", .{len, elemType.name});
    var arrType = registry.find(arrName);
    if (arrType == null) {
        arrType = try registry.getNew(arrName);
        arrType.?.size = len * elemType.size;
        arrType.?.alignment = elemType.alignment;
        arrType.?.info = .{ .Array = .{
            .elementType = elemType,
            .length = len,
        } };
    }
    return arrType.?;
}
