const std = @import("std");

pub const LeafHash = fn (hasher: anytype, key: anytype, comptime strat: std.hash.Strategy) void;

// copied with modifications from std/hash/auto_hash.zig

/// Helper function to hash a pointer and mutate the strategy if needed.
pub fn hashPointer(hasher: anytype, key: anytype, comptime strat: std.hash.Strategy, comptime leafHash: LeafHash) void {
    const info = @typeInfo(@TypeOf(key));

    switch (info.pointer.size) {
        .one => switch (strat) {
            .Shallow => hash(hasher, @intFromPtr(key), .Shallow, leafHash),
            .Deep => hash(hasher, key.*, .Shallow, leafHash),
            .DeepRecursive => hash(hasher, key.*, .DeepRecursive, leafHash),
        },

        .slice => {
            switch (strat) {
                .Shallow => {
                    hashPointer(hasher, key.ptr, .Shallow, leafHash);
                },
                .Deep => hashArray(hasher, key, .Shallow, leafHash),
                .DeepRecursive => hashArray(hasher, key, .DeepRecursive, leafHash),
            }
            hash(hasher, key.len, .Shallow, leafHash);
        },

        .many,
        .c,
        => switch (strat) {
            .Shallow => hash(hasher, @intFromPtr(key), .Shallow, leafHash),
            else => @compileError(
                \\ unknown-length pointers and C pointers cannot be hashed deeply.
                \\ Consider providing your own hash function.
            ),
        },
    }
}

/// Helper function to hash a set of contiguous objects, from an array or slice.
pub fn hashArray(hasher: anytype, key: anytype, comptime strat: std.hash.Strategy, comptime leafHash: LeafHash) void {
    for (key) |element| {
        hash(hasher, element, strat, leafHash);
    }
}

/// Provides generic hashing for any eligible type.
/// Strategy is provided to determine if pointers should be followed or not.
pub fn hash(hasher: anytype, key: anytype, comptime strat: std.hash.Strategy, comptime leafHash: LeafHash) void {
    const Key = @TypeOf(key);
    const Hasher = switch (@typeInfo(@TypeOf(hasher))) {
        .pointer => |ptr| ptr.child,
        else => @TypeOf(hasher),
    };

    if (strat == .Shallow and std.meta.hasUniqueRepresentation(Key)) {
        @call(.always_inline, Hasher.update, .{ hasher, std.mem.asBytes(&key) });
        return;
    }

    switch (@typeInfo(Key)) {
        .pointer => @call(.always_inline, hashPointer, .{ hasher, key, strat, leafHash }),

        .optional => if (key) |k| hash(hasher, k, strat, leafHash),

        .array => hashArray(hasher, key, strat, leafHash),

        .vector => |info| {
            if (std.meta.hasUniqueRepresentation(Key)) {
                hasher.update(std.mem.asBytes(&key));
            } else {
                comptime var i = 0;
                inline while (i < info.len) : (i += 1) {
                    hash(hasher, key[i], strat, leafHash);
                }
            }
        },

        .@"struct" => |info| {
            inline for (info.fields) |field| {
                // We reuse the hash of the previous field as the seed for the
                // next one so that they're dependant.
                hash(hasher, @field(key, field.name), strat, leafHash);
            }
        },

        .@"union" => |info| blk: {
            if (info.tag_type) |tag_type| {
                const tag = std.meta.activeTag(key);
                hash(hasher, tag, strat, leafHash);
                inline for (info.fields) |field| {
                    if (@field(tag_type, field.name) == tag) {
                        if (field.type != void) {
                            hash(hasher, @field(key, field.name), strat, leafHash);
                        }
                        break :blk;
                    }
                }
                unreachable;
            } else @compileError("cannot hash untagged union type: " ++ @typeName(Key) ++ ", provide your own hash function");
        },

        .error_union => blk: {
            const payload = key catch |err| {
                hash(hasher, err, strat, leafHash);
                break :blk;
            };
            hash(hasher, payload, strat, leafHash);
        },

        else => leafHash(hasher, key, strat),
    }
}

pub fn getHashApplyStratFn(comptime K: type, comptime Context: type, comptime strategy: std.hash.Strategy, comptime leafHash: LeafHash) (fn (Context, K) u32) {
    return struct {
        fn hashApply(ctx: Context, key: K) u32 {
            _ = ctx;
            var hasher = std.hash.Wyhash.init(0);
            hash(&hasher, key, strategy, leafHash);
            return @as(u32, @truncate(hasher.final()));
        }
    }.hashApply;
}

pub fn hashFloat(hasher: anytype, key: anytype, comptime strat: std.hash.Strategy, comptime leafHash: LeafHash) void {
    const Key = @TypeOf(key);
    switch (@typeInfo(Key)) {    
        .float => |float| 
            leafHash(hasher, @as(@Int(.unsigned, float.bits), @bitCast(key)), strat),
        else => leafHash(hasher, key, strat),
    }
}

pub fn autoHashFloat(hasher: anytype, key: anytype, comptime strat: std.hash.Strategy) void {
    return hashFloat(hasher, key, strat, std.hash.autoHashStrat);
}