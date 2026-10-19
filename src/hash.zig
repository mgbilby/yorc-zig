//! `source_hash`: lowercase hex SHA-256 of the exact document bytes.
const std = @import("std");

pub const Hex = [64]u8;

pub fn sha256Hex(data: []const u8) Hex {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const chars = "0123456789abcdef";
    var out: Hex = undefined;
    for (digest, 0..) |b, i| {
        out[2 * i] = chars[b >> 4];
        out[2 * i + 1] = chars[b & 0x0f];
    }
    return out;
}

test "known vectors" {
    const e = sha256Hex("");
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &e);
    const a = sha256Hex("abc");
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &a);
}
