const std = @import("std");
const vm = @import("vec_math.zig");
const g = @import("geom.zig");

pub fn SpatialTree(comptime N: u32, T: type, D: type) type {
    return struct {
        box: Box,
        nodes: NodesMap,
        nodeLevels: u6,

        const Node = struct {
            data: Data = undefined,
            childMask: ChildMask = 0,

            const ChildMask = @Int(.unsigned, NodesPerLevel);
        };

        pub const NodesMap = std.AutoHashMapUnmanaged(u32, Node);
        pub const Data = D;
        pub const Vec = vm.Vec(N, T);
        pub const Box = g.Box(N, T);
        pub const NodesPerLevel: u32 = 1 << N;
        pub const Self = @This();

        pub fn init(box_: *const Box, maxLevels: u6) Self {
            return .{
                .box = box_.*,
                .nodes = NodesMap.empty,
                .nodeLevels = maxLevels,
            };
        }

        pub fn clear(self: *Self, alloc: std.mem.Allocator) void {
            self.nodes.clearAndFree(alloc);
        }

        fn nodeIndexAndBox(self: *const Self, nodeBox: *const Box) struct { u32, Box } {
            std.debug.assert(!nodeBox.isEmpty());
            var curBox = self.box;
            var index: u32 = 1;
            var level: u6 = 0;
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
                curBox = childBox;
            }
            return .{index, curBox};
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

        pub const NodeData = struct {
            node: *Node,
            box: Box,
        };

        pub fn getNode(self: *const Self, dataBox: *const Box) ?NodeData {
            const nodeInd, const nodeBox = self.nodeIndexAndBox(dataBox);
            return .{
                .node = self.nodes.get(nodeInd) orelse return null,
                .box = nodeBox,
            };
        }

        pub fn getOrAddNode(self: Self, dataBox: *const Box, initData: *const Data, alloc: std.mem.Allocator) !NodeData {
            const nodeInd, const nodeBox = self.nodeIndexAndBox(dataBox);
            std.debug.assert(nodeInd > 0);
            var entry = try self.nodes.getOrPut(alloc, nodeInd);
            const node = entry.value_ptr;
            var parentInd = nodeInd;
            var childMask: Node.ChildMask = 0;
            while (!entry.found_existing) {
                entry.value_ptr.data = initData.*;
                entry.value_ptr.childMask = childMask;

                childMask = 1 << (parentInd & (NodesPerLevel - 1));
                parentInd >>= N;
                if (parentInd == 0)
                    break;
                entry = try self.nodes.getOrPut(alloc, parentInd);
            }
            return .{
                .node = node,
                .box = nodeBox,
            };
        }   

        pub fn iterator(self: *const Self) Iterator {
            return .{
                .spatial = self,
            };
        }

        pub const Iterator = struct {
            spatial: *const Self,
            nodeIdx: u32 = 1,

            pub fn next(self: *const Iterator) ?NodeData {
                const node = self.spatial.nodes.getPtr(self.nodeIdx) orelse return null;
                const nodeIdx = self.nodeIdx;
                self.advanceNode(node);
                return .{
                    .node = node,
                    .box = self.spatial.nodeBoxFromIndex(nodeIdx),
                };
            }

            pub fn skipNodeAndChildren(self: *const Iterator) void {
                const node = self.spatial.nodes.getPtr(self.nodeIdx).?;
                self. advanceNextSibling(node);
            }

            fn advanceNode(self: *Iterator, node: *Node) void {
                if (node.childMask != 0) {
                    // descend to the first child if there exists one
                    const firstChildIdx = @ctz(node.childMask);
                    self.nodeIdx = (self.nodeIdx << N) | firstChildIdx;
                } else {
                    self.advanceNextSibling(node);
                }
            }

            fn advanceNextSibling(self: *Iterator, node: *Node) void {
                // go up until we find a node with unvisited children
                var curNode = node;
                while (true) {
                    var childIdx = self.nodeIdx & (NodesPerLevel - 1);
                    self.nodeIdx >>= N;
                    curNode = self.spatial.nodes.getPtr(self.nodeIdx) orelse return;
                    while (true) {
                        childIdx += 1;
                        if (childIdx >= N)
                            break;
                        if ((curNode.childMask & (1 << childIdx)) != 0) {
                            self.nodeIdx = (self.nodeIdx << N) | childIdx;
                            return;
                        }
                    }
                }
            }
        };
    };
}

