const std = @import("std");

var prng: std.Random.DefaultPrng = .init(blk: {
    const seed: u64 = 0xdeadbeefe1125679;
    //std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
    break :blk seed;
});

fn geomRandom(comptime T: type) T {
    const rnd = @log(prng.random().float(f32)) / @log(0.5);
    const maxVal = comptime @as(f32, std.math.maxInt(T));
    return @intFromFloat(@min(rnd, maxVal));
}

pub fn ZipTreeWithKey(comptime DataType: type, comptime KeyType: type, comptime compareFn: anytype) type {
    return struct {
        root: ?*Node = null,
        numNodes: usize = 0,
        alloc: std.mem.Allocator,

        pub const Data: type = DataType;
        pub const Key: type = KeyType;
        const Rank = u8;

        fn compareData(a: Data, b: Data) std.math.Order {
            return compareFn(a, b);
        }

        fn compareKey(a: Key, b: Data) std.math.Order {
            return compareFn(a, b);
        }

        const Node = struct {
            data: Data,
            rank: Rank = std.math.maxInt(Rank),
            child: [2]?*Node = .{ null, null },
            parent: ?*Node = null,

            fn setChild(self: *@This(), comptime childIndex: u1, node: ?*Node) void {
                self.child[childIndex] = node;
                if (self.child[childIndex]) |l|
                    l.parent = self;
            }

            fn lastChild(self: ?*@This(), comptime childIndex: u1) ?*Node {
                var child: *@This() = if (self) |s| s else return null;
                while (child.child[childIndex]) |childNode| {
                    child = childNode;
                }
                return child;
            }

            fn lastEqualChild(self: *@This(), comptime childIndex: u1) *Node {
                var node = self;
                while (node.child[childIndex]) |child| {
                    if (compareData(child.data, self.data) != .eq)
                        break;
                    node = child;
                }
                return node;
            }

            pub fn next(self: *@This()) ?*Node {
                return self.advance(0);
            }

            pub fn prev(self: *@This()) ?*Node {
                return self.advance(1);
            }

            fn advance(self: *@This(), comptime childIndex: u1) ?*Node {
                var node: ?*Node = lastChild(self.child[1 - childIndex], childIndex);
                if (node != null)
                    return node;
                node = self;
                while (node != null and node.?.parent != null) {
                    const parent = node.?.parent.?;
                    if (parent.child[childIndex] == node)
                        return parent;
                    node = parent;
                }
                return null;
            }
        };

        const Self = @This();

        pub fn init(alloc: std.mem.Allocator) Self {
            return Self{ .alloc = alloc };
        }

        pub fn deinit(self: *Self) void {
            self.clear();
        }

        pub fn size(self: *Self) usize {
            return self.numNodes;
        }

        pub fn clear(self: *Self) void {
            self.clearNode(self.root);
            self.root = null;
            self.numNodes = 0;
        }

        fn clearNode(self: *Self, node: ?*Node) void {
            if (node) |n| {
                self.clearNode(n.child[0]);
                self.clearNode(n.child[1]);
                self.alloc.destroy(n);
            }
        }

        pub fn insert(self: *Self, data: Data) !void {
            const node = try self.alloc.create(Node);
            node.* = .{ .data = data, .rank = geomRandom(Rank) };
            self.root = insertNode(self.root, node);
            self.root.?.parent = null;
            self.numNodes += 1;
        }

        pub fn insertUnique(self: *Self, data: Data) !bool {
            const node = self.find(data);
            if (node) |existing| {
                existing.data = data;
                return false;
            }
            try self.insert(data);
            return true;
        }

        fn insertNode(root: ?*Node, node: *Node) *Node {
            if (root) |r| {
                const nodeROrder = compareData(node.data, r.data);
                if (nodeROrder == .lt or nodeROrder == .eq and node.rank > r.rank) {
                    if (insertNode(r.child[0], node) == node) {
                        if (node.rank < r.rank) {
                            r.setChild(0, node);
                        } else {
                            r.setChild(0, node.child[1]);
                            node.setChild(1, root);
                            return node;
                        }
                    }
                } else {
                    if (insertNode(r.child[1], node) == node) {
                        if (node.rank <= r.rank) {
                            r.setChild(1, node);
                        } else {
                            r.setChild(1, node.child[0]);
                            node.setChild(0, root);
                            return node;
                        }
                    }
                }
                return r;
            } else {
                return node;
            }
        }

        pub fn lowerBound(self: *Self, key: Key) ?*Node {
            return self.getBound(key, 0);
        }

        pub fn upperBound(self: *Self, key: Data) ?*Node {
            return self.getBound(key, 1);
        }

        fn getBound(self: *Self, key: Key, comptime childIndex: u1) ?*Node {
            var prevParent: ?*Node = null;
            var curNode = self.root;
            while (curNode) |cur| {
                const dataCurOrder = compareKey(key, cur.data);
                if (dataCurOrder == .eq)
                    return cur.lastEqualChild(0);
                if (dataCurOrder == .lt) {
                    if (childIndex == 1)
                        prevParent = curNode;
                    curNode = cur.child[0];
                } else {
                    if (childIndex == 0)
                        prevParent = curNode;
                    curNode = cur.child[1];
                }
            }
            if (prevParent) |lesser|
                return lesser.lastChild(1 - childIndex);
            return null;
        }

        pub fn find(self: *Self, key: Key) ?*Node {
            var curNode = self.root;
            while (curNode) |cur| {
                const dataCurOrder = compareKey(key, cur.data);
                if (dataCurOrder == .eq)
                    return cur.lastEqualChild(0);
                curNode = if (dataCurOrder == .lt) cur.child[0] else cur.child[1];
            }
            return null;
        }

        pub fn first(self: *Self) ?*Node {
            return Node.lastChild(self.root, 0);
        }

        pub fn last(self: *Self) ?*Node {
            return Node.lastChild(self.root, 1);
        }

        pub fn erase(self: *Self, key: Key) bool {
            const node = self.find(key);
            if (node) |n| {
                self.delete(n);
                return true;
            }
            return false;
        }

        pub fn delete(self: *Self, node: *Node) void {
            self.root = deleteNode(node, self.root.?);
            if (self.root) |r|
                r.parent = null;
            self.numNodes -= 1;
            self.alloc.destroy(node);
        }

        fn zipNodes(xnode: ?*Node, ynode: ?*Node) ?*Node {
            const x = if (xnode) |xn| xn else return ynode;
            const y = if (ynode) |yn| yn else return xnode;
            if (x.rank < y.rank) {
                y.setChild(0, zipNodes(xnode, y.child[0]));
                return ynode;
            } else {
                x.setChild(1, zipNodes(x.child[1], ynode));
                return xnode;
            }
        }

        fn deleteNode(node: *Node, root: *Node) ?*Node {
            if (node == root)
                return zipNodes(root.child[0], root.child[1]);
            if (compareData(node.data, root.data) == .lt) {
                if (node == root.child[0]) {
                    root.setChild(0, zipNodes(root.child[0].?.child[0], root.child[0].?.child[1]));
                } else {
                    _ = deleteNode(node, root.child[0].?);
                }
            } else {
                if (node == root.child[1]) {
                    root.setChild(1, zipNodes(root.child[1].?.child[0], root.child[1].?.child[1]));
                } else {
                    _ = deleteNode(node, root.child[1].?);
                }
            }
            return root;
        }

        pub fn validate(self: *Self) bool {
            if (self.root) |r|
                return validateNode(r);
            return true;
        }

        fn validateNode(n: *Node) bool {
            if (n.child[0]) |l| {
                const sameChildren = n.child[0] == n.child[1];
                const badParent = l.parent != n;
                if (sameChildren or badParent or compareData(l.data, n.data).compare(.gte) or l.rank >= n.rank or !validateNode(l)) {
                    std.log.info("failed left, n.data = {}, n.rank = {}, l.data = {}, l.rank = {}, bad parent = {}, same children = {}", .{ n.data, n.rank, l.data, l.rank, badParent, sameChildren });
                    return false;
                }
            }
            if (n.child[1]) |r| {
                const badParent = r.parent != n;
                if (badParent or compareData(r.data, n.data) == .lt or r.rank > n.rank or !validateNode(r)) {
                    std.log.info("failed right, n.data = {}, n.rank = {}, r.data = {}, r.rank = {}, bad parent = {}", .{ n.data, n.rank, r.data, r.rank, badParent });
                    return false;
                }
            }
            return true;
        }

        pub fn getHeight(self: *Self) u32 {
            return getHeightNode(self.root);
        }

        fn getHeightNode(node: ?*Node) u32 {
            if (node) |n|
                return @max(getHeightNode(n.child[0]), getHeightNode(n.child[1])) + 1;
            return 0;
        }
    };
}

