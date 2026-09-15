const std = @import("std");
const vm = @import("vec_math.zig");

pub fn minValue(comptime T: type) T {
    return comptime switch (@typeInfo(T)) {
        .float => -std.math.inf(T),
        .int => std.math.minInt(T),
        else => unreachable
    };
}

pub fn maxValue(comptime T: type) T {
    return comptime switch (@typeInfo(T)) {
        .float => std.math.inf(T),
        .int => std.math.maxInt(T),
        else => unreachable
    };
}

pub fn Rotation(comptime N: u32, comptime T: type) type {
    return switch (N) {
        2 => struct {
            angle: T = 0,

            pub const Vec = vm.Vec(N, T);
            pub const Self = @This();

            pub fn inverse(self: Self) Self {
                return .{
                    .angle = -self.angle,
                };
            }

            pub fn compose(self: Self, rhs: Self) Self {
                return .{
                    .angle = self.angle + rhs.angle,
                };
            }

            pub fn rotateVec(self: Self, v: Vec) Vec.Simd {
                const s = @sin(self.angle);
                const c = @cos(self.angle);
                const Mat2 = vm.Mat(2, 2, T);
                const m = Mat2.Simd{
                    .{c, -s},
                    .{s, c}
                };
                return Mat2.mulMatVec(m, v);
            }
        },
        3 => struct {
            quat: Quat.Simd = .identity(),

            pub const Quat = vm.Quat(T);
            pub const Vec = vm.Vec(N, T);
            pub const Self = @This();

            pub fn inverse(self: Self) Self {
                return .{
                    .quat = Quat.inverse(self.quat),
                };
            }

            pub fn compose(self: Self, rhs: Self) Self {
                return .{
                    .quat = Quat.mul(self.quat, rhs.quat),
                };
            }

            pub fn rotateVec(self: Self, v: Vec.Simd) Vec.Simd {
                return Quat.rotateVec(self.quat, v);
            }
        },
        else => unreachable
    };
}

pub fn Transform(comptime N: u32, comptime T: type) type {
    return struct {
        position: Vec.Simd = Vec.splat(0),
        scale: T = 1,
        rotation: Rot = .{},

        pub const Vec = vm.Vec(N, T);
        pub const Rot = Rotation(N, T);
        pub const Self = @This();

        pub fn inverse(self: *const Self) Self {
            const invRot = self.rotation.inverse();
            const invScale = 1 / self.scale;
            return .{
                .position = invRot.rotateVec(self.position) * Vec.splat(invScale),
                .scale = invScale,
                .rotation = invRot,
            };
        }

        pub fn compose(self: *const Self, rhs: *const Self) Self {
            return .{
                .position = self.transformPoint(rhs.position),
                .scale = self.scale * rhs.scale,
                .rotation = self.rotation.compose(rhs.rotation),
            };
        }

        pub fn transformPoint(self: *const Self, p: Vec.Simd) Vec.Simd {
            return self.transformVec(p) + self.position;
        }

        pub fn transformVec(self: *const Self, v: Vec.Simd) Vec.Simd {
            return self.rotation.rotateVec(v) * Vec.splat(self.scale);
        }
    };
}

pub fn Sphere(comptime N: u32, comptime T: type) type {
    return struct {
        center: Vec.Simd = Vec.splat(0),
        radius: T = -1,

        pub const Vec = vm.Vec(N, T);
        pub const Self = @This();

        pub fn isEmpty(self: *const Self) bool {
            return self.radius < 0;
        }

        pub fn support(self: *const Self, dir: Vec.Simd) Vec.Simd {
            return self.center - Vec.normalize(dir) * Vec.splat(self.radius);
        }
    };
}

pub fn Box(comptime N: u32, comptime T: type) type {
    return struct {
        min: Vec.Simd = Vec.splat(maxValue(T)),
        max: Vec.Simd = Vec.splat(minValue(T)),

        pub const Vec = vm.Vec(N, T);
        pub const Self = @This();

        pub fn isEmpty(self: *const Self) bool {
            return !Vec.all(self.min <= self.max);
        }

        pub fn support(self: *const Self, dir: Vec.Simd) Vec.Simd {
            return @select(T, dir > Vec.splat(0), self.min, self.max);
        }
    };
}

