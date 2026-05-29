const std = @import("std");
const c = @import("c");
const types = @import("types.zig");

alloc: std.mem.Allocator,
name: []const u8,
spvModule: c.SpvReflectShaderModule,

pub const Self = @This();

pub fn init(self: *Self, alloc: std.mem.Allocator, name: []const u8, spvCode: []const u8) !void {
    self.alloc = alloc;
    self.name = try alloc.dupe(u8, name);
    errdefer alloc.free(self.name);
    const result = c.spvReflectCreateShaderModule(spvCode.len, spvCode.ptr, &self.spvModule);
    if (result != c.SPV_REFLECT_RESULT_SUCCESS)
        return error.SpvReflectFailed;

    var typeReg = try types.TypeRegistry.init(alloc);
    defer typeReg.deinit();

    const ti = try typeReg.get(i32);
    ti.dump(0);
    const tb = try typeReg.get(bool);
    tb.dump(0);
    const ta = try typeReg.get([4]f32);
    ta.dump(0);
    const tp = try typeReg.get(*usize);
    tp.dump(0);

    const Kek = struct {
        i: i32,
        u: u32,
        b: bool,
    };
    const ts = try typeReg.get(Kek);
    ts.dump(0);
    std.debug.assert(ts.info.Struct.members[0].typeInfo == ti);

    (try typeReg.get(c.SpvReflectShaderModule)).dump(0);


    for (0..self.spvModule.push_constant_block_count) |i| {
        const varBlock: *c.SpvReflectBlockVariable = @ptrCast(&self.spvModule.push_constant_blocks[i]);
        self.printBlock(varBlock, 0);
    }
}

pub fn deinit(self: *Self) void {
    c.spvReflectDestroyShaderModule(&self.spvModule);
    self.alloc.free(self.name);
}

fn printBlock(self: *Self, varBlock: *c.SpvReflectBlockVariable, depth: u32) void {
    const indent = (" " ** 256)[0..depth*2];
    const typeName: [*c]const u8 = varBlock.type_description.*.type_name orelse "";
    std.log.info("{s}Var: {s}: {s}", .{indent, varBlock.name, typeName});
    for (0..varBlock.member_count) |i| {

        self.printBlock(@ptrCast(&varBlock.members[i]), depth + 1);
    }
}