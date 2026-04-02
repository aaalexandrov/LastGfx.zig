const std = @import("std");

var prng: std.Random.DefaultPrng = .init(blk: {
    const seed: u64 = 0xdeadbeefe1125679;
    //std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
    break :blk seed;
});

fn geomRandom() ZipTree.Rank {
    const rnd = @log(prng.random().float(f32)) / @log(0.5);
    return @intFromFloat(rnd);
    //    return prng.random().int(ZipTree.Rank);
}

const ZipTree = struct {
    root: ?*Node = null,
    numNodes: usize = 0,
    alloc: std.mem.Allocator,

    const Key = i32;
    const Rank = u16;

    const Node = struct {
        key: Key,
        rank: Rank = std.math.maxInt(Rank),
        left: ?*Node = null,
        right: ?*Node = null,
        parent: ?*Node = null,

        fn setLeft(self: *@This(), node: ?*Node) void {
            self.left = node;
            if (self.left) |l|
                l.parent = self;
        }
        fn setRight(self: *@This(), node: ?*Node) void {
            self.right = node;
            if (self.right) |r|
                r.parent = self;
        }

        fn leftMostChild(self: ?*@This()) ?*Node {
            var child: *@This() = if (self) |s| s else return null;
            while (child.left) |left| {
                child = left;
            }
            return child;
        }

        pub fn next(self: *@This()) ?*Node {
            var node: ?*Node = Node.leftMostChild(self.right);
            if (node != null)
                return node;
            node = self;
            while (node != null and node.?.parent != null) {
                const parent = node.?.parent.?;
                if (parent.left == node)
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
            self.clearNode(n.left);
            self.clearNode(n.right);
            self.alloc.destroy(n);
        }
    }

    pub fn insert(self: *Self, key: Key) !void {
        const node = try self.alloc.create(Node);
        node.* = .{ .key = key, .rank = geomRandom() };
        self.root = insertNode(self.root, node);
        self.root.?.parent = null;
        self.numNodes += 1;
    }

    fn insertNode(root: ?*Node, node: *Node) *Node {
        if (root) |r| {
            if (node.key < r.key or node.key == r.key and node.rank > r.rank) {
                if (insertNode(r.left, node) == node) {
                    if (node.rank < r.rank) {
                        r.setLeft(node);
                    } else {
                        r.setLeft(node.right);
                        node.setRight(root);
                        return node;
                    }
                }
            } else {
                if (insertNode(r.right, node) == node) {
                    if (node.rank <= r.rank) {
                        r.setRight(node);
                    } else {
                        r.setRight(node.left);
                        node.setLeft(root);
                        return node;
                    }
                }
            }
            return r;
        } else {
            return node;
        }
    }

    pub fn lower_bound(self: *Self, key: Key) ?*Node {
        var lesserParent: ?*Node = null;
        var curNode = self.root;
        while (curNode) |cur| {
            if (key == cur.key)
                return cur;
            if (key < cur.key) {
                curNode = cur.left;
            } else {
                lesserParent = curNode;
                curNode = cur.right;
            }
        }
        if (lesserParent) |lesser| {
            while (lesser.right) |lesserRight| {
                lesser = lesserRight;
            }
            return lesser;
        }
        return null;
    }

    pub fn find(self: *Self, key: Key) ?*Node {
        var curNode = self.root;
        while (curNode) |cur| {
            if (key == cur.key)
                return cur;
            curNode = if (key < cur.key) cur.left else cur.right;
        }
        return null;
    }

    pub fn firstNode(self: *Self) ?*Node {
        return Node.leftMostChild(self.root);
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
        const x = if (xnode) |xn| xn else 
            return ynode;
        const y = if (ynode) |yn| yn else
            return xnode;
        if (x.rank < y.rank) {
            y.setLeft(zipNodes(xnode, y.left));
            return ynode;
        } else {
            x.setRight(zipNodes(x.right, ynode));
            return xnode;
        }
    }

    fn deleteNode(node: *Node, root: *Node) *Node {
        if (node == root)
            return zipNodes(root.left, root.right).?;
        if (node.key < root.key) {
            if (node == root.left) {
                root.setLeft(zipNodes(root.left.?.left, root.left.?.right));
            } else {
                _ = deleteNode(node, root.left.?);
            }
        } else {
            if (node == root.right) {
                root.setRight(zipNodes(root.right.?.left, root.right.?.right));
            } else {
                _ = deleteNode(node, root.right.?);
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
        if (n.left) |l| {
            const sameChildren = n.left == n.right;
            const badParent = l.parent != n;
            if (sameChildren or badParent or l.key >= n.key or l.rank >= n.rank or !validateNode(l)) {
                std.log.info("failed left, n.key = {}, n.rank = {}, l.key = {}, l.rank = {}, bad parent = {}, same children = {}", .{ n.key, n.rank, l.key, l.rank, badParent, sameChildren });
                return false;
            }
        }
        if (n.right) |r| {
            const badParent = r.parent != n;
            if (badParent or r.key < n.key or r.rank > n.rank or !validateNode(r)) {
                std.log.info("failed right, n.key = {}, n.rank = {}, r.key = {}, r.rank = {}, bad parent = {}", .{ n.key, n.rank, r.key, r.rank, badParent });
                return false;
            }
        }
        return true;
    }

    pub fn getHeight(self: *Self) u32 {
        return getHeightNode(self.root);
    }

    fn getHeightNode(node: ?*Node) u32 {
        if (node) |n| {
            return @max(getHeightNode(n.left), getHeightNode(n.right)) + 1;
        }
        return 0;
    }
};

pub fn ZipTest(alloc: std.mem.Allocator) !void {
    var zip = ZipTree.init(alloc);
    defer zip.deinit();

    try std.testing.expect(zip.validate());

    var valueArr = try std.array_list.Managed(ZipTree.Key).initCapacity(alloc, 0);
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
    try zip.insert(valueArr.getLast());
    try std.testing.expect(zip.validate());


    for (0..1000) |i| {
        try valueArr.append(@intCast(i));
        try zip.insert(valueArr.getLast());
        try std.testing.expect(zip.validate());

        try valueArr.append(prng.random().intRangeAtMost(ZipTree.Key, 0, 10000));
        try zip.insert(valueArr.getLast());
        try std.testing.expect(zip.validate());
    }

    std.log.info("Tree height: {}, root rank: {}, elements: {}", .{ zip.getHeight(), zip.root.?.rank, zip.size() });

    std.mem.sort(ZipTree.Key, valueArr.items, {}, comptime std.sort.asc(ZipTree.Key));

    const n63 = zip.find(63);
    try std.testing.expect(n63 != null);

    var node = zip.firstNode();
    var count: u32 = 0;
    var prevKey: ZipTree.Key = std.math.minInt(ZipTree.Key);
    while (node) |n| {
        try std.testing.expect(prevKey <= n.key);
        try std.testing.expectEqual(valueArr.items[count], n.key);
        prevKey = n.key;
        count += 1;
        node = n.next();
    }
    try std.testing.expectEqual(zip.size(), count);

    try std.testing.expect(zip.erase(63));
    try std.testing.expect(zip.validate());
}

test "ZipTree" {
    try ZipTest(std.testing.allocator);
}