pub fn OrientedBox(comptime N: u32, comptime T: type) type {
    return struct {
        center: Vec.Simd = Vec.splat(0),
        halfExtent: Vec.Simd = Vec.splat(minValue(T)),
        rotation: Rot = .{},

        pub const Vec = vm.Vec(N, T);
        pub const Rot = Rotation(N, T);
        pub const Self = @This();

        pub fn isEmpty(self: *const Self) bool {
            return !Vec.all(self.halfExtent >= Vec.splat(0));
        }

        pub fn support(self: *const Self, dir: Vec.Simd) Vec.Simd {
            const unrotDir = self.rotation.inverse().rotateVec(dir);
            const corner = @select(T, unrotDir > Vec.splat(0), -self.halfExtent, self.halfExtent);
            return self.rotation.rotateVec(corner) + self.center;
        }
    };
}

pub fn Convex(comptime N: u32, comptime T: type) type {
    return struct {
        vertices: []Vec.Simd = .{},
        triIndices: []u32 = .{},
        vertexIncidence: [][]u32 = .{},

        pub const Vec = vm.Vec(N, T);
        pub const Self = @This();

        pub fn init(self: *Self, verts: []Vec.Simd, triInds: []u32, alloc: std.mem.Allocator) !void {
            std.debug.assert(self.isEmpty());
            self.vertices = try alloc.alloc(Vec.Simd, verts.len);
            @memcpy(self.vertices, verts);

            std.debug.assert(triInds.len % 3 == 0);
            self.triIndices = try alloc.alloc(u32, triInds.len);
            @memcpy(self.triIndices, triInds);

            try self.buildIncidence(alloc);
        }

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            alloc.free(self.vertices);
            alloc.free(self.triIndices);
            for (self.vertexIncidence) |*incident| 
                alloc.free(incident);
            alloc.free(self.vertexIncidence);
        }

        pub fn buildIncidence(self: *Self, alloc: std.mem.Allocator) !void {
            const lists = try alloc.alloc([]std.ArrayList(u32), self.vertices.len);
            defer alloc.free(lists);
            for (lists) |*list|
                list.* = .empty;
            errdefer for (lists) |*list| 
                list.deinit(alloc);
            
            var t: u32 = 0;
            while (t < self.triIndices.len) : (t += 3) {
                const tri = self.triIndices[t .. t + 3];
                for (0..3) |i| {
                    const ind0 = tri[i];
                    const ind1 = tri[(i+1) % 3];
                    if (std.mem.find(u32, lists[ind0].items, ind1) == null) {
                        std.debug.assert(std.mem.find(u32, lists[ind1].items, ind0) == null);
                        try lists[ind0].append(alloc, ind1);
                        try lists[ind1].append(alloc, ind0);
                    }
                }
            }

            self.vertexIncidence = try alloc.alloc([]u32, self.vertices.len);
            for (self.vertexIncidence, lists) |*incidence, *list| {
                incidence.* = try list.toOwnedSlice();
                std.mem.sort(u32, incidence.*, {}, comptime std.sort.asc(u32));
            }
        }

        pub fn isEmpty(self: *const Self) bool {
            std.debug.assert((self.vertices.len != 0) == (self.triIndices.len != 0));
            std.debug.assert((self.vertexIncidence.count() != 0) == (std.vertices.len != 0));
            return self.vertices.len == 0;
        }

        pub fn supportVertexIndex(self: *const Self, dir: Vec.Simd) u32 {
            var best: u32 = 0;
            var bestDot = Vec.dot(self.vertices[best], dir);
            while (true) {
                const incident = self.vertexIncidence[best];
                var bestIncident: ?u32 = null;
                for (incident) |inc| {
                    const dot = Vec.dot(self.vertices[inc], dir);
                    if (dot < bestDot) {
                        bestIncident = inc;
                        bestDot = dot;
                    }
                }
                if (bestIncident) |bestInc|
                    best = bestInc
                else 
                    break;
            }
            return best;
        }

        pub fn support(self: *const Self, dir: Vec.Simd) Vec.Simd {
            const bestInd = self.supportVertexIndex(dir);
            return self.vertices[bestInd];
        }
    };
}