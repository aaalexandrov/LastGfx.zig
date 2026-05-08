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

pub fn Vec(comptime N: u32, comptime T: type) type {
    return struct {
        pub const Simd = @Vector(N, T);
        pub const Arr = [N]T;
        pub const Dim = N;
        pub const Elem = T;

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

        pub fn get(v: Simd, i: u32) T {
            return @as(Arr, v)[i];
        }

        pub fn set(v: Simd, i: u32, e: T) Simd {
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
    pub const Col = Vec(R, T);
    pub const Row = Vec(C, T);
    pub const Elem = T;
    pub const Rows = R;
    pub const Cols = C;
    pub const Simd = [C]Col;

    pub fn diag(d: T) Simd {
        var m: Simd = undefined;
        inline for (0..C) |c|
            m[c] = Col.cardinal(c, d);
        return m;
    }

    pub fn row(m: Simd, r: u32) Row.Simd {
        var res: Row.Arr = undefined;
        for (0..C) |c|
            res[c] = m[c].get(r);
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
        inline for (0..R) |r|
            inline for (0..C) |c|
                res[c][r] = m[r][c];
        return res;
    }

    pub fn mul(comptime D: u32, a: Simd, b: Mat(C, D, T).Simd) Mat(R, D, T).Simd {
        var res: Mat(R, D).Simd = undefined;

        inline for (0..C) |bc|
            res[bc] = a[0] * @as(Vec4, @splat(b[bc][0]));

        inline for (1..C) |ac| {
            const c = a[ac];
            inline for (0..4) |bc|
                res[bc] += c * @as(Vec4, @splat(b[bc][ac]));
        }
        return res;
    }
}