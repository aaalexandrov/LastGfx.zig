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

            pub fn equal(self: Self, rhs: Self, eps: T) bool {
                return std.math.approxEqAbs(T, self.angle, rhs.angle, eps);
            }
        },
        3 => struct {
            quat: Quat.Simd = Quat.identity(),

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

            pub fn equal(self: Self, rhs: Self, eps: T) bool {
                return Quat.equal(self.quat, rhs.quat, eps);
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
        pub const Sphere_ = Sphere(N, T);
        pub const Box_ = Box(N, T);
        pub const OBox = OrientedBox(N, T);
        pub const Self = @This();

        pub fn inverse(self: *const Self) Self {
            const invRot = self.rotation.inverse();
            const invScale = 1 / self.scale;
            return .{
                .position = -invRot.rotateVec(self.position) * Vec.splat(invScale),
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

        pub fn transformSphere(self: *const Self, sphere: *const Sphere_) Sphere_ {
            return .{
                .center = self.transformPoint(sphere.center),
                .radius = self.scale * sphere.radius,
            };
        }

        pub fn transformBoxAsOBox(self: *const Self, box: *const Box_) OBox {
            const halfExtent = box.size() * 0.5;
            return .{
                .center = self.transformPoint(box.min + halfExtent),
                .halfExtent = halfExtent * Vec.splat(self.scale),
                .rotation = self.rotation,
            };
        }

        pub fn transformBox(self: *const Self, box: *const Box_) Box_ {
            return self.transformBoxAsOBox(box).getBox();
        }

        pub fn transformOBox(self: *const Self, obox: *const OBox) OBox {
            return .{
                .center = self.transformPoint(obox.center),
                .halfExtent = obox.halfExtent * Vec.splat(self.scale),
                .rotation = self.rotation.compose(obox.rotation),
            };
        }

        pub fn isEqual(self: *const Self, rhs: *const Self, eps: T) bool {
            return std.math.approxEqAbs(T, self.scale, rhs.scale, eps)
                and Vec.equal(self.position, rhs.position, eps)
                and self.rotation.equal(rhs.rotation, eps);
        }
    };
}

pub fn TestTransform() !void {
    const Transform3f = Transform(3, f32);
    const Vec3f = vm.Vec(3, f32);
    const Quatf = vm.Quat(f32);

    const ident: Transform3f = .{};
    const identInv = ident.inverse();
    try std.testing.expectEqualDeep(ident, identInv);

    const trans: Transform3f = .{
        .rotation = .{.quat = Quatf.axisAngle(Vec3f.Simd{0, 0, 1}, std.math.pi * 0.5) },
        .scale = 2,
        .position = Vec3f.Simd{100, 0, 0},
    };
    const transInv = trans.inverse();
    const transInvCompose = trans.compose(&transInv);
    try std.testing.expect(ident.isEqual(&transInvCompose, 1e-4));
    try std.testing.expect(ident.isEqual(&transInv.compose(&trans), 1e-4));
}

test "Transform" {
    try TestTransform();
}

pub fn Sphere(comptime N: u32, comptime T: type) type {
    return struct {
        center: Vec.Simd = Vec.splat(0),
        radius: T = -1,

        pub const Vec = vm.Vec(N, T);
        pub const BBox = Box(N, T);
        pub const Self = @This();

        pub fn isEmpty(self: *const Self) bool {
            return self.radius < 0;
        }

        pub fn getBox(self: *const Self) BBox {
            const r = Vec.splat(self.radius);
            return .{
                .min = self.center - r,
                .max = self.center + r,
            };
        }

        pub fn anyPoint(self: *const Self) Vec.Simd {
            return self.center;
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

        pub const NumCorners: u32 = 1 << N;
        pub const Vec = vm.Vec(N, T);
        pub const Self = @This();

        pub fn isEmpty(self: *const Self) bool {
            return !Vec.all(self.min <= self.max);
        }

        pub fn size(self: *const Self) Vec.Simd {
            return self.max - self.min;
        }

        pub fn center(self: *const Self) Vec.Simd {
            return self.min + self.size() / 2;
        }

        pub fn getBox(self: *const Self) Self {
            return self.*;
        }

        pub fn contains(self: *const Self, contained: *const Self) bool {
            return Vec.all(self.min <= contained.min) and Vec.all(contained.max <= self.max);
        }

        pub fn intersects(self: *const Self, rhs: *const Self) bool {
            return !getIntersection(self, rhs).isEmpty();
        }

        pub fn getIntersection(self: *const Self, rhs: *const Self) Self {
            return .{
                .min = @max(self.min, rhs.min),
                .max = @min(self.max, rhs.max),
            };
        }

        pub fn getUnion(self: *const Self, rhs: *const Self) Self {
            if (self.isEmpty())
                return rhs.*;
            if (rhs.isEmpty())
                return self.*;
            return .{
                .min = @min(self.min, rhs.min),
                .max = @max(self.max, rhs.max),
            };
        }

        pub fn anyPoint(self: *const Self) Vec.Simd {
            return (self.min + self.max) * Vec.splat(0.5);
        }

        pub fn support(self: *const Self, dir: Vec.Simd) Vec.Simd {
            return @select(T, dir > Vec.splat(0), self.min, self.max);
        }

        pub fn addPoint(self: *const Self, p: Vec.Simd) Self {
            return .{
                .min = @min(self.min, p),
                .max = @max(self.max, p),
            };
        }

        pub fn cornerSelector(cornerIdx: u32) Vec.BSimd {
            std.debug.assert(cornerIdx < NumCorners);
            var selector: Vec.BSimd = undefined;
            inline for (0..N) |i|
                selector[i] = (cornerIdx & (1<<i)) != 0;
            return selector;
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
        pub const BBox = Box(N, T);
        pub const Self = @This();

        pub fn isEmpty(self: *const Self) bool {
            return !Vec.all(self.halfExtent >= Vec.splat(0));
        }

        pub fn getBox(self: *const Self) BBox {
            var box: BBox = .{};
            for (0..BBox.NumCorners) |c| {
                const selector = BBox.cornerSelector(@intCast(c));
                const cornerMul = @select(T, selector, Vec.splat(1), Vec.splat(-1));
                const rotCorner = self.rotation.rotateVec(self.halfExtent * cornerMul);
                box = box.addPoint(self.center + rotCorner);
            }
            return box;
        }

        pub fn anyPoint(self: *const Self) Vec.Simd {
            return self.center;
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
        pub const BBox = Box(N, T);
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

        pub fn getBox(self: *const Self) BBox {
            var box: BBox = .{};
            for (self.vertices) |v|
                box = box.addPoint(v);
            return box;
        }

        pub fn anyPoint(self: *const Self) Vec.Simd {
            return self.vertices[0];
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

pub fn Line(comptime N: u32, comptime T: type) type {
    return struct {
        origin: Vec.Simd = Vec.splat(0),
        direction: Vec.Simd = Vec.splat(0),

        pub const Vec = vm.Vec(N, T);
        pub const Self = @This();

        pub fn fromPoints(p0: Vec.Simd, p1: Vec.Simd) Self {
            return .{
                .origin = p0,
                .direction = p1 - p0,
            };
        }

        pub fn getPoint(self: *const Self, t: T) Vec.Simd {
            return self.origin + self.direction * Vec.splat(t);
        }

        pub fn getProjectionParam(self: *const Self, v: Vec.Simd) T {
            const dotVO_D = Vec.dot(v - self.origin, self.direction);
            const dotDD = Vec.dot(self.direction, self.direction);
            const t = dotVO_D / dotDD;
            return if (std.math.isFinite(t)) t else 0;
        }

        pub fn closestPoint(self: *const Self, v: Vec.Simd) Vec.Simd {
            return self.getPoint(self.getProjectionParam(v));
        }
    };
}

pub fn Triangle(comptime N: u32, comptime T: type) type {
    return struct {
        points: [3]Vec.Simd = std.mem.zeroes([3]Vec.Simd),

        pub const Vec = vm.Vec(N, T);
        pub const Edge = Line(N, T);
        pub const Vec3 = vm.Vec(3, T);
        pub const Self = @This();

        pub fn getPoint(self: *const Self, bary: Vec3.Simd) Vec.Simd {
            return self.points[0] * Vec.splat(bary[0]) 
                + self.points[1] * Vec.splat(bary[1])
                + self.points[2] * Vec.splat(bary[2]);
        }

        pub fn barycentricCoordsFromPoints(triPoints: *const [3]Vec.Simd, v: Vec.Simd) Vec3.Simd {
            const p01 = triPoints.*[1] - triPoints.*[0];
            const p02 = triPoints.*[2] - triPoints.*[0];
            const v0 = v - triPoints.*[0];
            const dotP01 = Vec.dot(p01, p01);
            const dotP02 = Vec.dot(p02, p02);
            const dotVP1 = Vec.dot(v0, p01);
            const dotVP2 = Vec.dot(v0, p02);
            const dotP12 = Vec.dot(p01, p02);
            const invDenom = 1 / (dotP01 * dotP02 - dotP12 * dotP12);
            var bary: Vec3.Simd = undefined;
            if (!std.math.isFinite(invDenom)) {
                // degenerate triangle
                const dirIsP01 = dotP01 > dotP02;
                var param = if (dirIsP01) 
                        dotVP1 / dotP01 
                    else 
                        dotVP2 / dotP02;
                if (!std.math.isFinite(param)) 
                    param = 0;
                bary = Vec3.Simd{1 - param, 0, param};
                if (dirIsP01)
                    std.mem.swap(T, &bary[1], &bary[2]);
            } else {
                const c1 = (dotP02 * dotVP1 - dotP12 * dotVP2) * invDenom;
                const c2 = (dotP01 * dotVP2 - dotP12 * dotVP1) * invDenom;
                bary = Vec3.Simd{1 - c1 - c2, c1, c2};
            }
            return bary;
        }

        pub fn barycentricCoords(self: *const Self, v: Vec.Simd) Vec3.Simd {
            return barycentricCoordsFromPoints(&self.points, v);
        }

        fn prevIndex(i: u32) u32 {
            return switch (i) {
                0 => 2,
                1 => 0,
                2 => 1,
                else => unreachable
            };
        }

        fn nextIndex(i: u32) u32 {
            return switch (i) {
                0 => 1,
                1 => 2,
                2 => 0,
                else => unreachable
            };
        }

        pub fn clampBaryFromPoints(triPoints: *const [3]Vec.Simd, p: Vec.Simd, bary: Vec3.Simd) Vec3.Simd {
            const baryNegative = bary < Vec3.splat(0);
            const numNegative = @reduce(.Add, @as(@Vector(3, i32), @intFromBool(baryNegative)));
            return switch (numNegative) {
                2 => @select(T, baryNegative, Vec3.splat(0), Vec3.splat(1)),
                1 => single: {
                    const negInd = Vec.minElemIndex(bary);
                    const prevInd = prevIndex(negInd);
                    const nextInd = nextIndex(negInd);
                    const edge = Edge.fromPoints(triPoints.*[prevInd], triPoints.*[nextInd]);
                    const t = @min(@max(0, edge.getProjectionParam(p)), 1);
                    var clamped: Vec3.Arr = undefined;
                    clamped[prevInd] = 1 - t;
                    clamped[nextInd] = t;
                    clamped[negInd] = 0;
                    break :single clamped;
                },
                0 => bary,
                else => unreachable
            };
        }

        pub fn clampBary(self: *const Self, p: Vec.Simd, bary: Vec3.Simd) Vec3.Simd {
            return clampBaryFromPoints(&self.points, p, bary);
        }
    };
}

pub fn Pyramid(comptime N: u32, comptime T: type) type {
    return struct {
        points: [4]Vec.Simd = std.mem.zeroes([4]Vec.Simd),

        pub const Vec = vm.Vec(N, T);
        pub const Vec4 = vm.Vec(4, T);
        pub const Tri = Triangle(N, T);
        pub const Self = @This();

        pub fn getPoint(self: *const Self, bary: Vec4.Simd) Vec.Simd {
            return self.points[0] * Vec.splat(bary[0]) 
                + self.points[1] * Vec.splat(bary[1])
                + self.points[2] * Vec.splat(bary[2])
                + self.points[3] * Vec.splat(bary[3]);
        }

        pub fn unorientedTriangleIndices(triInd: u32) [3]u32 {
            return switch (triInd) {
                0 => .{1, 2, 3},
                1 => .{0, 2, 3},
                2 => .{0, 1, 3},
                3 => .{0, 1, 2},
                else => unreachable
            };
        }

        pub fn barycentricCoordsFromPoints(pyrPoints: *const [4]Vec.Simd, p: Vec.Simd) Vec4.Simd {
            const Mat3 = vm.Mat(3, 3, T);
            var m: Mat3.Simd = undefined;
            for (1..4) |i| {
                m[i - 1] = pyrPoints.*[i] - pyrPoints.*[0];
            }
            var bary: Vec4.Simd = undefined;
            const oneOverDeterminant = 1 / Mat3.determinant(m);
            if (!std.math.isFinite(oneOverDeterminant)) {
                // Points are co-planar
                // Find barycentrics for each side of the pyramid and pick the one that yields the closest point to the target when clamped to the triangle
                bary = Vec4.Simd{1, 0, 0, 0};
                var minDist = Vec.distance(p, pyrPoints.*[0]);
                for (0..4) |triInd| {
                    const inds = unorientedTriangleIndices(@intCast(triInd));
                    const tri: Tri = .{.points=.{pyrPoints.*[inds[0]], pyrPoints.*[inds[1]], pyrPoints.*[inds[2]]}};
                    // Triangles already handle their own degeneracy
                    const triBary = tri.barycentricCoords(p);
                    const triClosestBary = tri.clampBary(p, triBary);
                    const triClosest = tri.getPoint(triClosestBary);
                    const triDist = Vec.distance(p, triClosest);
                    if (minDist > triDist) {
                        var newBary: Vec4.Arr = undefined;
                        newBary[triInd] = 0;
                        for (0..3) |i|
                            newBary[inds[i]] = Tri.Vec3.get(triBary, i);
                        bary = newBary;
                        minDist = triDist;
                    }
                }
            } else {
                var invM: Mat3.Simd = undefined;
                invM[0][0] =  (m[1][1] * m[2][2] - m[2][1] * m[1][2]) * oneOverDeterminant;
                invM[1][0] = -(m[1][0] * m[2][2] - m[2][0] * m[1][2]) * oneOverDeterminant;
                invM[2][0] =  (m[1][0] * m[2][1] - m[2][0] * m[1][1]) * oneOverDeterminant;
                invM[0][1] = -(m[0][1] * m[2][2] - m[2][1] * m[0][2]) * oneOverDeterminant;
                invM[1][1] =  (m[0][0] * m[2][2] - m[2][0] * m[0][2]) * oneOverDeterminant;
                invM[2][1] = -(m[0][0] * m[2][1] - m[2][0] * m[0][1]) * oneOverDeterminant;
                invM[0][2] =  (m[0][1] * m[1][2] - m[1][1] * m[0][2]) * oneOverDeterminant;
                invM[1][2] = -(m[0][0] * m[1][2] - m[1][0] * m[0][2]) * oneOverDeterminant;
                invM[2][2] =  (m[0][0] * m[1][1] - m[1][0] * m[0][1]) * oneOverDeterminant;

                const params = Mat3.mulMatVec(invM, (p - pyrPoints.*[0]));
                bary = Vec4.Simd{1 - @reduce(.Add, params), params[0], params[1], params[2]};
            }
            return bary;
        }

        pub fn barycentricCoords(self: *const Self, v: Vec.Simd) Vec4.Simd {
            return barycentricCoordsFromPoints(&self.points, v);
        }

        pub fn clampBaryFromPoints(pyrPoints: *const [4]Vec.Simd, p: Vec.Simd, bary: Vec4.Simd) Vec4.Simd {
            const minInd = Vec4.minElemIndex(bary);
            if (Vec4.get(bary, minInd) >= 0)
                return bary;
            const inds = unorientedTriangleIndices(minInd);
            const tri: Tri = .{.points = .{pyrPoints.*[inds[0]], pyrPoints.*[inds[1]], pyrPoints.*[inds[2]]}};
            const triBary = tri.barycentricCoords(p);
            const triBaryClamped = tri.clampBary(p, triBary);
            var baryClamped: Vec4.Arr = undefined;
            baryClamped[minInd] = 0;
            for (0..3) |i|
                baryClamped[inds[i]] = Tri.Vec3.get(triBaryClamped, i);
            return baryClamped;
        }

        pub fn clampBary(self: *const Self, p: Vec.Simd, bary: Vec4.Simd) Vec4.Simd {
            return clampBaryFromPoints(&self.points, p, bary);
        }
    };
}

fn Simplex(comptime N: u32, comptime T: type) type {
    return struct {
        vertices: [N + 1]Vec.Simd = std.mem.zeroes([N + 1]Vec.Simd),
        numVertices: u32 = 0,

        pub const Vec = vm.Vec(N, T);
        pub const VecBary = vm.Vec(N + 1, T);
        pub const Edge = Line(N, T);
        pub const Tri = Triangle(N, T);
        pub const Pyr = Pyramid(N, T);
        pub const Self = @This();

        pub fn addVertex(self: *Self, v: Vec.Simd) void {
            std.debug.assert(self.numVertices < N + 1);
            self.vertices[self.numVertices] = v;
            self.numVertices += 1;
        }

        pub fn reduceToSupportOfBary(self: *Self, bary: VecBary.Simd) void {
            std.debug.assert(self.numVertices > 0);
            var nextVert: u32 = 0;
            var nextBary: u32 = 0;
            while (nextBary < self.numVertices) : (nextBary += 1) {
                if (@abs(VecBary.get(bary, nextBary)) > 0) {
                    self.vertices[nextVert] = self.vertices[nextBary];
                    nextVert += 1;
                }
            }
            self.numVertices = nextVert;
            std.debug.assert(self.numVertices < N + 1);
        }

        pub fn getPoint(self: *const Self, bary: VecBary.Simd) Vec.Simd {
            std.debug.assert(self.numVertices > 0);
            var p = self.vertices[0] * Vec.splat(bary[0]);
            for (1..self.numVertices) |i| 
                p += self.vertices[i] * Vec.splat(VecBary.get(bary, i));
            return p;
        }

        pub fn barycentricCoords(self: *const Self, p: Vec.Simd) VecBary.Simd {
            return switch (self.numVertices) {
                4 => Pyr.barycentricCoordsFromPoints(&self.vertices, p),
                3 => Tri.Vec3.toDim(N + 1, Tri.barycentricCoordsFromPoints(@ptrCast(&self.vertices), p), 0),
                2 => two: {
                    const edge = Edge.fromPoints(self.vertices[0], self.vertices[1]);
                    const t = edge.getProjectionParam(p);
                    var bary = VecBary.splat(0);
                    bary[0] = 1 - t;
                    bary[1] = t;
                    break :two bary;
                },
                1 => VecBary.cardinal(0, 1),
                else => unreachable
            };
        }

        pub fn clampBary(self: *const Self, p: Vec.Simd, bary: VecBary.Simd) VecBary.Simd {
            return switch (self.numVertices) {
                4 => return Pyr.clampBaryFromPoints(&self.vertices, p, bary),
                3 => Tri.Vec3.toDim(N + 1, Tri.clampBaryFromPoints(@ptrCast(&self.vertices), p, VecBary.toDim(3, bary, undefined)), 0),
                2 => two: {
                    var clamped = VecBary.splat(0);
                    clamped[1] = @min(@max(0, bary[1]), 1);
                    clamped[0] = 1 - clamped[1];
                    break :two clamped;
                },
                1 => bary,
                else => unreachable
            };
        }

        pub fn closestPointBary(self: *const Self, p: Vec.Simd) VecBary.Simd {
            const bary = self.barycentricCoords(p);
            const clamped = self.clampBary(p, bary);
            return clamped;
        }
    };
}

pub fn GJK(comptime N: u32, comptime T: type) type {
    return struct {
        pub const Vec = vm.Vec(N, T);
        pub const Simp = Simplex(N, T);
        pub const Self = @This();

        pub fn distance(comptime A: type, a: *const A, comptime B: type, b: *const B) T {
            var va = a.anyPoint();
            var vb = b.anyPoint();
            var v = va - vb;

            var simplex: Simp = .{};

            const zero = Vec.splat(0);
            const eps: T = 1e-5;

            var minDotPP = maxValue(T);
            var numFailedToImprove: u32 = 0;

            while (true) {
                simplex.addVertex(v);
                const pBary = simplex.closestPointBary(zero);
                const p = simplex.getPoint(pBary);
                const dotPP = Vec.dot(p, p);
                if (dotPP < eps)
                    return 0;
                if (dotPP < minDotPP) {
                    minDotPP = dotPP;
                    numFailedToImprove = 0;
                } else {
                    numFailedToImprove += 1;
                    if (numFailedToImprove > N + 1)
                        return @sqrt(minDotPP);
                }
                simplex.reduceToSupportOfBary(pBary);
                va = a.support(p);
                vb = b.support(-p);
                v = va - vb;
                const dotPV = Vec.dot(p, v);
                const dotDiff = dotPP - dotPV;
                const dotEps = eps * eps * dotPP;
                if (dotDiff <= dotEps)
                    return @sqrt(dotPP);
            }
        }
    };
}

pub fn TestGJK() !void {
    const Vec3f = vm.Vec(3, f32);
    const Sphere3f = Sphere(3, f32);
    const Box3f = Box(3, f32);
    const GJK3f = GJK(3, f32);

    const box: Box3f = .{.min = Vec3f.splat(-1), .max = Vec3f.splat(1)};
    const box2: Box3f = .{.min = Vec3f.splat(1), .max = Vec3f.splat(2)};
    const sphere: Sphere3f = .{.center = Vec3f.Simd{0, 0, 2}, .radius = 0.5};
    const dist = GJK3f.distance(Box3f, &box, Sphere3f, &sphere);
    try std.testing.expectApproxEqAbs(0.5, dist, 1e-3);
    const dist2 = GJK3f.distance(Box3f, &box, Box3f, &box2);
    try std.testing.expectEqual(0.0, dist2);
}

test "GJK" {
    try TestGJK();
}

