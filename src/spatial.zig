const std = @import("std");
const vm = @import("vec_math.zig");
const g = @import("geom.zig");

pub fn SpatialTree(comptime N: u32, T: type, D: type) type {
    return struct {
        box: Box,
        alloc: std.mem.Allocator,
        nodes: NodesMap,
        nodeLevels: u32,

        const Item = struct {
            dataBox: Box,
            data: Data,
        };

        const Node = struct {
            data: DataArray = DataArray.empty,
            childMask: ChildMask = 0,

            const DataArray = std.ArrayListUnmanaged(Item);
            const ChildMask = @Int(.unsigned, NodesPerLevel);
        };

        pub const NodesMap = std.AutoHashMapUnmanaged(u32, Node);
        pub const Data = D;
        pub const Vec = vm.Vec(N, T);
        pub const Box = g.Box(N, T);
        pub const NodesPerLevel: u32 = 1 << N;
        pub const Self = @This();

        pub fn init(box_: *const Box, maxLevels: u32, alloc_: std.mem.Allocator) !Self {
            return .{
                .box = box_.*,
                .alloc = alloc_,
                .nodes = NodesMap.empty,
                .nodeLevels = maxLevels,
            };
        }

        pub fn deinit(self: *Self) void {
            var itNodes = self.nodes.valueIterator();
            while (itNodes.next()) |node| {
                self.alloc.destroy(node.*);
            }
            self.nodes.clearAndFree(self.alloc);
        }

        fn nodeIndex(self: *const Self, nodeBox: *const Box) u32 {
            std.debug.assert(!nodeBox.isEmpty());
            var curBox = self.box;
            var index: u32 = 0;
            var level: u32 = 0;
            lvl: while (level < self.nodeLevels) : (level += 1) {
                std.debug.assert(curBox.contains(nodeBox));
                const curCenter = curBox.center();
                var childBox: Box = nodeBox;
                var childIdx: u32 = 0;
                inline for (0..N) |d| {
                    if (nodeBox.max[d] <= curCenter[d]) {
                        childBox.max[d] = curCenter[d];
                    } else if (curCenter[d] <= nodeBox.min[d]) {
                        childBox.min[d] = curCenter[d];
                        childIdx |= 1 << d;
                    } else
                        break :lvl;
                }
                index = index * NodesPerLevel + 1 + childIdx;
            }
            return index;
        }

        pub fn addData(self: *Self, dataBox: *const Box, data: Data) !void {
            var nodeInd = self.nodeIndex(dataBox);
            var entry = try self.nodes.getOrPut(self.allocator, nodeInd);
            const node = entry.value_ptr;
            var childBit: Node.ChildMask = 0;
            while (nodeInd != 0 and !entry.found_existing) {
                entry.value_ptr.* = .{.childMask = childBit};
                const childInd = (nodeInd - 1) % NodesPerLevel;
                childBit = 1 << childInd;
                nodeInd = (nodeInd - 1) / NodesPerLevel;
                entry = try self.nodes.getOrPut(self.allocator, nodeInd);
            }
            try node.data.append(self.alloc, .{
                .dataBox = dataBox,
                .data = data,
            });
        }

        pub fn findData(self: *const Self, dataBox: *const Box, data: Data) ?struct { node: *Node, dataIdx: u32 } {
            const nodeInd = self.nodeIndex(dataBox);
            const node = if (self.nodes.getPtr(nodeInd)) |n| n else return null;
            for (node.data.items, 0..) |*item, i| {
                if (item.dataBox == dataBox.* and item.data == data)
                    return .{.node = node, .dataIdx = @intCast(i)};
            }
            return null;
        }

        pub fn removeData(self: *Self, dataBox: *const Box, data: Data) void {
            if (self.findData(dataBox, data)) |found| {
                found.node.data.swapRemove(found.dataIdx);
            }
        }
    };
}