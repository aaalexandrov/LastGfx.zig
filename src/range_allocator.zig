const std = @import("std");
const zip = @import("zip_tree.zig");

pub fn RangeAlloc(comptime D: type) type {
    return struct {
        fullRange: Range,
        freeRanges: FreeRanges,
        allocatedRanges: AllocatedRanges,

        pub const Data = D;
        pub const Range = struct {
            start: Data = std.math.maxInt(Data),
            end: Data = std.math.minInt(Data),

            pub fn getSize(self: *const @This()) Data {
                return self.end - self.start;
            }

            pub fn empty(self: *const @This()) bool {
                return self.start >= self.end;
            }

            pub fn equals(lhs: *const @This(), rhs: *const @This()) bool {
                return lhs.start == rhs.start and lhs.end == rhs.end;
            }

            pub fn intersects(lhs: *const @This(), rhs: *const @This()) bool {
                return !(lhs.end <= rhs.start or rhs.end <= lhs.start);
            }

            pub fn contains(self: *const @This(), d: Data) bool {
                return self.start <= d and d < self.end;
            }

            fn orderByStart(lhs: anytype, rhs: @This()) std.math.Order {
                return switch (@TypeOf(lhs)) {
                    Data => std.math.order(lhs, rhs.start),
                    Range => std.math.order(lhs.start, rhs.start),
                    else => unreachable,
                };
            }

            fn orderBySize(lhs: anytype, rhs: @This()) std.math.Order {
                return switch (@TypeOf(lhs)) {
                    Data => std.math.order(lhs, rhs.getSize()),
                    Range => range: {
                        const sizeOrder = std.math.order(lhs.getSize(), rhs.getSize());
                        break :range if (sizeOrder == .eq)
                            orderByStart(lhs, rhs)
                        else 
                            sizeOrder;
                    },
                    else => unreachable,
                };
            }
        };

        const FreeRanges = zip.ZipTree(Range, Range.orderBySize);
        const AllocatedRanges = zip.ZipTree(Range, Range.orderByStart);

        pub const Self = @This();

        pub fn init(self: *Self, start: Data, end: Data, alloc_: std.mem.Allocator) !void {
            self.fullRange = .{ .start = start, .end = end };
            self.freeRanges = FreeRanges.init(alloc_);
            try self.freeRanges.insert(.{.start = start, .end = end});
            self.allocatedRanges = AllocatedRanges.init(alloc_);
        }

        pub fn deinit(self: *Self) void {
            self.allocatedRanges.deinit();
            self.freeRanges.deinit();
        }

        pub fn clear(self: *Self) void {
            self.allocatedRanges.clear();
            self.freeRanges.clear();
            try self.freeRanges.insert(self.fullRange);
        }

        pub fn validate(self: *Self) bool {
            var allocatedSize: Data = 0;
            var next = self.allocatedRanges.first();
            while (next) |current| {
                if (current.data.empty())
                    return false;

                allocatedSize += current.data.getSize();

                var freeNode = self.freeRanges.first();
                while (freeNode) |freeN| : (freeNode = freeN.next()) {
                    if (freeN.data.intersects(&current.data))
                        return false;
                }

                next = current.next();
                if (next) |next_| {
                    if (current.data.intersects(&next_.data))
                        return false;
                    const middle = Range{.start = current.data.end, .end = next_.data.start};
                    if (middle.getSize() > 0) {
                        const foundFree = self.freeRanges.find(middle);
                        if (foundFree) |f| {
                            if (!f.data.equals(&middle))
                                return false;
                        } else {
                            return false;
                        }
                    }
                }
            }

            var freeSize: Data = 0;
            var freeNode = self.freeRanges.first();
            while (freeNode) |freeN| : (freeNode = freeN.next()) {
                freeSize += freeN.data.getSize();
            }

            if (allocatedSize + freeSize != self.fullRange.getSize())
                return false;

            return true;
        }

        pub fn alloc(self: *Self, size: Data, alignment: Data) !Data {
            std.debug.assert(std.math.isPowerOfTwo(alignment));
            var smallest = self.freeRanges.lowerBoundAny(Data, size) orelse self.freeRanges.first();
            while (smallest) |small| : (smallest = small.next()) {
                const freeRange = small.data;
                const aligned = (freeRange.start + alignment - 1) & ~(alignment - 1);
                if (aligned + size <= freeRange.end) {
                    const allocRange = Range{.start = aligned, .end = aligned + size};
                    try self.allocatedRanges.insert(allocRange);
                    self.freeRanges.delete(small);
                    if (freeRange.start < aligned)
                        try self.freeRanges.insert(.{.start = freeRange.start, .end = aligned});
                    if (allocRange.end < freeRange.end)
                        try self.freeRanges.insert(.{.start = allocRange.end, .end = freeRange.end});
                    return aligned;
                }
            }
            return error.NoAvailableRange;
        }

        pub fn free(self: *Self, allocated: Data) !void {
            const allocation = self.findAllocated(allocated) 
                orelse return error.NotAnAllocatedRange;
            var prevFree = Range{
                .start = if (allocation.prev()) |prev|
                        prev.data.end
                    else
                        self.fullRange.start, 
                .end = allocation.data.start,
            };
            if (!prevFree.empty()) {
                const freed = self.freeRanges.erase(prevFree);
                std.debug.assert(freed);
            }

            var nextFree = Range{
                .start = allocation.data.end,
                .end = if (allocation.next()) |next|
                        next.data.start
                    else
                        self.fullRange.end,
            };
            if (!nextFree.empty()) {
                const freed = self.freeRanges.erase(nextFree);
                std.debug.assert(freed);
            }

            self.allocatedRanges.delete(allocation);
            try self.freeRanges.insert(.{.start = prevFree.start, .end = nextFree.end});
        }

        pub fn allocSize(self: *Self, allocated: Data) Data {
            const allocation = self.findAllocated(allocated);
            return if (allocation) |a|
                a.data.getSize()
            else
                0;
        }

        fn findAllocated(self: *Self, allocated: Data) ?*AllocatedRanges.Node {
            const lower = self.allocatedRanges.lowerBoundAny(Data, allocated);
            if (lower) |low| {
                if (low.data.contains(allocated))
                    return low;
            }
            return null;
        }
    };
}


pub fn RangeAllocTest(alloc: std.mem.Allocator) !void {
    var ra: RangeAlloc(u64) = undefined;
    try ra.init(0, 1024*1024, alloc);
    defer ra.deinit();

    try std.testing.expect(ra.validate());

    const a1000 = try ra.alloc(1000, 1);
    try std.testing.expect(ra.validate());

    try std.testing.expectEqual(1000, ra.allocSize(a1000 + 5));
    try std.testing.expectEqual(0, ra.allocSize(a1000 + 1005));

    const a2048 = try ra.alloc(2048, 16);
    try std.testing.expect(ra.validate());

    const a8 = try ra.alloc(8, 1);
    try std.testing.expect(ra.validate());

    try ra.free(a8);
    try std.testing.expect(ra.validate());

    try ra.free(a1000);
    try std.testing.expect(ra.validate());

    try ra.free(a2048);
    try std.testing.expect(ra.validate());

    var failed = false;
    _ = ra.alloc(1024*1024*2, 16) catch |err| switch (err) { 
        error.NoAvailableRange => failed = true,
        else => return err,
    };
    try std.testing.expect(failed);
}

test "RangeAlloc" {
    try RangeAllocTest(std.testing.allocator);
}
