//! Test fixtures, embedded with @embedFile so the tests need no file system
//! access. Generated from the directory listing; regenerate it when files
//! are added (see README.md in this directory).
//!
//! ORCID material (record_3.0/, common_3.0/, group-id-3.0/group-id-3.0.xml
//! and changes/, derived from ORCID's record sample): ORCID MIT-style
//! license, see LICENSE-ORCID. The real records and the dump archive: CC0 1.0 public ORCID
//! data (see README.md).

pub const File = struct { name: []const u8, data: []const u8 };

pub const read_samples = [_]File{
    .{ .name = "activities-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/activities-3.0.xml") },
    .{ .name = "address-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/address-3.0.xml") },
    .{ .name = "addresses-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/addresses-3.0.xml") },
    .{ .name = "biography-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/biography-3.0.xml") },
    .{ .name = "bulk-work-err.xml", .data = @embedFile("record_3.0/samples/read_samples/bulk-work-err.xml") },
    .{ .name = "credit-name-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/credit-name-3.0.xml") },
    .{ .name = "distinction-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/distinction-3.0.xml") },
    .{ .name = "distinctions-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/distinctions-3.0.xml") },
    .{ .name = "education-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/education-3.0.xml") },
    .{ .name = "education-full-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/education-full-3.0.xml") },
    .{ .name = "educations-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/educations-3.0.xml") },
    .{ .name = "email-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/email-3.0.xml") },
    .{ .name = "emails-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/emails-3.0.xml") },
    .{ .name = "employment-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/employment-3.0.xml") },
    .{ .name = "employment-full-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/employment-full-3.0.xml") },
    .{ .name = "employments-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/employments-3.0.xml") },
    .{ .name = "error-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/error-3.0.xml") },
    .{ .name = "external-identifier-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/external-identifier-3.0.xml") },
    .{ .name = "external-identifiers-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/external-identifiers-3.0.xml") },
    .{ .name = "funding-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/funding-3.0.xml") },
    .{ .name = "funding-full-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/funding-full-3.0.xml") },
    .{ .name = "fundings-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/fundings-3.0.xml") },
    .{ .name = "history-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/history-3.0.xml") },
    .{ .name = "invited-position-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/invited-position-3.0.xml") },
    .{ .name = "invited-positions-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/invited-positions-3.0.xml") },
    .{ .name = "keyword-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/keyword-3.0.xml") },
    .{ .name = "keywords-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/keywords-3.0.xml") },
    .{ .name = "membership-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/membership-3.0.xml") },
    .{ .name = "memberships-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/memberships-3.0.xml") },
    .{ .name = "name-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/name-3.0.xml") },
    .{ .name = "other-name-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/other-name-3.0.xml") },
    .{ .name = "other-names-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/other-names-3.0.xml") },
    .{ .name = "peer-review-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/peer-review-3.0.xml") },
    .{ .name = "peer-review-full-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/peer-review-full-3.0.xml") },
    .{ .name = "peer-reviews-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/peer-reviews-3.0.xml") },
    .{ .name = "person-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/person-3.0.xml") },
    .{ .name = "personal-details-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/personal-details-3.0.xml") },
    .{ .name = "preferences-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/preferences-3.0.xml") },
    .{ .name = "qualification-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/qualification-3.0.xml") },
    .{ .name = "qualifications-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/qualifications-3.0.xml") },
    .{ .name = "record-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/record-3.0.xml") },
    .{ .name = "record-full-3.0.json", .data = @embedFile("record_3.0/samples/read_samples/record-full-3.0.json") },
    .{ .name = "record-no-city-country-for-professional-activities-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/record-no-city-country-for-professional-activities-3.0.xml") },
    .{ .name = "research-resource-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/research-resource-3.0.xml") },
    .{ .name = "research-resources-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/research-resources-3.0.xml") },
    .{ .name = "researcher-url-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/researcher-url-3.0.xml") },
    .{ .name = "researcher-urls-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/researcher-urls-3.0.xml") },
    .{ .name = "search-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/search-3.0.xml") },
    .{ .name = "service-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/service-3.0.xml") },
    .{ .name = "services-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/services-3.0.xml") },
    .{ .name = "work-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/work-3.0.xml") },
    .{ .name = "work-full-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/work-full-3.0.xml") },
    .{ .name = "work-review-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/work-review-3.0.xml") },
    .{ .name = "works-3.0.xml", .data = @embedFile("record_3.0/samples/read_samples/works-3.0.xml") },
};

