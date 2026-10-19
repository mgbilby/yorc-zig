//! Integration tests over the embedded fixtures (`zig build test`).
test {
    _ = @import("xml_test.zig");
    _ = @import("json_test.zig");
    _ = @import("rows_test.zig");
    _ = @import("extra_test.zig");
    _ = @import("schema_test.zig");
    _ = @import("dump_test.zig");
    _ = @import("client_test.zig");
    _ = @import("fuzz_test.zig");
    _ = @import("walkthrough_test.zig");
}
