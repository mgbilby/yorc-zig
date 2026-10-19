//! yorc-zig build, for Zig 0.18.0-dev.131+41f885830 (see README.md).
//!
//!   zig build test                      # every test (library, client, integration)
//!   zig build test -Dtest-filter=json   # only tests whose name contains "json"
//!   zig build test --fuzz               # also fuzz the readers (Linux/macOS, 64-bit)
//!   zig build walkthrough               # WALKTHROUGH.md, cells 0 to 8
//!   zig build walkthrough -- 5          # one cell
//!   zig build walkthrough -- 9 --network   # cell 9: one request to ORCID
//!
//! Modules for dependents:
//!   yorc          id, model, xml, json, rows, hash, dump, reservoir
//!   yorc_client   the blocking Public API reader (imports `yorc`)
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const filters = b.option([]const []const u8, "test-filter", "Only run tests whose name contains this text (repeatable)") orelse &.{};

    const yorc = b.addModule("yorc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const client = b.addModule("yorc_client", .{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "yorc", .module = yorc }},
    });

    // Test fixtures (ORCID samples, XSDs, a real record, a dump archive),
    // embedded with @embedFile from their own module so paths stay inside it.
    const fixtures = b.createModule(.{
        .root_source_file = b.path("testdata/fixtures.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The walkthrough (WALKTHROUGH.md): one function per cell. The program
    // runs in the package root, where its input paths (testdata/...) are;
    // tests/walkthrough_test.zig calls the same cells.
    const walkthrough = b.createModule(.{
        .root_source_file = b.path("examples/walkthrough.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "yorc", .module = yorc },
            .{ .name = "yorc_client", .module = client },
        },
    });
    const walkthrough_exe = b.addExecutable(.{ .name = "walkthrough", .root_module = walkthrough });
    const walkthrough_run = b.addRunArtifact(walkthrough_exe);
    walkthrough_run.setCwd(b.path("."));
    walkthrough_run.addPassthruArgs();
    b.step("walkthrough", "Run the walkthrough (WALKTHROUGH.md); `-- N` runs cell N, `-- 9 --network` the network cell")
        .dependOn(&walkthrough_run.step);

    const integration = b.createModule(.{
        .root_source_file = b.path("tests/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "yorc", .module = yorc },
            .{ .name = "yorc_client", .module = client },
            .{ .name = "fixtures", .module = fixtures },
            .{ .name = "walkthrough", .module = walkthrough },
        },
    });

    const test_step = b.step("test", "Run the library, client and integration tests");
    for ([_]struct { []const u8, *std.Build.Module }{
        .{ "yorc", yorc },
        .{ "yorc_client", client },
        .{ "integration", integration },
    }) |t| {
        const exe = b.addTest(.{ .name = t[0], .root_module = t[1], .filters = filters });
        test_step.dependOn(&b.addRunArtifact(exe).step);
    }
}