pub const write_samples = [_]File{
    .{ .name = "address-3.0.json", .data = @embedFile("record_3.0/samples/write_samples/address-3.0.json") },
    .{ .name = "address-3.0.xml", .data = @embedFile("record_3.0/samples/write_samples/address-3.0.xml") },
    .{ .name = "bulk-work-3.0.json", .data = @embedFile("record_3.0/samples/write_samples/bulk-work-3.0.json") },
    .{ .name = "bulk-work-3.0.xml", .data = @embedFile("record_3.0/samples/write_samples/bulk-work-3.0.xml") },
    .{ .name = "bulk-works-100-works-3.0.json", .data = @embedFile("record_3.0/samples/write_samples/bulk-works-100-works-3.0.json") },
    .{ .name = "bulk-works-3-works-3.0.json", .data = @embedFile("record_3.0/samples/write_samples/bulk-works-3-works-3.0.json") },
    .{ .name = "distinction-3.0.json", .data = @embedFile("record_3.0/samples/write_samples/distinction-3.0.json") },
    .{ .name = "distinction-3.0.xml", .data = @embedFile("record_3.0/samples/write_samples/distinction-3.0.xml") },
    .{ .name = "education-3.0.json", .data = @embedFile("record_3.0/samples/write_samples/education-3.0.json") },
    .{ .name = "education-3.0.xml", .data = @embedFile("record_3.0/samples/write_samples/education-3.0.xml") },
    .{ .name = "employment-3.0.json", .data = @embedFile("record_3.0/samples/write_samples/employment-3.0.json") },
    .{ .name = "employment-3.0.xml", .data = @embedFile("record_3.0/samples/write_samples/employment-3.0.xml") },
    .{ .name = "external-identifier-3.0.json", .data = @embedFile("record_3.0/samples/write_samples/external-identifier-3.0.json") },
    .{ .name = "external-identifier-3.0.xml", .data = @embedFile("record_3.0/samples/write_samples/external-identifier-3.0.xml") },
    .{ .name = "funding-3.0-simple.json", .data = @embedFile("record_3.0/samples/write_samples/funding-3.0-simple.json") },
    .{ .name = "funding-3.0-with-NISO-roles.json", .data = @embedFile("record_3.0/samples/write_samples/funding-3.0-with-NISO-roles.json") },
    .{ .name = "funding-3.0.xml", .data = @embedFile("record_3.0/samples/write_samples/funding-3.0.xml") },
    .{ .name = "invited-position-3.0.json", .data = @embedFile("record_3.0/samples/write_samples/invited-position-3.0.json") },
    .{ .name = "invited-position-3.0.xml", .data = @embedFile("record_3.0/samples/write_samples/invited-position-3.0.xml") },
    .{ .name = "keyword-3.0.xml", .data = @embedFile("record_3.0/samples/write_samples/keyword-3.0.xml") },
    .{ .name = "keywords-3.0.json", .data = @embedFile("record_3.0/samples/write_samples/keywords-3.0.json") },
    .{ .name = "membership-3.0.json", .data = @embedFile("record_3.0/samples/write_samples/membership-3.0.json") },
    .{ .name = "membership-3.0.xml", .data = @embedFile("record_3.0/samples/write_samples/membership-3.0.xml") },
    .{ .name = "other-name-3.0.xml", .data = @embedFile("record_3.0/samples/write_samples/other-name-3.0.xml") },
    .{ .name = "other-names-3.0.json", .data = @embedFile("record_3.0/samples/write_samples/other-names-3.0.json") },
    .{ .name = "peer-review-full-3.0-award-subject-type.json", .data = @embedFile("record_3.0/samples/write_samples/peer-review-full-3.0-award-subject-type.json") },
    .{ .name = "peer-review-full-3.0-research-resource.json", .data = @embedFile("record_3.0/samples/write_samples/peer-review-full-3.0-research-resource.json") },
    .{ .name = "peer-review-full-3.0.json", .data = @embedFile("record_3.0/samples/write_samples/peer-review-full-3.0.json") },
    .{ .name = "peer-review-full-3.0.xml", .data = @embedFile("record_3.0/samples/write_samples/peer-review-full-3.0.xml") },
    .{ .name = "peer-review-full-award-subject-type-3.0.xml", .data = @embedFile("record_3.0/samples/write_samples/peer-review-full-award-subject-type-3.0.xml") },
    .{ .name = "peer-review-group-id.json", .data = @embedFile("record_3.0/samples/write_samples/peer-review-group-id.json") },
    .{ .name = "peer-review-simple-3.0.json", .data = @embedFile("record_3.0/samples/write_samples/peer-review-simple-3.0.json") },
    .{ .name = "peer-review-simple-3.0.xml", .data = @embedFile("record_3.0/samples/write_samples/peer-review-simple-3.0.xml") },
    .{ .name = "qualification-3.0.json", .data = @embedFile("record_3.0/samples/write_samples/qualification-3.0.json") },
    .{ .name = "qualification-3.0.xml", .data = @embedFile("record_3.0/samples/write_samples/qualification-3.0.xml") },
    .{ .name = "research-resource-3.0.json", .data = @embedFile("record_3.0/samples/write_samples/research-resource-3.0.json") },
    .{ .name = "research-resource-3.0.xml", .data = @embedFile("record_3.0/samples/write_samples/research-resource-3.0.xml") },
    .{ .name = "researcher-url-3.0-no-name.xml", .data = @embedFile("record_3.0/samples/write_samples/researcher-url-3.0-no-name.xml") },
    .{ .name = "researcher-url-3.0.json", .data = @embedFile("record_3.0/samples/write_samples/researcher-url-3.0.json") },
    .{ .name = "researcher-url-3.0.xml", .data = @embedFile("record_3.0/samples/write_samples/researcher-url-3.0.xml") },
    .{ .name = "researcher-url-no-name-3.0.json", .data = @embedFile("record_3.0/samples/write_samples/researcher-url-no-name-3.0.json") },
    .{ .name = "service-3.0.json", .data = @embedFile("record_3.0/samples/write_samples/service-3.0.json") },
    .{ .name = "service-3.0.xml", .data = @embedFile("record_3.0/samples/write_samples/service-3.0.xml") },
    .{ .name = "work-51-contributors-3.0.json", .data = @embedFile("record_3.0/samples/write_samples/work-51-contributors-3.0.json") },
    .{ .name = "work-full-3.0.json", .data = @embedFile("record_3.0/samples/write_samples/work-full-3.0.json") },
    .{ .name = "work-full-3.0.xml", .data = @embedFile("record_3.0/samples/write_samples/work-full-3.0.xml") },
    .{ .name = "work-simple-3.0.xml", .data = @embedFile("record_3.0/samples/write_samples/work-simple-3.0.xml") },
    .{ .name = "work-with-NISO-roles-51-contributors-3.0.json", .data = @embedFile("record_3.0/samples/write_samples/work-with-NISO-roles-51-contributors-3.0.json") },
};

