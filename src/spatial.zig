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
            self.clear();
        }

        pub fn clear(self: *Self) void {
            self.nodes.clearAndFree(self.alloc);
        }

        fn nodeIndex(self: *const Self, nodeBox: *const Box) u32 {
            std.debug.assert(!nodeBox.isEmpty());
            var curBox = self.box;
            var index: u32 = 1;
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
                index = (index << N) | childIdx;
            }
            return index;
        }

        fn nodeBoxFromIndex(self: *const Self, nodeIdx: u32) Box {
            if (nodeIdx == 0)
                return .{};
            var shift: u32 = 32 - @clz(nodeIdx) - 1;
            std.debug.assert(shift % N == 0);
            var box = self.box;
            while (shift > 0) {
                shift -= N;
                const childIdx = nodeIdx >> shift;
                box = getChildBox(&box, childIdx);
            }
            return box;
        }

        fn getChildBox(box: *const Box, childIdx: u32) Box {
            var curBox = box.*;
            const center = box.center();
            inline for (0..N) |d| {
                if ((childIdx & (1 << d)) == 0)
                    curBox.max[d] = center[d]
                else
                    curBox.min[d] = center[d];
            }
            return curBox;
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

        pub fn iterator(self: *const Self) Iterator {
            return .{
                .spatial = self,
                .box = self.box,
                .nodeIdx = 1,
                .itemIdx = null,
                .childIdx = 0,
            };
        }

        pub const Iterator = struct {
            spatial: *const Self,
            box: Box,
            nodeIdx: u32,
            itemIdx: ?u32,
            childIdx: u32,

            pub fn next(self: *const Iterator) ?struct { box: *const Box, data: ?Data } {
                const node = self.spatial.nodes.getPtr(self.nodeIdx) orelse return null;
                const curBox = self.box;
                var data: ?*const Data = null;
                if (self.itemIdx) |itemIndex| {
                    const item = &node.data.items[itemIndex];
                    curBox = item.dataBox;
                    data = item.data;
                }
                self.advanceItem(node);
                return .{.box = curBox, .data = data};
            }

            pub fn skipNodeAndChildren(self: *const Iterator) void {
                const node = self.spatial.nodes.getPtr(self.nodeIdx).?;
                self.childIdx = NodesPerLevel;
                self.advanceNode(node);
            }

            fn advanceItem(self: *const Iterator, node: *const Node) void {
                if (self.itemIdx == null)
                    self.itemIdx = 0
                else
                    self.itemIdx += 1;
                if (self.itemIdx >= node.data.items.len)
                    advanceNode(self, node);
            }

            fn advanceNode(self: *const Iterator, node: *const Node) void {
                self.itemIdx = null;
                while (self.childIdx < NodesPerLevel) {
                    if ((node.childMask & (1 << self.childIdx)) != 0) {
                        // descend to a valid child
                        self.nodeIdx = (self.nodeIdx << N) | self.childIdx;
                        self.box = getChildBox(self.box, self.childIdx);
                        self.childIdx = 0;
                        return;
                    }
                    self.childIdx += 1;
                }
                // go up to the parent
                // if we're already a the root (index 1), we'll go to index 0 which does not exist so nextBox() will return null on the next call
                self.childIdx = self.nodeIdx & (NodesPerLevel - 1);
                self.nodeIdx = self.nodeIdx >> N;
                self.box = self.nodeBoxFromIndex(self.nodeIdx);
            }
        };
    };
}