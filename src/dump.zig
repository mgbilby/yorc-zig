//! Streaming access to ORCID Public Data File archives (`*.tar.gz`): the
//! archive is decompressed and walked member by member through `std.Io.Reader`
//! interfaces; nothing is extracted to disk and only the current member is
//! held in memory, and only if the caller reads it. In the summaries dump each
//! record is `ORCID_YYYY_MM_summaries/<last 3 chars>/<iD>.xml`.
//!
//! compressed reader → std.compress.flate.Decompress (.gzip), one member
//! after another → std.tar.Iterator
//!
//! A gzip file may be several members one after the other (RFC 1952, 2.2:
//! `cat a.gz b.gz`, some recompressors). The ORCID dumps are one member;
//! like flate2's `MultiGzDecoder` (yorc-rs) and DuckDB's gzip file
//! system, the archive reads every member: when one ends and more input
//! follows, the next member is decompressed as the continuation of the same
//! stream. Input after a member that is not a gzip header is
//! `error.CorruptArchive` (detail `error.BadGzipHeader`), as in flate2.
//!
//! The seeded reservoir sampler lives in `reservoir.zig` (`yorc.reservoir`).
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// Bad gzip/deflate data or tar headers (see `Archive.detail`).
    CorruptArchive,
    /// The underlying reader failed (see `Archive.detail`).
    ReadFailed,
    OutOfMemory,
};

pub const Member = struct {
    /// Path inside the archive; valid until the next `next`.
    name: []const u8,
    kind: std.tar.FileKind,
    size: u64,
    file: std.tar.Iterator.File,
};

/// A streaming tar.gz reader over any `*Io.Reader` of compressed bytes.
/// Heap-allocated so the reader chain keeps stable addresses.
pub const Archive = struct {
    gpa: Allocator,
    window: []u8,
    name_buf: []u8,
    link_buf: []u8,
    /// The compressed bytes.
    compressed: *Io.Reader,
    /// The current gzip member; replaced by a fresh one for each member.
    decomp: std.compress.flate.Decompress,
    /// The members' bytes as one stream (`gzStream`): what `iter` reads.
    gz: Io.Reader,
    gz_buf: []u8,
    iter: std.tar.Iterator,
    /// Reused buffer for member contents.
    content: Io.Writer.Allocating,
    /// Members seen so far (including skipped ones).
    members_seen: u64 = 0,
    /// gzip members begun so far (1 for the ORCID dumps).
    gzip_members: u64 = 1,
    /// The error behind the last `CorruptArchive` / `ReadFailed`.
    detail: ?anyerror = null,
    /// Set by `FileArchive` so a file error can be told apart.
    file_err: ?*const ?Io.File.Reader.Error = null,

    /// `compressed` must stay valid while the Archive is used.
    pub fn init(gpa: Allocator, compressed: *Io.Reader) Allocator.Error!*Archive {
        const self = try gpa.create(Archive);
        errdefer gpa.destroy(self);
        const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
        errdefer gpa.free(window);
        const name_buf = try gpa.alloc(u8, Io.Dir.max_path_bytes);
        errdefer gpa.free(name_buf);
        const link_buf = try gpa.alloc(u8, Io.Dir.max_path_bytes);
        errdefer gpa.free(link_buf);
        const gz_buf = try gpa.alloc(u8, gz_buffer_len);
        errdefer gpa.free(gz_buf);
        self.* = .{
            .gpa = gpa,
            .window = window,
            .name_buf = name_buf,
            .link_buf = link_buf,
            .compressed = compressed,
            .decomp = .init(compressed, .gzip, window),
            .gz = .{ .vtable = &gz_vtable, .buffer = gz_buf, .seek = 0, .end = 0 },
            .gz_buf = gz_buf,
            .iter = undefined,
            .content = .init(gpa),
        };
        self.iter = .init(&self.gz, .{
            .file_name_buffer = self.name_buf,
            .link_name_buffer = self.link_buf,
        });
        return self;
    }

    pub fn deinit(self: *Archive) void {
        const gpa = self.gpa;
        self.content.deinit();
        gpa.free(self.gz_buf);
        gpa.free(self.link_buf);
        gpa.free(self.name_buf);
        gpa.free(self.window);
        gpa.destroy(self);
    }

    const gz_buffer_len = 64 * 1024;

    const gz_vtable: Io.Reader.VTable = .{ .stream = gzStream };

    /// `Io.Reader.VTable.stream` of `gz`: the current member's bytes; at its
    /// end, a fresh decompressor for the next member if more input follows.
    /// (`Decompress` takes only the bytes of its member from `compressed`:
    /// it peeks bits and consumes whole bytes, up to its 8-byte trailer.)
    fn gzStream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *Archive = @alignCast(@fieldParentPtr("gz", r));
        while (true) {
            if (self.decomp.reader.stream(w, limit)) |n| {
                return n;
            } else |err| switch (err) {
                // the member is complete, its output all read
                error.EndOfStream => {},
                else => |e| return e,
            }
            // EndOfStream here is the end of the archive's input
            _ = try self.compressed.peekByte();
            self.decomp = .init(self.compressed, .gzip, self.window);
            self.gzip_members += 1;
        }
    }

    fn mapError(self: *Archive, err: anyerror) Error {
        if (err == error.ReadFailed) {
            if (self.decomp.err) |e| {
                self.detail = e;
                if (e == error.ReadFailed) {
                    if (self.file_err) |fe| if (fe.*) |f| {
                        self.detail = f;
                        return error.ReadFailed;
                    };
                }
                return error.CorruptArchive;
            }
            if (self.file_err) |fe| if (fe.*) |f| {
                self.detail = f;
                return error.ReadFailed;
            };
        }
        if (err == error.OutOfMemory) return error.OutOfMemory;
        self.detail = err;
        return error.CorruptArchive;
    }

    /// The next member (files, directories, symlinks), or null at the end.
    /// Unread content of the previous member is skipped.
    pub fn next(self: *Archive) Error!?Member {
        const maybe = self.iter.next() catch |err| return self.mapError(err);
        const f = maybe orelse return null;
        self.members_seen += 1;
        return .{ .name = f.name, .kind = f.kind, .size = f.size, .file = f };
    }

    /// The next regular file whose name ends in `.xml` (case-insensitive),
    /// skipping everything else.
    pub fn nextXml(self: *Archive) Error!?Member {
        while (try self.next()) |m| {
            if (m.kind == .file and xmlEntryStem(m.name) != null) return m;
        }
        return null;
    }

    /// Reads the current member's bytes; the slice is valid until the next
    /// `read` or `next`. `limit` caps the member size (error.CorruptArchive
    /// with detail error.StreamTooLong beyond it).
    pub fn read(self: *Archive, m: Member, limit: u64) Error![]const u8 {
        if (m.size > limit) {
            self.detail = error.StreamTooLong;
            return error.CorruptArchive;
        }
        self.content.clearRetainingCapacity();
        self.iter.streamRemaining(m.file, &self.content.writer) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => return self.mapError(err),
        };
        return self.content.written();
    }
};

