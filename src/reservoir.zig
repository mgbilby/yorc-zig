//! Seeded single-pass reservoir sampling (Vitter's Algorithm R), the exact
//! algorithm of yorc-rs's `dump::reservoir` so that both pick the same
//! sample from the same stream, seed and capacity:
//! * the RNG is SplitMix64 seeded with the seed;
//! * a draw in `[0, n)` is Lemire's multiply-shift `(next() * n) >> 64` (no
//!   rejection step);
//! * the k-th eligible item (0-based) is kept unconditionally while `k < N`;
//!   otherwise one draw `j = below(k + 1)` is made and the item replaces slot
//!   `j` iff `j < N`.
const std = @import("std");

pub const SplitMix64 = struct {
    state: u64,

    pub fn init(seed: u64) SplitMix64 {
        return .{ .state = seed };
    }

    pub fn next(self: *SplitMix64) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    /// A value in `[0, n)`; `n` must be > 0.
    pub fn below(self: *SplitMix64, n: u64) u64 {
        const wide: u128 = @as(u128, self.next()) * @as(u128, n);
        return @intCast(wide >> 64);
    }
};

/// What to do with the item just offered.
pub const Slot = union(enum) {
    append,
    replace: usize,
    skip,
};

/// A reservoir of up to `capacity` items of type T (unmanaged: pass the
/// allocator to `put` and `deinit`).
pub fn Reservoir(comptime T: type) type {
    return struct {
        capacity: usize,
        seen: u64 = 0,
        items: std.ArrayList(T) = .empty,
        rng: SplitMix64,

        const Self = @This();

        pub fn init(capacity: usize, seed: u64) Self {
            return .{ .capacity = capacity, .rng = .init(seed) };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.items.deinit(gpa);
            self.* = undefined;
        }

        /// Decides the fate of the next eligible item. Call exactly once per
        /// eligible item, in stream order; the item's content is only needed
        /// if the result is not `.skip`, so callers can avoid reading it.
        pub fn offer(self: *Self) Slot {
            const k = self.seen;
            self.seen += 1;
            if (self.capacity == 0) return .skip;
            if (k < self.capacity) return .append;
            const j = self.rng.below(k + 1);
            return if (j < self.capacity) .{ .replace = @intCast(j) } else .skip;
        }

        /// Stores `item` as `slot` says. Returns the item the caller must
        /// dispose of, if any: the evicted one for `.replace`, `item` itself
        /// for `.skip`, null for `.append`.
        pub fn put(self: *Self, gpa: std.mem.Allocator, slot: Slot, item: T) std.mem.Allocator.Error!?T {
            switch (slot) {
                .append => {
                    try self.items.append(gpa, item);
                    return null;
                },
                .replace => |j| {
                    const old = self.items.items[j];
                    self.items.items[j] = item;
                    return old;
                },
                .skip => return item,
            }
        }

        /// The sample so far (slot order).
        pub fn slice(self: *const Self) []const T {
            return self.items.items;
        }
    };
}

// ------------------------------------------------------------------ tests

fn sample(gpa: std.mem.Allocator, n: usize, seed: u64, total: u32) ![]u32 {
    var r: Reservoir(u32) = .init(n, seed);
    errdefer r.deinit(gpa);
    var i: u32 = 0;
    while (i < total) : (i += 1) {
        const slot = r.offer();
        _ = try r.put(gpa, slot, i);
    }
    return r.items.toOwnedSlice(gpa);
}

const testing = std.testing;

test "SplitMix64 reference values" {
    var g: SplitMix64 = .init(0);
    try testing.expectEqual(@as(u64, 0xe220a8397b1dcdaf), g.next());
    try testing.expectEqual(@as(u64, 0x6e789e6aa1b965f4), g.next());
    try testing.expectEqual(@as(u64, 0x06c45d188009454f), g.next());
    var h: SplitMix64 = .init(1_234_567);
    try testing.expectEqual(@as(u64, 6_457_827_717_110_365_317), h.next());
    try testing.expectEqual(@as(u64, 3_203_168_211_198_807_973), h.next());
    try testing.expectEqual(@as(u64, 9_817_491_932_198_370_423), h.next());
}

test "below is in range" {
    var g: SplitMix64 = .init(42);
    for ([_]u64{ 1, 2, 3, 10, 1000, std.math.maxInt(u64) }) |n| {
        for (0..1000) |_| try testing.expect(g.below(n) < n);
    }
}

test "keeps everything when the stream is short" {
    const s = try sample(testing.allocator, 10, 1, 5);
    defer testing.allocator.free(s);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4 }, s);
}

test "zero capacity" {
    const s = try sample(testing.allocator, 0, 1, 100);
    defer testing.allocator.free(s);
    try testing.expectEqual(@as(usize, 0), s.len);
}

fn sortedSample(n: usize, seed: u64, total: u32) ![]u32 {
    const s = try sample(testing.allocator, n, seed, total);
    std.mem.sort(u32, s, {}, std.sort.asc(u32));
    return s;
}

test "pinned picks (contract vectors shared with yorc-rs)" {
    const a = try sortedSample(3, 42, 10);
    defer testing.allocator.free(a);
    try testing.expectEqualSlices(u32, &.{ 5, 7, 9 }, a);
    const b = try sortedSample(5, 1, 1000);
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(u32, &.{ 71, 165, 177, 730, 916 }, b);
    // slot order, seed 7, 10 000 items (computed independently from the
    // algorithm above)
    const c = try sample(testing.allocator, 5, 7, 10_000);
    defer testing.allocator.free(c);
    try testing.expectEqualSlices(u32, &.{ 8135, 5980, 1301, 5670, 6839 }, c);
}

test "deterministic per seed" {
    const a = try sample(testing.allocator, 5, 7, 10_000);
    defer testing.allocator.free(a);
    const b = try sample(testing.allocator, 5, 7, 10_000);
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(u32, a, b);
    const c = try sample(testing.allocator, 5, 8, 10_000);
    defer testing.allocator.free(c);
    try testing.expect(!std.mem.eql(u32, a, c));
}

test "roughly uniform" {
    // P(item i kept) = n/total; check over many seeds.
    const n = 2;
    const total = 10;
    const trials = 20_000;
    var counts: [total]u32 = @splat(0);
    var seed: u64 = 0;
    while (seed < trials) : (seed += 1) {
        const s = try sample(testing.allocator, n, seed, total);
        defer testing.allocator.free(s);
        for (s) |x| counts[x] += 1;
    }
    const expected: f64 = @as(f64, trials) * n / total;
    for (counts) |c| {
        const dev = @abs(@as(f64, @floatFromInt(c)) - expected) / expected;
        try testing.expect(dev < 0.05);
    }
}
