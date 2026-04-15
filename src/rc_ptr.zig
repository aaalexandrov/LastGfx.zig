const std = @import("std");
const assert = std.debug.assert;

fn emptyDeinit(_: anytype) void {}

fn RcInner(T: type, deinitFn: anytype) type {
    return struct {
        counters: [2]Counter = .{
            1,
            0,
        },
        data: Data = undefined,

        pub const Counter = u32;
        pub const Data = T;
        pub const Self = @This();

        fn addRef(self: *Self, comptime ref: u1) void {
            const prevCounter = @atomicRmw(Counter, &self.counters[ref], .Add, 1, .acq_rel);
            assert(ref != 0 or prevCounter > 0);
        }

        fn decRef(self: *Self, alloc_: std.mem.Allocator, comptime ref: u1) void {
            const prevCounter = @atomicRmw(Counter, &self.counters[ref], .Sub, 1, .acq_rel);
            assert(ref > 0 or prevCounter > 0);
            if (prevCounter == 1) {
                if (comptime ref == 0) {
                    deinitData(&self.data);
                    alloc_.destroy(self);
                }
            }
        }

        fn deinitData(data_: *Data) void {
            deinitFn(data_);
        }
    };
}

pub fn RcPtr(T: type, weak: bool, deinitFn: anytype) type {
    return struct {
        inner: ?*Inner = null,

        const Inner = RcInner(T, deinitFn);

        pub const Data = T;
        pub const Weak: u1 = @intFromBool(weak);
        pub const Self = @This();

        pub fn alloc(alloc_: std.mem.Allocator, data_: Data) !Self {
            comptime if (weak)
                @compileError("Cannot allocate data with a weak pointer");
            const self = Self{
                .inner = try alloc_.create(Inner),
            };
            self.inner.?.* = .{
                .data = data_,
            };
            return self;
        }

        pub fn deinit(self: *Self, alloc_: std.mem.Allocator) void {
            self.assignInner(null, alloc_);
        }

        pub fn reset(self: *Self, alloc_: std.mem.Allocator) void {
            return self.assignInner(null, alloc_);
        }

        pub fn assign(self: *Self, rhs: *const Self, alloc_: std.mem.Allocator) void {
            self.assignInner(rhs.inner, alloc_);
        }

        pub fn assignPtr(self: *Self, data_: ?*Data, alloc_: std.mem.Allocator) void {
            const inner_: ?*Inner = if (data_) |data__|
                @fieldParentPtr("data", data__)
            else
                null;
            self.assignInner(inner_, alloc_);
        }

        fn assignInner(self: *Self, inner_: ?*Inner, alloc_: std.mem.Allocator) void {
            if (inner_) |inner__|
                inner__.addRef(0);
            if (self.inner) |selfInner|
                selfInner.decRef(alloc_, 0);
            self.inner = inner_;
        }

        pub fn data(self: *const Self) ?*Data {
            return if (self.inner) |inner_| &inner_.data else null;
        }

        pub fn empty(self: *const Self) bool {
            return self.inner == null;
        }
    };
}

pub fn RcTest(alloc_: std.mem.Allocator) !void {
    const expect = std.testing.expect;
    const expectEqual = std.testing.expectEqual;

    const Rc_u32 = RcPtr(u32, false, emptyDeinit);
    var rc = Rc_u32{};
    defer rc.deinit(alloc_);
    try expect(rc.empty());
    try expect(rc.data() == null);

    rc = try Rc_u32.alloc(alloc_, 44);
    try expect(rc.data() != null);

    var rc1 = Rc_u32{};
    defer rc1.deinit(alloc_);
    rc1.assign(&rc, alloc_);
    try expectEqual(2, rc1.inner.?.counters[0]);
    try expectEqual(rc.inner, rc1.inner);

    rc.reset(alloc_);
    try expect(rc.empty());
}

test "RcPtr" {
    RcTest(std.testing.allocator);
}
