//! Bump allocation in chunks taken from an arena. `std.heap.ArenaAllocator`
//! is thread-safe, which costs an atomic read-modify-write per allocation; a
//! reader or a table builder owns its arena alone, so it hands out memory
//! from the current chunk with plain arithmetic and goes to the arena only
//! for the next chunk. Nothing is freed before the arena is.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Bump = struct {
    arena: Allocator,
    buf: []u8,
    used: usize = 0,
    /// Size of the chunks after the first (a larger request gets its own).
    chunk: usize,

    /// `first` (the first chunk, allocated now) and `chunk` must be > 0.
    pub fn init(arena: Allocator, first: usize, chunk: usize) Allocator.Error!Bump {
        std.debug.assert(first > 0 and chunk > 0);
        return .{ .arena = arena, .buf = try arena.alloc(u8, first), .chunk = chunk };
    }

    /// `n` bytes aligned to `alignment`.
    pub fn bytes(b: *Bump, n: usize, comptime alignment: usize) Allocator.Error![*]u8 {
        const base = @intFromPtr(b.buf.ptr);
        const start = std.mem.alignForward(usize, base + b.used, alignment) - base;
        if (start + n <= b.buf.len) {
            b.used = start + n;
            return b.buf.ptr + start;
        }
        return b.fresh(n, alignment);
    }

    fn fresh(b: *Bump, n: usize, comptime alignment: usize) Allocator.Error![*]u8 {
        @branchHint(.cold);
        b.buf = try b.arena.alloc(u8, @max(b.chunk, n + alignment));
        const base = @intFromPtr(b.buf.ptr);
        const start = std.mem.alignForward(usize, base, alignment) - base;
        b.used = start + n;
        return b.buf.ptr + start;
    }

    pub fn alloc(b: *Bump, comptime T: type, n: usize) Allocator.Error![]T {
        const ptr = try b.bytes(n * @sizeOf(T), @alignOf(T));
        return @as([*]T, @ptrCast(@alignCast(ptr)))[0..n];
    }

    pub fn dupe(b: *Bump, s: []const u8) Allocator.Error![]const u8 {
        const ptr = try b.bytes(s.len, 1);
        @memcpy(ptr[0..s.len], s);
        return ptr[0..s.len];
    }
};

test "chunks, alignment and large requests" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var b = try Bump.init(arena.allocator(), 16, 32);
    const s = try b.dupe("abc");
    const xs = try b.alloc(u64, 3);
    for (xs, 0..) |*x, i| x.* = i;
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(xs.ptr) % @alignOf(u64));
    const big = try b.alloc(u8, 1000);
    @memset(big, 7);
    const t = try b.dupe("defg");
    try std.testing.expectEqualStrings("abc", s);
    try std.testing.expectEqualStrings("defg", t);
    try std.testing.expectEqual(@as(u64, 2), xs[2]);
    try std.testing.expectEqual(@as(u8, 7), big[999]);
}