pub fn GeomPtr(comptime N: u32, comptime T: type) type {
    return union(enum) {
        box: *Box,
        obox: *OBox,
        sphere: *Sphere,
        convex: *Convex,

        pub const Vec = vm.Vec(N, T);
        pub const Box = g.Box(N, T);
        pub const OBox = g.OrientedBox(N, T);
        pub const Sphere = g.Sphere(N, T);
        pub const Convex = g.Convex(N, T);
        pub const GJK = g.GJK(N, T);
        pub const Self = @This();

        pub fn getPtr(comptime G: type, geom: *G) Self {
            return switch (G) {
                Box => .{.box = geom},
                OBox => .{.obox = geom},
                Sphere => .{.sphere = geom},
                Convex => .{.convex = geom},
                else => unreachable
            };
        }

        pub fn getBox(self: Self) Box {
            return switch (self) {
                inline else => |geom| geom.getBox(),
            };
        }

        pub fn intersects(self: Self, rhs: Self) bool {
            return switch (self) {
                .box => |box_| switch (rhs) {
                    .box => |rhsBox| box_.intersects(rhsBox),
                    inline else => |rhsGeom| GJK.distance(Box, box_, @TypeOf(rhsGeom.*), rhsGeom) <= Vec.Eps,
                },
                else => |geom| switch (rhs) {
                    inline else => |rhsGeom| GJK.distance(@TypeOf(geom.*), geom, @TypeOf(rhsGeom.*), rhsGeom) <= Vec.Eps,
                }
            };
        }
    };
}

pub fn GeomTree(comptime N: u32, comptime T: type) type {
    return struct {
        spatial: Spatial,
        alloc: std.mem.Allocator,

        pub const Vec = vm.Vec(N, T);
        pub const Box = g.Box(N, T);
        pub const GeomP = GeomPtr(N, T);
        pub const GeomArr = std.ArrayListUnmanaged(GeomP);
        pub const Spatial = SpatialTree(N, T, GeomArr);
        pub const Self = @This();

        pub fn init(box: *const Box, maxLevels: u6, alloc_: std.mem.Allocator) Self {
            return .{
                .spatial = Spatial.init(box, maxLevels),
                .alloc = alloc_,
            };
        }

        pub fn deinit(self: *Self) void {
            self.spatial.clear(self.alloc);
        }

        pub fn addGeom(self: *Self, geom: GeomP) !void {
            const geomBox = geom.getBox();
            const nodeData = try self.spatial.getOrAddNode(geomBox, &GeomArr.empty, self.alloc);
            std.debug.assert(std.mem.find(GeomP, nodeData.node.data.items, .{geom}) == null);
            try nodeData.node.data.append(self.alloc, geom);
        }

        pub fn removeGeom(self: *Self, geom: GeomP) void {
            const geomBox = geom.getBox();
            const nodeData = try self.spatial.getNode(geomBox) orelse return;
            const geomIdx = std.mem.find(GeomP, nodeData.node.data.items, .{geom}) orelse return;
            _ = nodeData.node.data.swapRemove(geomIdx);
        }

        pub const GeomCallback = fn (context: anyopaque, geom: GeomP) void;
        pub fn forAllGeom(self: *const Self, context: anyopaque, callback: GeomCallback) void {
            var itNodes = self.spatial.iterator();
            while (itNodes.next()) |nodeData| {
                for (nodeData.node.data.items) |nodeGeom| {
                    callback(context, nodeGeom);
                }
            }
        }

        pub fn forIntersectingGeom(self: *const Self, geom: GeomP, context: anyopaque, callback: GeomCallback) void {
            var itNodes = self.spatial.iterator();
            while (itNodes.next()) |nodeData| {
                const nodeBoxPtr = GeomP.getPtr(Box, &nodeData.box);
                if (!geom.intersects(nodeBoxPtr)) {
                    itNodes.skipNodeAndChildren();
                    continue;
                }
                for (nodeData.node.data.items) |nodeGeom| {
                    if (geom.intersects(nodeGeom))
                        callback(context, nodeGeom);
                }
            }
        }
    };
}