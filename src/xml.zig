//! ORCID v3.0 XML: reading (`parse`) and writing (`write`, `toOwned`). See
//! xml_read.zig and xml_write.zig for the rules.
const read = @import("xml_read.zig");
const wr = @import("xml_write.zig");

/// The pull scanner underneath the reader (for callers that need raw tokens,
/// qualified names or namespace declarations).
pub const scan = @import("xml_scan.zig");

pub const Options = read.Options;
pub const ParseError = read.ParseError;
/// Parses an ORCID XML document into an owned `Document`.
pub const parse = read.parse;
/// The element tree the reader builds before mapping (advanced use).
pub const Elem = read.Elem;
pub const buildTree = read.buildTree;
/// Maps an element tree onto a `Root`.
pub const rootFromTree = read.document;

pub const Ns = wr.Ns;
pub const WriteError = wr.WriteError;
pub const write = wr.write;
pub const toOwned = wr.toOwned;

test {
    _ = read;
    _ = wr;
    _ = scan;
}
