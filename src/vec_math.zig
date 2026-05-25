const std = @import("std");

pub const BinaryOp = enum {
    Add,
    Sub,
    Mul,
    Div,
};

pub const UnaryOp = enum {
    Neg,
    Sqrt,
};

pub const BoolOp = enum {
    Equal,
    NotEqual,
    Less,
    LessOrEqual,
    Greater,
    GreaterOrEqual,
};

pub fn Vec(comptime N: u32, comptime T: type) type {
    return struct {
        pub const Simd = @Vector(N, T);
        pub const Arr = [N]T;
        pub const Dim = N;
        pub const Elem = T;
        pub const Eps = std.math.floatEps(T);

        pub fn load(a: Arr) Simd {
            return a;
        }

        pub fn store(v: Simd) Arr {
            return v;
        }

        pub fn splat(e: T) Simd {
            return @splat(e);
        }

        pub fn cardinal(D: u32, e: T) Simd {
            var v: Arr = undefined;
            inline for (0..N) |i|
                v[i] = if (i == D) e else 0;
            return v;
        }

        pub fn all(v: Simd) bool {
            return @reduce(.And, v);
        }

        pub fn any(v: Simd) bool {
            return @reduce(.Or, v);
        }

        pub fn toDim(comptime D: u32, v: Simd, pad: T) @Vector(D, T) {
            var res: [D]T = undefined;
            inline for (0..D) |i|
                res[i] = if (i < N) v[i] else pad;
            return res;
        }

        pub fn dot(a: Simd, b: Simd) T {
            return @reduce(.Add, a * b);
        }

        pub fn cross_scalar(a: Simd, b: Simd) Simd {
            var v: Simd = undefined;
            v[0] = a[1] * b[2] - a[2] * b[1];
            v[1] = a[2] * b[0] - a[0] * b[2];
            v[2] = a[0] * b[1] - a[1] * b[0];
            inline for (3..N) |i|
                v[i] = 0;
            return v;
        }

        pub fn cross(a: Simd, b: Simd) Simd {
            const a1 = shifted(a, 1, 3);
            const b1 = shifted(b, 1, 3);
            return shifted(a * b1 - a1 * b, 1, 3);
        }

        pub fn shifted(v: Simd, comptime n: i32, comptime D: i32) Simd {
            comptime var mask: [N]i32 = undefined;
            inline for (0..N) |i|
                mask[i] = if (i < D) @mod(@as(i32, @intCast(i)) + n, D) else -1;
            return @shuffle(f32, v, @Vector(1, T){0}, mask);
        }

        pub fn length2(v: Simd) T {
            return dot(v, v);
        }

        pub fn length(v: Simd) T {
            return @sqrt(length2(v));
        }

        pub fn normalize(v: Simd) Simd {
            const len = length(v);
            if (std.math.approxEqAbs(T, len, 0, Eps))
                return v;
            return v * @as(Simd, @splat(1 / len));
        }

        pub fn get(v: Simd, i: usize) T {
            return @as(Arr, v)[i];
        }

        pub fn set(v: Simd, i: usize, e: T) Simd {
            var va: Arr = v;
            va[i] = e;
            return va;
        }
    };
}

test "Vec" {
    const v4f = Vec(4, f32);
    const a = v4f.Simd{ 1, 2, 3, 4 };
    const b = v4f.Simd{ 5, 6, 7, 8 };
    const dot = v4f.dot(a, b);

    var dot_f: v4f.Elem = 0;
    inline for (0..v4f.Dim) |i|
        dot_f += a[i] * b[i];
    try std.testing.expect(dot_f == dot);

    const cross = v4f.cross(a, b);
    const cross_s = v4f.cross_scalar(a, b);
    try std.testing.expectEqual(cross, cross_s);

    const v3f = Vec(3, f32);
    const a3: v3f.Simd = v4f.toDim(3, a, 0);
    const b3: v3f.Simd = v4f.toDim(3, b, 0);
    const cross3 = v3f.cross(a3, b3);
    const cross3_s = v3f.cross_scalar(a3, b3);
    try std.testing.expectEqual(cross3, cross3_s);
}