/// An `Archive` over a file opened by path.
pub const FileArchive = struct {
    gpa: Allocator,
    io: Io,
    file: Io.File,
    file_buf: []u8,
    file_reader: Io.File.Reader,
    archive: *Archive,

    /// Opens `path` relative to the current working directory.
    pub fn open(gpa: Allocator, io: Io, path: []const u8) !*FileArchive {
        return openAt(gpa, io, Io.Dir.cwd(), path);
    }

    /// Opens `sub_path` relative to `dir` (the Dir may be closed afterwards).
    pub fn openAt(gpa: Allocator, io: Io, dir: Io.Dir, sub_path: []const u8) !*FileArchive {
        const self = try gpa.create(FileArchive);
        errdefer gpa.destroy(self);
        const file = try dir.openFile(io, sub_path, .{});
        errdefer file.close(io);
        const buf = try gpa.alloc(u8, 256 * 1024);
        errdefer gpa.free(buf);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .file = file,
            .file_buf = buf,
            .file_reader = file.reader(io, buf),
            .archive = undefined,
        };
        self.archive = try Archive.init(gpa, &self.file_reader.interface);
        self.archive.file_err = &self.file_reader.err;
        return self;
    }

    pub fn deinit(self: *FileArchive) void {
        const gpa = self.gpa;
        self.archive.deinit();
        gpa.free(self.file_buf);
        self.file.close(self.io);
        gpa.destroy(self);
    }
};

/// Last path component (trailing slashes ignored).
fn baseName(path: []const u8) []const u8 {
    const p = std.mem.trimEnd(u8, path, "/");
    return if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| p[i + 1 ..] else p;
}

/// True for `*.tar.gz` / `*.tgz` (case-insensitive).
pub fn isDumpPath(path: []const u8) bool {
    const name = baseName(path);
    return std.ascii.endsWithIgnoreCase(name, ".tar.gz") or std.ascii.endsWithIgnoreCase(name, ".tgz");
}

/// The file stem of a path ending in `.xml` (case-insensitive), or null.
pub fn xmlEntryStem(path: []const u8) ?[]const u8 {
    const name = baseName(path);
    if (std.mem.eql(u8, name, "..")) return null;
    if (name.len > 4 and std.ascii.endsWithIgnoreCase(name, ".xml")) return name[0 .. name.len - 4];
    return null;
}

test "dump path detection" {
    try std.testing.expect(isDumpPath("/x/ORCID_2024_10_summaries.tar.gz"));
    try std.testing.expect(isDumpPath("a.TGZ"));
    try std.testing.expect(!isDumpPath("a.xml"));
    try std.testing.expect(!isDumpPath("a.gz"));
}

test "entry stems" {
    try std.testing.expectEqualStrings("0000-0002-1825-0097", xmlEntryStem("ORCID_2024_10_summaries/097/0000-0002-1825-0097.xml").?);
    try std.testing.expect(xmlEntryStem("dir/README.txt") == null);
    try std.testing.expect(xmlEntryStem(".xml") == null);
    try std.testing.expectEqualStrings("A", xmlEntryStem("A.XML").?);
}