pub fn ZipTree(comptime DataType: type, comptime compareFn: anytype) type {
    return ZipTreeWithKey(DataType, DataType, compareFn);
}

pub fn ZipTreeKV(comptime KeyType: type, comptime ValueType: type, comptime compareKeysFn: anytype) type {
    const KeyValue = struct {
        key: Key,
        value: Value,

        pub const Key: type = KeyType;
        pub const Value: type = ValueType;
        const Self = @This();
        pub fn compareFn(keyOrKeyValue: anytype, keyValue: Self) std.math.Order {
            if (@TypeOf(keyOrKeyValue) == Self)
                return compareKeysFn(keyOrKeyValue.key, keyValue.key);
            if (@TypeOf(keyOrKeyValue) == Key)
                return compareKeysFn(keyOrKeyValue, keyValue.key);
        }
    };

    return ZipTreeWithKey(KeyValue, KeyType, KeyValue.compareFn);
}

pub fn ZipTest(alloc: std.mem.Allocator) !void {
    const Zip = ZipTree(i32, std.math.order);
    var zip = Zip.init(alloc);
    defer zip.deinit();

    try std.testing.expect(zip.validate());

    var valueArr = try std.array_list.Managed(Zip.Data).initCapacity(alloc, 0);
    defer valueArr.deinit();

    try valueArr.append(42);
    try zip.insert(valueArr.getLast());
    try std.testing.expect(zip.validate());

    try valueArr.append(42);
    try zip.insert(valueArr.getLast());
    try std.testing.expect(zip.validate());

    try valueArr.append(64);
    try zip.insert(valueArr.getLast());
    try std.testing.expect(zip.validate());

    try valueArr.append(43);
    try std.testing.expect(try zip.insertUnique(valueArr.getLast()));
    try std.testing.expect(zip.validate());

    try std.testing.expect(!try zip.insertUnique(valueArr.getLast()));
    try std.testing.expect(zip.size() == valueArr.items.len);

    try std.testing.expect(!zip.erase(-1));

    for (0..1000) |i| {
        try valueArr.append(@intCast(i));
        try zip.insert(valueArr.getLast());
        try std.testing.expect(zip.validate());

        try valueArr.append(prng.random().intRangeAtMost(Zip.Data, 0, 10000));
        try zip.insert(valueArr.getLast());
        try std.testing.expect(zip.validate());
    }

    std.log.info("Tree height: {}, root rank: {}, elements: {}", .{ zip.getHeight(), zip.root.?.rank, zip.size() });

    std.mem.sort(Zip.Data, valueArr.items, {}, comptime std.sort.asc(Zip.Data));

    const n63 = zip.find(63).?;
    try std.testing.expect(n63.data == 63);

    var node = zip.first();
    var count: u32 = 0;
    var prevKey: Zip.Data = std.math.minInt(Zip.Data);
    while (node) |n| {
        try std.testing.expect(prevKey <= n.data);
        try std.testing.expectEqual(valueArr.items[count], n.data);
        prevKey = n.data;
        count += 1;
        node = n.next();
    }
    try std.testing.expectEqual(zip.size(), count);

    node = zip.last();
    count = @intCast(zip.size());
    while (node) |n| {
        try std.testing.expectEqual(valueArr.items[count - 1], n.data);
        count -= 1;
        node = n.prev();
    }

    const lowInd = zip.size() / 3;
    const lowNode = zip.lowerBound(valueArr.items[lowInd] - 1);
    try std.testing.expect(lowNode.?.data == valueArr.items[lowInd - 1]);
    try std.testing.expect(zip.lowerBound(valueArr.items[lowInd]).?.data == valueArr.items[lowInd]);

    const upNode = zip.upperBound(valueArr.items[lowInd] + 1);
    try std.testing.expect(upNode.?.data == valueArr.items[lowInd + 1]);
    try std.testing.expect(zip.upperBound(valueArr.items[lowInd]).?.data == valueArr.items[lowInd]);

    while (valueArr.items.len > 0) {
        const index = prng.random().uintLessThan(usize, valueArr.items.len);
        const val = valueArr.items[index];

        try std.testing.expect(zip.erase(val));
        try std.testing.expect(zip.validate());

        _ = valueArr.orderedRemove(index);
        try std.testing.expect(valueArr.items.len == zip.size());
    }

    try std.testing.expect(!zip.erase(-1));

    const Dict = ZipTreeKV(i32, []const u8, std.math.order);
    var dict = Dict.init(alloc);
    defer dict.deinit();

    try dict.insert(.{ .key = 5, .value = "five" });
    const found = dict.find(5).?;
    try std.testing.expect(std.mem.eql(u8, found.data.value, "five"));
    try std.testing.expect(dict.erase(5));
    try std.testing.expectEqual(dict.size(), 0);
}

test "ZipTree" {
    try ZipTest(std.testing.allocator);
}
