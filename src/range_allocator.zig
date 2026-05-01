const std = @import("std");
const zip = @import("zip_tree.zig");

pub const RangeAlloc = struct {
    freeRanges: FreeRanges,
    allocatedRanges: AllocatedRanges,

    pub const Data = u64;
    pub const Range = struct {
        start: Data,
        end: Data,

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

        pub fn orderByStart(lhs: anytype, rhs: @This()) std.math.Order {
            switch (@TypeOf(lhs)) {
                Data => 
                    return std.math.order(lhs, rhs.start),
                Range =>
                    return std.math.order(lhs.start, rhs.start),
                else =>
                    unreachable,
            }
        }

        pub fn orderBySize(lhs: anytype, rhs: @This()) std.math.Order {
            switch (@TypeOf(lhs)) {
                Data =>
                    return std.math.order(lhs, rhs.getSize()),
                Range => {
                    const sizeOrder = std.math.order(lhs.getSize(), rhs.getSize());
                    return if (sizeOrder == .eq)
                        orderByStart(lhs, rhs)
                    else 
                        sizeOrder;
                },
                else =>
                    unreachable,
            }
        }
    };
    pub const FreeRanges = zip.ZipTree(Range, Range.orderBySize);
    pub const AllocatedRanges = zip.ZipTree(Range, Range.orderByStart);

    pub const Self = @This();

    pub fn init(self: *Self, start: Data, end: Data, alloc_: std.mem.Allocator) !void {
        self.freeRanges = FreeRanges.init(alloc_);
        try self.freeRanges.insert(.{.start = start, .end = end});
        self.allocatedRanges = AllocatedRanges.init(alloc_);
    }

    pub fn deinit(self: *Self) void {
        self.allocatedRanges.deinit();
        self.freeRanges.deinit();
    }

    pub fn validate(self: *Self) bool {
        var next = self.allocatedRanges.first();
        while (next) |current| {
            if (current.data.empty())
                return false;
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
        return true;
    }

    // pub fn alloc(self: *Self, size: Data, alignment: Data) !Data {

    // }

    // pub fn free(self: *Self, allocated: Data) void {

    // }

    fn findAllocated(self: *Self, allocated: Data) ?*AllocatedRanges.Node {
        return self.allocatedRanges.lowerBound(.{.start = allocated, .end = allocated});
    }
};

pub fn RangeAllocTest(alloc: std.mem.Allocator) !void {
    var ra: RangeAlloc = undefined;
    try ra.init(0, 1024*1024, alloc);
    defer ra.deinit();

    try std.testing.expect(ra.validate());
}

test "RangeAlloc" {
    try RangeAllocTest(std.testing.allocator);
}
