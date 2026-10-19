//! yorc-zig (module `yorc`): Cultivate your research identity and networks. The
//! ORCID message schema v3.0 for Zig.
//!
//! * `id`: `OrcidId`, ISO 7064 MOD 11-2, the normalisation rules of
//!   yorc-duckdb's `orcid_normalize`.
//! * `model`: types for every data-bearing element and attribute of the v3.0
//!   record XSDs and the group-id-3.0 records; `Document` / `Root` for every
//!   root element.
//! * `xml`: ORCID XML → `Document` (own pull parser over std) and model →
//!   ORCID XML (exact and deterministic, ORCID's prefixes).
//! * `json`: ORCID's JSON form over the same model, read and write.
//! * `rows`: yorc-duckdb's section tables, same names, columns,
//!   order and types; `hash.sha256Hex` for `source_hash`. Opt-in:
//!   its `timeline` and `group_ids` tables (`rows.Extra`) and its snapshot
//!   diff (`rows.changes`).
//! * `dump`: streaming Public Data File (`.tar.gz`) access; `reservoir`: the
//!   seeded sampler.
//!
//! The client is a separate module, `yorc_client`: it reads only ORCID's
//! Public API (`pub.orcid.org`). yorc-zig does not provide access to the
//! ORCID Sandbox or the ORCID Member API.
//!
//! yorc-zig is an independent open-source project. It is not affiliated
//! with, endorsed by or sponsored by ORCID, Inc.
//!
//! Every function that allocates takes an allocator; documents own their
//! memory (`Document.deinit`); readers and writers report details through an
//! optional `*Diagnostic`.
pub const id = @import("id.zig");
pub const model = @import("model.zig");
pub const xml = @import("xml.zig");
pub const json = @import("json.zig");
pub const rows = @import("rows.zig");
pub const hash = @import("hash.zig");
pub const dump = @import("dump.zig");
pub const reservoir = @import("reservoir.zig");
pub const utf8 = @import("utf8.zig");
pub const Diagnostic = @import("diag.zig").Diagnostic;

pub const OrcidId = id.OrcidId;
pub const Document = model.Document;
pub const Root = model.Root;
pub const Record = model.Record;

/// Library version (matches build.zig.zon).
pub const version = "0.1.0";

test {
    _ = id;
    _ = model;
    _ = xml;
    _ = json;
    _ = rows;
    _ = hash;
    _ = dump;
    _ = reservoir;
    _ = utf8;
    _ = @import("bump.zig");
    _ = @import("rows_extra.zig");
}