/// record_3.0/*.xsd and common_3.0/common-3.0.xsd.
pub const xsds = [_]File{
    .{ .name = "activities-3.0.xsd", .data = @embedFile("record_3.0/activities-3.0.xsd") },
    .{ .name = "address-3.0.xsd", .data = @embedFile("record_3.0/address-3.0.xsd") },
    .{ .name = "bulk-3.0.xsd", .data = @embedFile("record_3.0/bulk-3.0.xsd") },
    .{ .name = "distinction-3.0.xsd", .data = @embedFile("record_3.0/distinction-3.0.xsd") },
    .{ .name = "education-3.0.xsd", .data = @embedFile("record_3.0/education-3.0.xsd") },
    .{ .name = "email-3.0.xsd", .data = @embedFile("record_3.0/email-3.0.xsd") },
    .{ .name = "employment-3.0.xsd", .data = @embedFile("record_3.0/employment-3.0.xsd") },
    .{ .name = "error-3.0.xsd", .data = @embedFile("record_3.0/error-3.0.xsd") },
    .{ .name = "expanded-search-3.0.xsd", .data = @embedFile("record_3.0/expanded-search-3.0.xsd") },
    .{ .name = "funding-3.0.xsd", .data = @embedFile("record_3.0/funding-3.0.xsd") },
    .{ .name = "history-3.0.xsd", .data = @embedFile("record_3.0/history-3.0.xsd") },
    .{ .name = "invited-position-3.0.xsd", .data = @embedFile("record_3.0/invited-position-3.0.xsd") },
    .{ .name = "keyword-3.0.xsd", .data = @embedFile("record_3.0/keyword-3.0.xsd") },
    .{ .name = "membership-3.0.xsd", .data = @embedFile("record_3.0/membership-3.0.xsd") },
    .{ .name = "other-name-3.0.xsd", .data = @embedFile("record_3.0/other-name-3.0.xsd") },
    .{ .name = "peer-review-3.0.xsd", .data = @embedFile("record_3.0/peer-review-3.0.xsd") },
    .{ .name = "person-3.0.xsd", .data = @embedFile("record_3.0/person-3.0.xsd") },
    .{ .name = "person-external-identifier-3.0.xsd", .data = @embedFile("record_3.0/person-external-identifier-3.0.xsd") },
    .{ .name = "personal-details-3.0.xsd", .data = @embedFile("record_3.0/personal-details-3.0.xsd") },
    .{ .name = "preferences-3.0.xsd", .data = @embedFile("record_3.0/preferences-3.0.xsd") },
    .{ .name = "qualification-3.0.xsd", .data = @embedFile("record_3.0/qualification-3.0.xsd") },
    .{ .name = "record-3.0.xsd", .data = @embedFile("record_3.0/record-3.0.xsd") },
    .{ .name = "research-resource-3.0.xsd", .data = @embedFile("record_3.0/research-resource-3.0.xsd") },
    .{ .name = "researcher-url-3.0.xsd", .data = @embedFile("record_3.0/researcher-url-3.0.xsd") },
    .{ .name = "search-3.0.xsd", .data = @embedFile("record_3.0/search-3.0.xsd") },
    .{ .name = "service-3.0.xsd", .data = @embedFile("record_3.0/service-3.0.xsd") },
    .{ .name = "work-3.0.xsd", .data = @embedFile("record_3.0/work-3.0.xsd") },
    .{ .name = "common-3.0.xsd", .data = @embedFile("common_3.0/common-3.0.xsd") },
};