pub fn Mat(comptime R: u32, comptime C: u32, comptime T: type) type {
    return struct {
        pub const Col = Vec(R, T);
        pub const Row = Vec(C, T);
        pub const RowBool = Vec(C, bool);
        pub const Elem = T;
        pub const Rows = R;
        pub const Cols = C;
        pub const Simd = [C]Col.Simd;
        pub const Eps = std.math.floatEps(T);

        pub fn diag(d: T) Simd {
            var m: Simd = undefined;
            inline for (0..C) |c|
                m[c] = Col.cardinal(c, d); 
            return m;
        }

        pub fn toDim(comptime R1: u32, comptime C1: u2, m: Simd, diagPad: T) Mat(R1, C1, T).Simd {
            const Mat1 = Mat(R1, C1, T);
            var res: Mat1.Simd = undefined;
            inline for (0..C1) |c1| {
                res[c1] = if (c1 < C)
                        Col.toDim(R1, m[c1], 0)
                    else
                        Mat1.Col.cardinal(c1, diagPad);
            }
            return res;
        }

        pub fn row(m: Simd, r: u32) Row.Simd {
            var res: Row.Arr = undefined;
            for (0..C) |c|
                res[c] = Col.get(m[c] ,r);
            return res;
        }

        pub fn setRow(m: Simd, r: u32, rowVec: Row.Simd) Simd {
            var res: Simd = undefined;
            for (0..C) |c|
                res[c] = m[c].set(r, Row.get(rowVec, c));
            return res;
        }

        pub fn binaryOp(comptime op: BinaryOp, m1: Simd, m2: Simd) Simd {
            var res: Simd = undefined;
            inline for (0..C) |c|
                res[c] = switch (op) {
                    .Add => m1[c] + m2[c],
                    .Sub => m1[c] - m2[c],
                    .Mul => m1[c] * m2[c],
                    .Div => m1[c] / m2[c],
                };
            return res;
        }

        pub fn uniaryOp(comptime op: UnaryOp, m: Simd) Simd {
            var res: Simd = undefined;
            inline for (0..C) |c|
                res[c] = switch (op) {
                    .Neg => -m[c],
                    .Sqrt => @sqrt(m[c]),
                };
            return res;
        }

        pub fn boolOp(comptime op: BoolOp, a: Simd, b:Simd) RowBool.Simd {
            var res: RowBool.Simd = undefined;
            inline for (0..C) |c| {
                const rowRes: RowBool.Simd = switch (op) {
                    .Equal => a[c] == b[c],
                    .NotEqual => a[c] != b[c],
                    .Less => a[c] < b[c],
                    .LessOrEqual => a[c] <= b[c],
                    .Greater => a[c] > b[c],
                    .GreaterOrEqual => a[c] >= b[c],
                };
                res[c] = RowBool.all(rowRes);
            }
            return res;
        }

        pub fn mulMatVec(m: Simd, v: Row.Simd) Col.Simd {
            var res: Col.Simd = m[0] * @as(Col.Simd, @splat(v[0]));
            inline for (1..C) |c|
                res += m[c] * @as(Col.Simd, @splat(v[c]));
            return res;
        }

        pub fn mulVecMat(v: Col.Simd, m: Simd) Row.Simd {
            var res: Row.Simd = row(m, 0) * @as(Row.Simd, @splat(v[0]));
            inline for (1..R) |r|
                res += row(m, r) * @as(Row.Simd, @splat(v[r]));
            return res;
        }

        pub fn transpose(m: Simd) Mat(C, R, T).Simd {
            var res: Mat(C, R, T).Simd = undefined;
            inline for (0..R) |r| {
                inline for (0..C) |c|
                    res[c][r] = m[r][c];
            }
            return res;
        }

        pub fn mul(comptime D: u32, a: Simd, b: Mat(C, D, T).Simd) Mat(R, D, T).Simd {
            var res: Mat(R, D, T).Simd = undefined;

            inline for (0..C) |bc|
                res[bc] = a[0] * @as(Col.Simd, @splat(b[bc][0]));

            inline for (1..C) |ac| {
                const c = a[ac];
                inline for (0..4) |bc|
                    res[bc] += c * @as(Col.Simd, @splat(b[bc][ac]));
            }
            return res;
        }

        pub fn determinant(m_: Simd) T {
            comptime if (R != C) unreachable;
            // TODO: specialize for small sizes
            var m = m_;
            var det: T = 1;
            for (0..C) |c| {
                var maxInd = c;
                for (c+1..C) |cm| {
                    if (@abs(Col.get(m[cm], c)) > @abs(Col.get(m[maxInd], c)))
                        maxInd = cm;
                }
                if (maxInd != c) {
                    std.mem.swap(Col.Simd, &m[c], &m[maxInd]);
                    det *= -1;
                }
                const pivot = Col.get(m[c], c);
                if (std.math.approxEqAbs(T, pivot, 0, Eps))
                    return 0;
                det *= pivot;
                for (c+1..C) |cn| {
                    const elem = Col.get(m[cn], c);
                    if (std.math.approxEqAbs(T, elem, 0, Eps))
                        continue;
                    const scale = -pivot / elem;
                    m[cn] = m[cn] * @as(Col.Simd, @splat(scale)) + m[c];
                    det *= scale;
                    std.debug.assert(Col.get(m[cn], c) < 1e-5);
                }
            }
            return det;
        }

        pub fn inverse(m_: Simd) !Simd {
             comptime if (R != C) unreachable;
            // TODO: specialize for small sizes
            var m = m_;
            var res = diag(1);
            for (0..C) |c| {
                var maxInd = c;
                for (c+1..C) |cm| {
                    if (@abs(Col.get(m[cm], c)) > @abs(Col.get(m[maxInd],c)))
                        maxInd = cm;
                }
                if (maxInd != c) {
                    std.mem.swap(Col.Simd, &m[c], &m[maxInd]);
                    std.mem.swap(Col.Simd, &res[c], &res[maxInd]);
                }
                const pivot = Col.get(m[c], c);
                if (std.math.approxEqAbs(T, pivot, 0, Eps))
                    return error.NotInvertible;
                const scale = @as(Col.Simd, @splat(1 / pivot));
                m[c] *= scale;
                res[c] *= scale;
                for (0..C) |co| {
                    if (co == c)
                        continue;
                    const elem = Col.get(m[co], c);
                    if (std.math.approxEqAbs(T, elem, 0, Eps))
                        continue;
                    const factor = @as(Col.Simd, @splat(elem));
                    m[co] -= m[c] * factor;
                    res[co] -= res[c] * factor;
                }
            }
            return res;
        }

        pub fn translate(comptime D: u32, pos: Vec(D, T).Simd) Simd {
            const PosVec = Vec(D, T);
            var res: Simd = undefined;
            inline for (0..C) |c| {
                res[c] = Col.cardinal(c, 1);
            }
            inline for (0..R) |r| {
                res[C-1][r] = if (r < @min(R, PosVec.Dim))
                        PosVec.get(pos, r)
                    else
                        @intFromBool(r == R-1);
            }
            return res;
        }

        pub fn rotate3D(comptime D: u32, angle: T, axis_: Vec(D, T).Simd) Simd {
            const AxisVec = Vec(D, T);
            const a = angle;
            const c = @cos(a);
            const s = @sin(a);

            const axis = AxisVec.normalize(axis_);
            const temp = @as(Col.Simd, @splat(1 - c)) * axis;

            var rotate: Simd = diag(1);
            rotate[0][0] = c + temp[0] * axis[0];
            rotate[0][1] = temp[0] * axis[1] + s * axis[2];
            rotate[0][2] = temp[0] * axis[2] - s * axis[1];

            rotate[1][0] = temp[1] * axis[0] - s * axis[2];
            rotate[1][1] = c + temp[1] * axis[1];
            rotate[1][2] = temp[1] * axis[2] + s * axis[0];

            rotate[2][0] = temp[2] * axis[0] + s * axis[1];
            rotate[2][1] = temp[2] * axis[1] - s * axis[0];
            rotate[2][2] = c + temp[2] * axis[2];

            return rotate;
        }

        pub fn perspective(fovY: T, aspect: T, near: T, far: T) Simd {
            comptime if (C != 4 or R != 4) unreachable;
            const tanFov2 = @tan(fovY / 2);
            return Simd{
                .{1/(aspect*tanFov2), 0, 0, 0},
                .{0, 1/tanFov2, 0, 0},
                .{0, 0, -(far+near)/(far-near), -1},
                .{0, 0, -2*far*near/(far-near), 0},
            };
        }

        pub fn orthographic(left: T, right: T, bottom: T, top: T, near: T, far: T) Simd {
            comptime if (C != 4 or R != 4) unreachable;
            return Simd{
                .{2/(right-left), 0, 0, 0},
                .{0, 2/(top-bottom), 0, 0},
                .{0, 0, -2/(far-near), 0},
                .{-(right+left)/(right-left), -(top+bottom)/(top-bottom), -(far+near)/(far-near), 1},
            };
        }
    };
}

