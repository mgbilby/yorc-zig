//! Error details for the readers and writers. Zig errors carry no payload, so
//! functions that can fail on data take an optional `*Diagnostic` and fill it
//! before returning the error. A Diagnostic owns no heap memory.
const std = @import("std");

pub const Diagnostic = struct {
    /// XML: byte offset where reading stopped. UTF-8 errors: the number of
    /// valid bytes before the first invalid one (Rust's `valid_up_to`).
    position: usize = 0,
    /// A short, static description (e.g. "unbalanced end tag").
    message: []const u8 = "",
    /// For `error.Unwritable`: the code point XML 1.0 cannot carry, if that
    /// is the reason (0xFFFD for bytes that are not UTF-8).
    code_point: ?u21 = null,
    /// For `error.Unwritable`: the element path, e.g. `keyword/content` or
    /// `work/@put-code` (truncated to the buffer).
    path_buf: [512]u8 = undefined,
    path_len: usize = 0,

    pub fn path(d: *const Diagnostic) []const u8 {
        return d.path_buf[0..d.path_len];
    }

    pub fn setPath(d: *Diagnostic, p: []const u8) void {
        const n = @min(p.len, d.path_buf.len);
        @memcpy(d.path_buf[0..n], p[0..n]);
        d.path_len = n;
    }

    /// Appends `/segment` (or `segment` at the start).
    pub fn pushPath(d: *Diagnostic, segment: []const u8) void {
        if (d.path_len > 0) d.appendRaw("/");
        d.appendRaw(segment);
    }

    pub fn appendRaw(d: *Diagnostic, s: []const u8) void {
        const room = d.path_buf.len - d.path_len;
        const n = @min(room, s.len);
        @memcpy(d.path_buf[d.path_len..][0..n], s[0..n]);
        d.path_len += n;
    }

    /// `{f}`: "message at byte N" / "cannot write PATH: message".
    pub fn format(d: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (d.path_len > 0) {
            try w.print("cannot write {s}: {s}", .{ d.path_buf[0..d.path_len], d.message });
            if (d.code_point) |cp| try w.print(" (U+{X:0>4})", .{cp});
        } else {
            try w.print("{s} (at byte {d})", .{ d.message, d.position });
        }
    }
};

/// Fills `diag` (if any) and returns `err`.
pub fn fail(diag: ?*Diagnostic, err: anytype, message: []const u8, position: usize) @TypeOf(err) {
    if (diag) |d| {
        d.message = message;
        d.position = position;
    }
    return err;
}