/// The public record of 0000-0003-0100-6634 as served by the Public API.
pub const real_record = @embedFile("0000-0003-0100-6634.xml");

/// The public record of 0000-0002-2771-9344 as served by the Public API: a
/// fictitious person's record that ORCID uses as an example, read by the
/// walkthrough.
pub const demo_record = @embedFile("0000-0002-2771-9344.xml");

/// A small Public Data File-shaped archive (`.tar.gz` bytes; stored as .tgz).
pub const dump_tgz = @embedFile("dump/orcid_test_summaries.tgz");

/// A tar in the dump layout (the ORCID sample record and a README) split
/// inside the record into two gzip members, concatenated (`cat a.gz b.gz`);
/// built with Python's tarfile and gzip (level 9, mtime 0), see
/// tests/dump_test.zig.
pub const dump_two_members_tgz = @embedFile("dump/orcid_test_two_members.tgz");

/// ORCID's group-id-3.0 sample (`group-id-record`).
pub const group_id_sample = @embedFile("group-id-3.0/group-id-3.0.xml");

/// A two-record `group-id-records` page: the document of yorc-duckdb's
/// test/sql/orcid_api_messages.test (also yorc-rs's tests/data).
pub const group_id_records = @embedFile("group-id-3.0/group-id-records.xml");

/// Two snapshots of the ORCID sample record (yorc-duckdb's
/// test/data/changes: old.xml is record-3.0.xml, new.xml an edited copy).
pub const changes_old = @embedFile("changes/old.xml");
pub const changes_new = @embedFile("changes/new.xml");

/// Declared XSD names without a model counterpart, with reasons.
pub const xsd_uncovered = @embedFile("xsd_uncovered.txt");

/// A read sample by file name (compile error if it does not exist).
pub fn readSample(comptime name: []const u8) []const u8 {
    return find(&read_samples, name);
}

/// A write sample by file name (compile error if it does not exist).
pub fn writeSample(comptime name: []const u8) []const u8 {
    return find(&write_samples, name);
}

fn find(comptime set: []const File, comptime name: []const u8) []const u8 {
    const data: ?[]const u8 = comptime blk: {
        for (set) |f| {
            if (eql(f.name, name)) break :blk f.data;
        }
        break :blk null;
    };
    return data orelse @compileError("no fixture " ++ name);
}

fn eql(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
