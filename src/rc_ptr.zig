const std = @import("std");
const assert = std.debug.assert;

fn emptyDeinit(_: anytype, _: std.mem.Allocator) void {}

fn RcInner(T: type, deinitFn: anytype) type {
    return struct {
        counters: [2]Counter = .{
            0,
            0,
        },
        data: Data = undefined,

        pub const Counter = u32;
        pub const Data = T;
        pub const Self = @This();

        fn addRef(self: *Self, comptime ref: u1) void {
            _ = @atomicRmw(Counter, &self.counters[ref], .Add, 1, .acq_rel);
        }

        fn addRefIfPositive(self: *Self, comptime ref: u1) bool {
            var counter = self.getRef(ref);
            while (counter > 0) {
                if (@cmpxchgWeak(Counter, &self.counters[ref], counter, counter + 1, .acq_rel, .acquire)) |ctr|
                    counter = ctr
                else
                    break;
            }
            return counter > 0;
        }

        fn decRef(self: *Self, alloc: std.mem.Allocator, comptime ref: u1) void {
            const prevCounter = @atomicRmw(Counter, &self.counters[ref], .Sub, 1, .acq_rel);
            assert(ref > 0 or prevCounter > 0);
            if (prevCounter == 1) {
                if (comptime ref == 0) {
                    // TODO: Should we try to use alloc.resize() to shrink the memory in place?
                    // if we do and it doesn't fail, then we should use alloc.rawFree() or alloc.resize(new_nen = 0) with the shrunken memory size later when we free the memory
                    deinitData(&self.data, alloc);
                }
                if (self.getRef(1 - ref) == 0)
                    alloc.destroy(self);
            }
        }

        fn getRef(self: *const Self, ref: u1) Counter {
            return @atomicLoad(Counter, &self.counters[ref], .acquire);
        }

        fn deinitData(data_: *Data, alloc: std.mem.Allocator) void {
            deinitFn(data_, alloc);
        }
    };
}

pub fn RcPtr(T: type, weak: bool, deinitFn: anytype) type {
    return struct {
        inner: ?*Inner = null,

        const Inner = RcInner(T, deinitFn);

        pub const Data = T;
        pub const Weak: u1 = @intFromBool(weak);
        pub const AlternativePtr = RcPtr(T, !weak, deinitFn);
        pub const WeakPtr = if (weak) Self else AlternativePtr;
        pub const StrongPtr = if (weak) AlternativePtr else Self;
        pub const Self = @This();

        pub fn allocate(self: *Self, alloc: std.mem.Allocator, data_: Data) !void {
            comptime if (weak) unreachable;

            const inner = try alloc.create(Inner);
            inner.* = .{
                .data = data_,
            };
            self.assignInner(inner, true, alloc);
        }

        pub fn clear(self: *Self, alloc: std.mem.Allocator) void {
            return self.assignInner(null, true, alloc);
        }

        pub fn assign(self: *Self, rhs: anytype, alloc: std.mem.Allocator) void {
            const rhsTypeInfo = @typeInfo(@TypeOf(rhs));
            comptime if (rhsTypeInfo.pointer.child != Self and rhsTypeInfo.pointer.child != AlternativePtr)
                unreachable;

            const assumeInnerHasRef = comptime (Self.Weak != 0 or @TypeOf(rhs.*).Weak == 0);
            self.assignInner(rhs.getInner(), assumeInnerHasRef, alloc);
        }

        pub fn assignPtr(self: *Self, data_: ?*Data, alloc: std.mem.Allocator) void {
            // here we assume that data was allocated through a RcPtr, and that it's still referenced by one to keep the inner allocation alive
            const inner_: ?*Inner = if (data_) |data__|
                @fieldParentPtr("data", data__)
            else
                null;
            self.assignInner(inner_, true, alloc);
        }

        pub fn data(self: *const Self) ?*Data {
            comptime if (weak) unreachable;

            return if (self.getInner()) |inner_| &inner_.data else null;
        }

        pub fn isClear(self: *const Self) bool {
            return self.getInner() == null;
        }

        pub fn getRef(self: *const Self, weakCount: u1) Inner.Counter {
            return if (self.getInner()) |inner_| inner_.getRef(weakCount) else 0;
        }

        fn getInner(self: *const Self) ?*Inner {
            return @atomicLoad(?*Inner, &self.inner, .acquire);
        }

        fn assignInner(self: *Self, inner_: ?*Inner, comptime assumeInnerHasRef: bool, alloc: std.mem.Allocator) void {
            var effectiveInner = inner_;
            if (effectiveInner) |inner__| {
                if (assumeInnerHasRef)
                    inner__.addRef(Weak)
                else if (!inner__.addRefIfPositive(Weak))
                    effectiveInner = null;
            }
            const prevInner = @atomicRmw(?*Inner, &self.inner, .Xchg, effectiveInner, .acq_rel);
            if (prevInner) |prevInner_|
                prevInner_.decRef(alloc, Weak);
        }
    };
}

pub fn SharedPtr(T: type, deinitFn: anytype) type {
    return RcPtr(T, false, deinitFn);
}
pub fn SharedPtrNoDeinit(T: type) type {
    return RcPtr(T, false, emptyDeinit);
}
pub fn WeakPtr(T: type, deinitFn: anytype) type {
    return RcPtr(T, true, deinitFn);
}
pub fn WeakPtrNoDeinit(T: type) type {
    return RcPtr(T, true, emptyDeinit);
}


pub fn RcTest(alloc: std.mem.Allocator) !void {
    const expect = std.testing.expect;
    const expectEqual = std.testing.expectEqual;

    const SharedU32 = SharedPtrNoDeinit(u32);
    var rc = SharedU32{};
    defer rc.clear(alloc);
    try expect(rc.isClear());
    try expect(rc.data() == null);

    try rc.allocate(alloc, 44);
    try expect(rc.data() != null);

    var rc1 = SharedU32{};
    defer rc1.clear(alloc);
    rc1.assign(&rc, alloc);
    try expectEqual(2, rc1.getRef(0));
    try expectEqual(rc.inner, rc1.inner);

    var wc: SharedU32.WeakPtr = WeakPtrNoDeinit(u32){};
    defer wc.clear(alloc);

    wc.assign(&rc1, alloc);
    try expectEqual(2, wc.getRef(0));
    try expectEqual(1, wc.getRef(1));
    try expectEqual(rc.inner, wc.inner);

    rc.clear(alloc);
    try expect(rc.isClear());
    rc.assign(&rc, alloc);
    try expect(rc.isClear());

    try expectEqual(1, wc.getRef(0));
    try expectEqual(1, wc.getRef(1));
    try expectEqual(rc1.inner, wc.inner);

    rc.assign(&wc, alloc);
    try expectEqual(2, wc.getRef(0));
    try expectEqual(1, wc.getRef(1));
    try expectEqual(rc.inner, wc.inner);

    rc.assignPtr(rc.data(), alloc);
    try expectEqual(2, wc.getRef(0));
    try expectEqual(1, wc.getRef(1));
    try expectEqual(rc.inner, wc.inner);

    try expectEqual(44, rc1.data().?.*);
}

test "RcPtr" {
    RcTest(std.testing.allocator);
}