test "Mat" {
    const m4f = Mat(4, 4, f32);
    const a = m4f.diag(1);
    const b = m4f.diag(2);

    const ab = m4f.binaryOp(.Add, a, b);
    const abeq3 = m4f.boolOp(.Equal, ab, m4f.diag(3));
    try std.testing.expect(m4f.RowBool.all(abeq3));

    const abmul = m4f.binaryOp(.Mul, a, b);
    const abmuleq2 = m4f.boolOp(.Equal, abmul, m4f.diag(2));
    try std.testing.expect(m4f.RowBool.all(abmuleq2));

    const mulab = m4f.mul(4, a, b);
    const mulabeq2 = m4f.boolOp(.Equal, mulab, m4f.diag(2));
    try std.testing.expect(m4f.RowBool.all(mulabeq2));

    const binv = try m4f.inverse(b);
    const bbinv = m4f.mul(4, b, binv);
    const bbinveq1 = m4f.boolOp(.Equal, bbinv, m4f.diag(1));
    try std.testing.expect(m4f.RowBool.all(bbinveq1));

    const bdet = m4f.determinant(b);
    try std.testing.expectEqual(std.math.pow(f32, 2, 4), bdet);

    const mat43f = Mat(4, 3, f32);
    const m: mat43f.Simd = .{
        .{2, 0, 0, 1},
        .{0, 2, 0, 1},
        .{0, 0, 2, 1},
    };
    const v4: mat43f.Col.Simd = .{1, 2, 3, 1};
    const v3: mat43f.Row.Simd = .{1, 2, 3};

    const vm = mat43f.mulVecMat(v4, m);
    try std.testing.expectEqual(mat43f.Row.Simd{3, 5, 7}, vm);

    const mv = mat43f.mulMatVec(m, v3);
    try std.testing.expectEqual(mat43f.Col.Simd{2, 4, 6, 6}, mv);
}