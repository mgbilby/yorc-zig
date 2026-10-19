//! Typed model of the ORCID message schema v3.0 (record_3.0 and common_3.0
//! XSDs): every data-bearing element and attribute has a field. Also the
//! peer-review group ids of group-id-3.0 (`GroupIdRecord`, `GroupIdRecords`).
//!
//! Conventions (the same as yorc-rs's `model`):
//! * Elements with `maxOccurs="1"` are optionals, repeated ones are slices;
//!   every field has a default, so `.{}` is an empty value.
//! * Text is stored trimmed of ASCII space, tab, CR and LF; empty text is null
//!   (yorc-duckdb's rule).
//! * Timestamps (`xs:dateTime`) are kept as the text ORCID sent.
//! * Integers (put-codes, fuzzy-date parts, display index) follow yorc-duckdb:
//!   ASCII digits only, at most 18 (put-code) or 9 digits; anything else is null.
//! * Closed vocabularies are `Vocab(E)`: a known value of enum `E` (whose tag
//!   names are the XML text) or `.other` holding unknown text verbatim, so new
//!   ORCID values never fail a read.
//! * Summary and full forms are separate types (`WorkSummary` / `Work`, ...).
//!
//! Memory: the model holds slices only. Documents produced by the readers
//! own all their memory in one arena (`Document.deinit`). Values you build
//! yourself may point anywhere, as long as it outlives their use.
const std = @import("std");

/// Text of the document (borrowed slice).
pub const Text = []const u8;

/// ORCID put-code (`common:put-code`, an `xs:integer`).
pub const PutCode = i64;

/// A closed vocabulary: `.known` with a value of `E` (tag names are the XML
/// text, e.g. `.@"journal-article"`), or `.other` with text not in the list.
pub fn Vocab(comptime E: type) type {
    return union(enum) {
        known: E,
        other: Text,

        const Self = @This();
        pub const Known = E;

        /// The vocabulary value for `text` (`.other` if it is not known).
        /// `.other` borrows `text`.
        pub fn parse(s: Text) Self {
            if (std.meta.stringToEnum(E, s)) |k| return .{ .known = k };
            return .{ .other = s };
        }

        /// The value as written in ORCID XML.
        pub fn text(v: Self) Text {
            return switch (v) {
                .known => |k| @tagName(k),
                .other => |s| s,
            };
        }

        pub fn isOther(v: Self) bool {
            return v == .other;
        }

        pub fn is(v: Self, k: E) bool {
            return switch (v) {
                .known => |x| x == k,
                .other => false,
            };
        }
    };
}

// ===================================================================== common

/// `common:visibility`.
pub const Visibility = Vocab(enum { private, limited, public, @"registered-only" });

/// `common:relationship-type` (`external-id-relationship`).
pub const Relationship = Vocab(enum { self, @"part-of", @"version-of", @"funded-by" });

/// `common:orcid-id` (`orcid-identifier`, `source-orcid`, `contributor-orcid`,
/// `assertion-origin-orcid`, ...) and, with the same shape, `common:client-id`.
pub const OrcidIdentifier = struct {
    uri: ?Text = null,
    path: ?Text = null,
    host: ?Text = null,
};

/// `common:client-id` (`source-client-id`, `assertion-origin-client-id`).
pub const ClientId = OrcidIdentifier;

/// `common:source-type`.
pub const Source = struct {
    source_orcid: ?OrcidIdentifier = null,
    source_client_id: ?ClientId = null,
    source_name: ?Text = null,
    assertion_origin_orcid: ?OrcidIdentifier = null,
    assertion_origin_client_id: ?ClientId = null,
    assertion_origin_name: ?Text = null,
};

/// `common:element-summary`: the attributes and metadata every activity and
/// person item carries.
pub const ItemMeta = struct {
    /// `@put-code`
    put_code: ?PutCode = null,
    /// `@visibility`
    visibility: ?Visibility = null,
    /// `@display-index` (an `xs:string` in the XSD), parsed with
    /// yorc-duckdb's integer rule, so `-1` is null here.
    display_index: ?i32 = null,
    /// `@display-index` verbatim (trimmed), kept only when it is not exactly
    /// `display_index` in decimal (e.g. `-1`, which ORCID emits). Writers use
    /// it in preference to `display_index`.
    display_index_text: ?Text = null,
    /// `@path`
    path: ?Text = null,
    /// `common:created-date`
    created_date: ?Text = null,
    /// `common:last-modified-date`
    last_modified_date: ?Text = null,
    /// `common:source`
    source: ?Source = null,
};

/// `common:fuzzy-date` (`start-date`, `end-date`, `publication-date`, ...).
pub const FuzzyDate = struct {
    year: ?i32 = null,
    month: ?i32 = null,
    day: ?i32 = null,
};

/// `common:organization-address`.
pub const OrganizationAddress = struct {
    city: ?Text = null,
    region: ?Text = null,
    country: ?Text = null,
};

/// `common:disambiguated-organization`.
pub const DisambiguatedOrganization = struct {
    /// `disambiguated-organization-identifier`
    identifier: ?Text = null,
    /// `disambiguation-source` (GRID, RINGGOLD, FUNDREF, ROR, LEI, ...)
    source: ?Text = null,
};

/// `common:organization`.
pub const Organization = struct {
    name: ?Text = null,
    address: ?OrganizationAddress = null,
    disambiguated_organization: ?DisambiguatedOrganization = null,
};

/// `common:transient-non-empty-string` (`external-id-normalized`).
pub const TransientString = struct {
    value: ?Text = null,
    /// `@transient`
    transient: ?bool = null,
};

/// `common:transient-error` (`external-id-normalized-error`).
pub const TransientError = struct {
    error_code: ?Text = null,
    error_message: ?Text = null,
    /// `@transient`
    transient: ?bool = null,
};

/// `common:external-id` (also the person `external-identifier`, the peer
/// review `subject-external-identifier` and `review-identifiers` entries).
pub const ExternalId = struct {
    /// `common:external-id` extends `element-summary`.
    meta: ItemMeta = .{},
    /// `external-id-type` (doi, isbn, grant_number, agr, ...; an open list)
    id_type: ?Text = null,
    /// `external-id-value`
    value: ?Text = null,
    /// `external-id-normalized`
    normalized: ?TransientString = null,
    /// `external-id-normalized-error`
    normalized_error: ?TransientError = null,
    /// `external-id-url`
    url: ?Text = null,
    /// `external-id-relationship`
    relationship: ?Relationship = null,
};

/// `common:translated-title` (text + `@language-code`).
pub const TranslatedTitle = struct {
    value: ?Text = null,
    language_code: ?Text = null,
};

/// `work:work-title`, `funding:funding-title`, research-resource `title`,
/// `peer-review:subject-name`: `common:title`, `common:subtitle` (works and
/// peer-review subjects only), `common:translated-title`.
pub const Title = struct {
    title: ?Text = null,
    subtitle: ?Text = null,
    translated_title: ?TranslatedTitle = null,
};

/// `common:amount` (text + `@currency-code`).
pub const Amount = struct {
    value: ?Text = null,
    currency_code: ?Text = null,
};

/// `common:country` element (text + `@visibility`), as used by works.
pub const Country = struct {
    value: ?Text = null,
    visibility: ?Visibility = null,
};

/// `contributor-sequence`.
pub const ContributorSequence = Vocab(enum { first, additional });

/// `contributor-role`: the legacy work and funding roles. CRediT role URIs
/// (`https://credit.niso.org/contributor-roles/...`) are `.other`.
pub const ContributorRole = Vocab(enum {
    author,
    assignee,
    editor,
    @"chair-or-translator",
    @"co-investigator",
    @"co-inventor",
    @"graduate-student",
    @"other-inventor",
    @"principal-investigator",
    @"postdoctoral-researcher",
    @"support-staff",
    lead,
    @"co-lead",
    @"supported-by",
    @"other-contribution",
});

/// `contributor-attributes` (works: sequence + role; fundings: role).
pub const ContributorAttributes = struct {
    sequence: ?ContributorSequence = null,
    role: ?ContributorRole = null,
};

/// `work:contributor` / `funding:contributor`.
pub const Contributor = struct {
    contributor_orcid: ?OrcidIdentifier = null,
    credit_name: ?Text = null,
    contributor_email: ?Text = null,
    attributes: ?ContributorAttributes = null,
};

// ====================================================================== works

/// `work:work-type` (the v3.0 values).
pub const WorkType = Vocab(enum {
    annotation,
    @"artistic-performance",
    @"blog-post",
    @"book-chapter",
    @"book-review",
    book,
    @"cartographic-material",
    @"clinical-study",
    @"conference-abstract",
    @"conference-paper",
    @"conference-poster",
    @"conference-output",
    @"conference-presentation",
    @"conference-proceedings",
    @"data-management-plan",
    @"data-set",
    design,
    @"dictionary-entry",
    disclosure,
    dissertation,
    @"dissertation-thesis",
    @"edited-book",
    @"encyclopedia-entry",
    image,
    invention,
    @"journal-article",
    @"journal-issue",
    @"learning-object",
    @"lecture-speech",
    license,
    @"magazine-article",
    manual,
    @"moving-image",
    @"musical-composition",
    @"newsletter-article",
    @"newspaper-article",
    @"online-resource",
    other,
    patent,
    @"physical-object",
    preprint,
    @"public-speech",
    @"registered-copyright",
    report,
    @"research-protocol",
    @"research-technique",
    @"research-tool",
    review,
    software,
    sound,
    @"spin-off-company",
    @"standards-and-policy",
    @"supervised-student-publication",
    @"technical-standard",
    @"test",
    trademark,
    translation,
    undefined,
    website,
    @"working-paper",
});

/// `work:citation-type`.
pub const CitationType = Vocab(enum {
    @"formatted-unspecified",
    bibtex,
    ris,
    @"formatted-apa",
    @"formatted-harvard",
    @"formatted-ieee",
    @"formatted-mla",
    @"formatted-vancouver",
    @"formatted-chicago",
    rif,
    @"csl-json",
});

/// `work:citation`.
pub const Citation = struct {
    citation_type: ?CitationType = null,
    citation_value: ?Text = null,
};

/// `work:work-summary`.
pub const WorkSummary = struct {
    meta: ItemMeta = .{},
    title: ?Title = null,
    external_ids: []const ExternalId = &.{},
    url: ?Text = null,
    work_type: ?WorkType = null,
    publication_date: ?FuzzyDate = null,
    journal_title: ?Text = null,
};

/// `work:work`.
pub const Work = struct {
    meta: ItemMeta = .{},
    title: ?Title = null,
    journal_title: ?Text = null,
    short_description: ?Text = null,
    citation: ?Citation = null,
    work_type: ?WorkType = null,
    publication_date: ?FuzzyDate = null,
    external_ids: []const ExternalId = &.{},
    url: ?Text = null,
    /// `work:contributors/work:contributor`
    contributors: []const Contributor = &.{},
    language_code: ?Text = null,
    country: ?Country = null,
};

/// `activities:work-group` (`activities:group` under `works`).
pub const WorkGroup = struct {
    last_modified_date: ?Text = null,
    external_ids: []const ExternalId = &.{},
    work_summaries: []const WorkSummary = &.{},
};

/// `activities:works`.
pub const Works = struct {
    path: ?Text = null,
    last_modified_date: ?Text = null,
    groups: []const WorkGroup = &.{},
};

// =================================================================== fundings

/// `funding:funding-type`.
pub const FundingType = Vocab(enum { grant, contract, award, @"salary-award" });

/// `funding:funding-summary`.
pub const FundingSummary = struct {
    meta: ItemMeta = .{},
    title: ?Title = null,
    external_ids: []const ExternalId = &.{},
    url: ?Text = null,
    funding_type: ?FundingType = null,
    start_date: ?FuzzyDate = null,
    end_date: ?FuzzyDate = null,
    organization: ?Organization = null,
};

/// `funding:funding`.
pub const Funding = struct {
    meta: ItemMeta = .{},
    funding_type: ?FundingType = null,
    organization_defined_type: ?Text = null,
    title: ?Title = null,
    short_description: ?Text = null,
    amount: ?Amount = null,
    url: ?Text = null,
    start_date: ?FuzzyDate = null,
    end_date: ?FuzzyDate = null,
    external_ids: []const ExternalId = &.{},
    /// `funding:contributors/funding:contributor`
    contributors: []const Contributor = &.{},
    organization: ?Organization = null,
};

/// `activities:funding-group`.
pub const FundingGroup = struct {
    last_modified_date: ?Text = null,
    external_ids: []const ExternalId = &.{},
    funding_summaries: []const FundingSummary = &.{},
};

/// `activities:fundings`.
pub const Fundings = struct {
    path: ?Text = null,
    last_modified_date: ?Text = null,
    groups: []const FundingGroup = &.{},
};

// =============================================================== affiliations

/// The seven affiliation sections; they share `common:affiliation`.
pub const AffiliationKind = enum {
    distinction,
    education,
    employment,
    invited_position,
    membership,
    qualification,
    service,

    pub const all = [_]AffiliationKind{
        .distinction, .education,     .employment, .invited_position,
        .membership,  .qualification, .service,
    };

    /// Element name of the full item: `distinction`, ..., `invited-position`.
    pub fn element(k: AffiliationKind) []const u8 {
        return switch (k) {
            .distinction => "distinction",
            .education => "education",
            .employment => "employment",
            .invited_position => "invited-position",
            .membership => "membership",
            .qualification => "qualification",
            .service => "service",
        };
    }

    /// Element name of the summary item: `distinction-summary`, ...
    pub fn summaryElement(k: AffiliationKind) []const u8 {
        return switch (k) {
            .distinction => "distinction-summary",
            .education => "education-summary",
            .employment => "employment-summary",
            .invited_position => "invited-position-summary",
            .membership => "membership-summary",
            .qualification => "qualification-summary",
            .service => "service-summary",
        };
    }

    /// Element name of the section container: `distinctions`, ...
    pub fn containerElement(k: AffiliationKind) []const u8 {
        return switch (k) {
            .distinction => "distinctions",
            .education => "educations",
            .employment => "employments",
            .invited_position => "invited-positions",
            .membership => "memberships",
            .qualification => "qualifications",
            .service => "services",
        };
    }

    pub fn fromElement(name: []const u8) ?AffiliationKind {
        for (all) |k| if (std.mem.eql(u8, k.element(), name)) return k;
        return null;
    }

    pub fn fromSummaryElement(name: []const u8) ?AffiliationKind {
        for (all) |k| if (std.mem.eql(u8, k.summaryElement(), name)) return k;
        return null;
    }

    pub fn fromContainerElement(name: []const u8) ?AffiliationKind {
        for (all) |k| if (std.mem.eql(u8, k.containerElement(), name)) return k;
        return null;
    }
};

/// `common:affiliation` / `common:affiliation-summary` (identical content):
/// the summary inside groups (`employment-summary`) and the full item
/// (`employment`); the document or container says which.
pub const Affiliation = struct {
    kind: AffiliationKind,
    meta: ItemMeta = .{},
    department_name: ?Text = null,
    role_title: ?Text = null,
    start_date: ?FuzzyDate = null,
    end_date: ?FuzzyDate = null,
    organization: ?Organization = null,
    url: ?Text = null,
    external_ids: []const ExternalId = &.{},
};

/// `activities:affiliation-group`.
pub const AffiliationGroup = struct {
    last_modified_date: ?Text = null,
    external_ids: []const ExternalId = &.{},
    /// `*-summary` items (normally all of the container's kind).
    summaries: []const Affiliation = &.{},
};

/// `activities:distinctions`, `educations`, `employments`,
/// `invited-positions`, `memberships`, `qualifications`, `services`.
pub const Affiliations = struct {
    kind: AffiliationKind,
    path: ?Text = null,
    last_modified_date: ?Text = null,
    groups: []const AffiliationGroup = &.{},
};

// =============================================================== peer reviews

/// `peer-review:role`.
pub const PeerReviewRole = Vocab(enum { reviewer, editor, member, chair, organizer });

/// `peer-review:type`.
pub const PeerReviewType = Vocab(enum { review, evaluation });

/// `peer-review:peer-review-summary`.
pub const PeerReviewSummary = struct {
    meta: ItemMeta = .{},
    reviewer_role: ?PeerReviewRole = null,
    external_ids: []const ExternalId = &.{},
    review_url: ?Text = null,
    review_type: ?PeerReviewType = null,
    completion_date: ?FuzzyDate = null,
    review_group_id: ?Text = null,
    convening_organization: ?Organization = null,
};

/// `peer-review:peer-review`.
pub const PeerReview = struct {
    meta: ItemMeta = .{},
    reviewer_role: ?PeerReviewRole = null,
    /// `review-identifiers/external-id`
    review_identifiers: []const ExternalId = &.{},
    review_url: ?Text = null,
    review_type: ?PeerReviewType = null,
    review_completion_date: ?FuzzyDate = null,
    review_group_id: ?Text = null,
    subject_external_identifier: ?ExternalId = null,
    subject_container_name: ?Text = null,
    /// `subject-type` (work types plus e.g. `award`, `grant`; an open list)
    subject_type: ?Text = null,
    /// `subject-name`: title, subtitle, translated title
    subject_name: ?Title = null,
    subject_url: ?Text = null,
    convening_organization: ?Organization = null,
};

/// `activities:peer-review-duplicates` (element `activities:peer-review-group`).
pub const PeerReviewDuplicates = struct {
    last_modified_date: ?Text = null,
    external_ids: []const ExternalId = &.{},
    summaries: []const PeerReviewSummary = &.{},
};

/// `activities:peer-review-group` (element `activities:group`).
pub const PeerReviewGroup = struct {
    last_modified_date: ?Text = null,
    external_ids: []const ExternalId = &.{},
    duplicates: []const PeerReviewDuplicates = &.{},
};

/// `activities:peer-reviews`.
pub const PeerReviews = struct {
    path: ?Text = null,
    last_modified_date: ?Text = null,
    groups: []const PeerReviewGroup = &.{},
};

// ========================================================= research resources

/// `research-resource:resource-type`.
pub const ResourceType = Vocab(enum { infrastructures, collections, equipment, services });

/// `research-resource:proposal`.
pub const Proposal = struct {
    title: ?Title = null,
    /// `hosts/organization` (1..10)
    hosts: []const Organization = &.{},
    external_ids: []const ExternalId = &.{},
    start_date: ?FuzzyDate = null,
    end_date: ?FuzzyDate = null,
    url: ?Text = null,
};

/// `research-resource:resource-item`.
pub const ResourceItem = struct {
    resource_name: ?Text = null,
    resource_type: ?ResourceType = null,
    hosts: []const Organization = &.{},
    external_ids: []const ExternalId = &.{},
    url: ?Text = null,
};

/// `research-resource:research-resource-summary`.
pub const ResearchResourceSummary = struct {
    meta: ItemMeta = .{},
    proposal: ?Proposal = null,
};

/// `research-resource:research-resource`.
pub const ResearchResource = struct {
    meta: ItemMeta = .{},
    proposal: ?Proposal = null,
    /// `resource-items/resource-item`
    resource_items: []const ResourceItem = &.{},
};

/// `activities:research-resource-group`.
pub const ResearchResourceGroup = struct {
    last_modified_date: ?Text = null,
    external_ids: []const ExternalId = &.{},
    summaries: []const ResearchResourceSummary = &.{},
};

/// `activities:research-resources`.
pub const ResearchResources = struct {
    path: ?Text = null,
    last_modified_date: ?Text = null,
    groups: []const ResearchResourceGroup = &.{},
};

// ========================================================= activities summary

/// `activities:activities-summary`.
pub const ActivitiesSummary = struct {
    path: ?Text = null,
    last_modified_date: ?Text = null,
    distinctions: ?Affiliations = null,
    educations: ?Affiliations = null,
    employments: ?Affiliations = null,
    fundings: ?Fundings = null,
    invited_positions: ?Affiliations = null,
    memberships: ?Affiliations = null,
    peer_reviews: ?PeerReviews = null,
    qualifications: ?Affiliations = null,
    research_resources: ?ResearchResources = null,
    services: ?Affiliations = null,
    works: ?Works = null,

    /// The affiliation container of a kind.
    pub fn affiliations(a: *const ActivitiesSummary, kind: AffiliationKind) ?*const Affiliations {
        const slot = switch (kind) {
            .distinction => &a.distinctions,
            .education => &a.educations,
            .employment => &a.employments,
            .invited_position => &a.invited_positions,
            .membership => &a.memberships,
            .qualification => &a.qualifications,
            .service => &a.services,
        };
        return if (slot.*) |*v| v else null;
    }

    /// Mutable slot of the affiliation container of a kind.
    pub fn affiliationsSlot(a: *ActivitiesSummary, kind: AffiliationKind) *?Affiliations {
        return switch (kind) {
            .distinction => &a.distinctions,
            .education => &a.educations,
            .employment => &a.employments,
            .invited_position => &a.invited_positions,
            .membership => &a.memberships,
            .qualification => &a.qualifications,
            .service => &a.services,
        };
    }

    /// Number of work summaries over all groups.
    pub fn workSummaryCount(a: *const ActivitiesSummary) usize {
        const w = a.works orelse return 0;
        var n: usize = 0;
        for (w.groups) |g| n += g.work_summaries.len;
        return n;
    }

    /// Every work summary, in document order.
    pub fn workSummaries(a: *const ActivitiesSummary) WorkSummaryIterator {
        return .{ .groups = if (a.works) |w| w.groups else &.{} };
    }
};

pub const WorkSummaryIterator = struct {
    groups: []const WorkGroup,
    group: usize = 0,
    item: usize = 0,

    pub fn next(it: *WorkSummaryIterator) ?*const WorkSummary {
        while (it.group < it.groups.len) {
            const g = &it.groups[it.group];
            if (it.item < g.work_summaries.len) {
                it.item += 1;
                return &g.work_summaries[it.item - 1];
            }
            it.group += 1;
            it.item = 0;
        }
        return null;
    }
};

// ===================================================================== person

/// `personal-details:name`.
pub const Name = struct {
    visibility: ?Visibility = null,
    path: ?Text = null,
    created_date: ?Text = null,
    last_modified_date: ?Text = null,
    given_names: ?Text = null,
    family_name: ?Text = null,
    credit_name: ?Text = null,
};

/// `personal-details:biography`.
pub const Biography = struct {
    visibility: ?Visibility = null,
    path: ?Text = null,
    created_date: ?Text = null,
    last_modified_date: ?Text = null,
    content: ?Text = null,
};

/// `other-name:other-name`.
pub const OtherName = struct {
    meta: ItemMeta = .{},
    content: ?Text = null,
};

/// `researcher-url:researcher-url`.
pub const ResearcherUrl = struct {
    meta: ItemMeta = .{},
    url_name: ?Text = null,
    url: ?Text = null,
};

/// `email:email`.
pub const Email = struct {
    meta: ItemMeta = .{},
    email: ?Text = null,
    /// `@verified`
    verified: ?bool = null,
    /// `@primary`
    primary: ?bool = null,
};

/// `address:address`.
pub const Address = struct {
    meta: ItemMeta = .{},
    /// ISO 3166 country code
    country: ?Text = null,
};

/// `keyword:keyword`.
pub const Keyword = struct {
    meta: ItemMeta = .{},
    content: ?Text = null,
};

/// `external-identifier:external-identifier` (a `common:external-id`).
pub const PersonExternalIdentifier = ExternalId;

/// A person item container: `other-names`, `researcher-urls`, `emails`,
/// `addresses`, `keywords`, `external-identifiers`.
pub fn ItemList(comptime T: type) type {
    return struct {
        path: ?Text = null,
        last_modified_date: ?Text = null,
        items: []const T = &.{},
    };
}

pub const OtherNames = ItemList(OtherName);
pub const ResearcherUrls = ItemList(ResearcherUrl);
pub const Emails = ItemList(Email);
pub const Addresses = ItemList(Address);
pub const Keywords = ItemList(Keyword);
pub const ExternalIdentifiers = ItemList(PersonExternalIdentifier);

/// `person:person`.
pub const Person = struct {
    path: ?Text = null,
    last_modified_date: ?Text = null,
    name: ?Name = null,
    other_names: ?OtherNames = null,
    biography: ?Biography = null,
    researcher_urls: ?ResearcherUrls = null,
    emails: ?Emails = null,
    addresses: ?Addresses = null,
    keywords: ?Keywords = null,
    external_identifiers: ?ExternalIdentifiers = null,
};

/// `personal-details:personal-details`.
pub const PersonalDetails = struct {
    path: ?Text = null,
    last_modified_date: ?Text = null,
    name: ?Name = null,
    other_names: ?OtherNames = null,
    biography: ?Biography = null,
};

// ===================================================================== record

/// `history:creation-method`.
pub const CreationMethod = Vocab(enum { API, Direct, @"Member-referred", website });

/// `history:history`.
pub const History = struct {
    visibility: ?Visibility = null,
    creation_method: ?CreationMethod = null,
    completion_date: ?Text = null,
    submission_date: ?Text = null,
    last_modified_date: ?Text = null,
    claimed: ?bool = null,
    source: ?Source = null,
    deactivation_date: ?Text = null,
    verified_email: ?bool = null,
    verified_primary_email: ?bool = null,
};

/// `preferences:preferences`.
pub const Preferences = struct {
    locale: ?Text = null,
};

/// `record:record`.
pub const Record = struct {
    path: ?Text = null,
    orcid_identifier: ?OrcidIdentifier = null,
    preferences: ?Preferences = null,
    history: ?History = null,
    person: ?Person = null,
    activities_summary: ?ActivitiesSummary = null,
};

/// `error:error` (API error body; also a bulk item).
pub const OrcidError = struct {
    response_code: ?i64 = null,
    developer_message: ?Text = null,
    user_message: ?Text = null,
    error_code: ?i64 = null,
    more_info: ?Text = null,
};

/// One entry of `bulk:bulk`.
pub const BulkItem = union(enum) {
    work: Work,
    @"error": OrcidError,
};

/// `bulk:bulk` (bulk work read/write).
pub const Bulk = struct {
    items: []const BulkItem = &.{},
};

/// `search:search`.
pub const Search = struct {
    /// `@num-found`
    num_found: ?i64 = null,
    /// `result/orcid-identifier`
    results: []const OrcidIdentifier = &.{},
};

/// `expanded-search:expanded-result`.
pub const ExpandedResult = struct {
    orcid_id: ?Text = null,
    given_names: ?Text = null,
    family_names: ?Text = null,
    credit_name: ?Text = null,
    other_names: []const Text = &.{},
    emails: []const Text = &.{},
    institution_names: []const Text = &.{},
};

/// `expanded-search:expanded-search`.
pub const ExpandedSearch = struct {
    /// `@num-found`
    num_found: ?i64 = null,
    results: []const ExpandedResult = &.{},
};

// ================================================================ group ids

/// `group-id:type`: the kind of group a peer review belongs to.
pub const GroupType = Vocab(enum { publisher, institution, journal, conference, newspaper, newsletter, magazine, @"peer-review service" });

/// `group-id:group-id-record` (group-id-3.0), as ORCID's `GroupIdRecord`.
/// The XSD extends common-2.1's `source-type`, so the source fields may sit
/// directly in the record; both forms read into `source`, and the writers
/// write `common:source`.
pub const GroupIdRecord = struct {
    /// `@put-code`
    put_code: ?PutCode = null,
    /// `common:created-date` (XML only: ORCID's JSON leaves it out).
    created_date: ?Text = null,
    /// `common:last-modified-date` (XML only, as `created_date`).
    last_modified_date: ?Text = null,
    name: ?Text = null,
    group_id: ?Text = null,
    description: ?Text = null,
    /// `type`
    group_type: ?GroupType = null,
    source: ?Source = null,
};

/// `group-id:group-id-records`: one page of group-id records.
pub const GroupIdRecords = struct {
    last_modified_date: ?Text = null,
    /// `total`, `page`, `page-size`: 1 to 9 ASCII digits, else null.
    total: ?i64 = null,
    page: ?i64 = null,
    page_size: ?i64 = null,
    records: []const GroupIdRecord = &.{},
};

/// The root element of an ORCID v3.0 document.
pub const Root = union(enum) {
    record: Record,
    activities_summary: ActivitiesSummary,
    works: Works,
    work: Work,
    work_summary: WorkSummary,
    fundings: Fundings,
    funding: Funding,
    funding_summary: FundingSummary,
    /// `distinctions`, `educations`, ... (the kind is inside)
    affiliations: Affiliations,
    /// `distinction`, `education`, ... (full item)
    affiliation: Affiliation,
    /// `distinction-summary`, ...
    affiliation_summary: Affiliation,
    peer_reviews: PeerReviews,
    peer_review: PeerReview,
    peer_review_summary: PeerReviewSummary,
    research_resources: ResearchResources,
    research_resource: ResearchResource,
    research_resource_summary: ResearchResourceSummary,
    person: Person,
    personal_details: PersonalDetails,
    name: Name,
    biography: Biography,
    /// `personal-details:credit-name`
    credit_name: ?Text,
    other_names: OtherNames,
    other_name: OtherName,
    researcher_urls: ResearcherUrls,
    researcher_url: ResearcherUrl,
    emails: Emails,
    email: Email,
    addresses: Addresses,
    address: Address,
    keywords: Keywords,
    keyword: Keyword,
    external_identifiers: ExternalIdentifiers,
    external_identifier: PersonExternalIdentifier,
    history: History,
    preferences: Preferences,
    bulk: Bulk,
    @"error": OrcidError,
    search: Search,
    expanded_search: ExpandedSearch,
    /// `group-id:group-id-record` (group-id-3.0).
    group_id_record: GroupIdRecord,
    /// `group-id:group-id-records` (group-id-3.0), a page of records.
    group_id_records: GroupIdRecords,
    /// A root element this library does not know (its local name).
    unknown: Text,

    /// The document kind: the local name of the XML root element (`record`,
    /// `work`, `employment`, `works`, `bulk`, ...), null for `.unknown`.
    pub fn kind(r: Root) ?[]const u8 {
        return switch (r) {
            .record => "record",
            .activities_summary => "activities-summary",
            .works => "works",
            .work => "work",
            .work_summary => "work-summary",
            .fundings => "fundings",
            .funding => "funding",
            .funding_summary => "funding-summary",
            .affiliations => |a| a.kind.containerElement(),
            .affiliation => |a| a.kind.element(),
            .affiliation_summary => |a| a.kind.summaryElement(),
            .peer_reviews => "peer-reviews",
            .peer_review => "peer-review",
            .peer_review_summary => "peer-review-summary",
            .research_resources => "research-resources",
            .research_resource => "research-resource",
            .research_resource_summary => "research-resource-summary",
            .person => "person",
            .personal_details => "personal-details",
            .name => "name",
            .biography => "biography",
            .credit_name => "credit-name",
            .other_names => "other-names",
            .other_name => "other-name",
            .researcher_urls => "researcher-urls",
            .researcher_url => "researcher-url",
            .emails => "emails",
            .email => "email",
            .addresses => "addresses",
            .address => "address",
            .keywords => "keywords",
            .keyword => "keyword",
            .external_identifiers => "external-identifiers",
            .external_identifier => "external-identifier",
            .history => "history",
            .preferences => "preferences",
            .bulk => "bulk",
            .@"error" => "error",
            .search => "search",
            .expanded_search => "expanded-search",
            .group_id_record => "group-id-record",
            .group_id_records => "group-id-records",
            .unknown => null,
        };
    }
};

/// Every document kind the readers accept (XML root local names).
pub const kinds = [_][]const u8{
    "record",                "activities-summary",        "works",
    "work",                  "work-summary",              "fundings",
    "funding",               "funding-summary",           "distinctions",
    "educations",            "employments",               "invited-positions",
    "memberships",           "qualifications",            "services",
    "distinction",           "education",                 "employment",
    "invited-position",      "membership",                "qualification",
    "service",               "distinction-summary",       "education-summary",
    "employment-summary",    "invited-position-summary",  "membership-summary",
    "qualification-summary", "service-summary",           "peer-reviews",
    "peer-review",           "peer-review-summary",       "research-resources",
    "research-resource",     "research-resource-summary", "person",
    "personal-details",      "name",                      "biography",
    "credit-name",           "other-names",               "other-name",
    "researcher-urls",       "researcher-url",            "emails",
    "email",                 "addresses",                 "address",
    "keywords",              "keyword",                   "external-identifiers",
    "external-identifier",   "history",                   "preferences",
    "bulk",                  "error",                     "search",
    "expanded-search",       "group-id-record",           "group-id-records",
};

/// A parsed ORCID document. Documents returned by `xml.parse` and
/// `json.parse` own every byte they reference; call `deinit`.
pub const Document = struct {
    /// Owner of the document's memory; null for documents built by hand.
    arena: ?*std.heap.ArenaAllocator = null,
    /// Local name of the root element (the kind, for JSON).
    root_name: Text,
    /// The root element's `path` attribute as written (any root may carry
    /// one; yorc-duckdb takes the record's iD from it).
    root_path: ?Text = null,
    root: Root,

    pub fn deinit(doc: *Document) void {
        if (doc.arena) |a| {
            const child = a.child_allocator;
            a.deinit();
            child.destroy(a);
        }
        doc.* = undefined;
    }

    /// The record, if this is a `record:record` document.
    pub fn record(doc: *const Document) ?*const Record {
        return switch (doc.root) {
            .record => |*r| r,
            else => null,
        };
    }

    /// The activities summary of a record or an `activities-summary` document.
    pub fn activitiesSummary(doc: *const Document) ?*const ActivitiesSummary {
        return switch (doc.root) {
            .record => |*r| if (r.activities_summary) |*a| a else null,
            .activities_summary => |*a| a,
            else => null,
        };
    }

    /// The record's iD as yorc-duckdb determines it: the first segment of
    /// the root `path` attribute (`/0000-0003-0100-6634` →
    /// `0000-0003-0100-6634`), else the first non-empty
    /// `orcid-identifier/path`.
    pub fn orcid(doc: *const Document) ?Text {
        if (doc.root_path) |p| {
            const seg = firstPathSegment(trimXmlSpace(p));
            if (seg.len > 0) return seg;
        }
        switch (doc.root) {
            .record => |*r| if (r.orcid_identifier) |*id| return identifierPath(id),
            .search => |*s| for (s.results) |*id| {
                if (identifierPath(id)) |p| return p;
            },
            else => {},
        }
        return null;
    }
};

fn identifierPath(id: *const OrcidIdentifier) ?Text {
    const p = id.path orelse return null;
    return if (p.len > 0) p else null;
}

/// Trims ASCII space, tab, CR and LF (yorc-duckdb's `Trim`).
pub fn trimXmlSpace(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// First segment of an ORCID element path:
/// `/0000-0003-0100-6634/work/1` → `0000-0003-0100-6634`.
pub fn firstPathSegment(path: []const u8) []const u8 {
    const rest = if (path.len > 0 and path[0] == '/') path[1..] else path;
    return if (std.mem.indexOfScalar(u8, rest, '/')) |i| rest[0..i] else rest;
}

// ============================================================ deep equality

/// Deep structural equality of two model values of the same type: slices
/// compare element by element, unions by tag and payload, optionals by
/// presence and payload. (`std.meta.eql` compares slices by address.)
pub fn eql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    switch (@typeInfo(T)) {
        .void => return true,
        .bool, .int, .float, .@"enum", .comptime_int => return a == b,
        .optional => {
            if (a) |pa| {
                if (b) |pb| return eql(pa, pb);
                return false;
            }
            return b == null;
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.child == u8) return std.mem.eql(u8, a, b);
                if (a.len != b.len) return false;
                for (a, b) |x, y| if (!eql(x, y)) return false;
                return true;
            },
            .one => return eql(a.*, b.*),
            else => @compileError("eql: unsupported pointer type " ++ @typeName(T)),
        },
        .array => {
            for (a, b) |x, y| if (!eql(x, y)) return false;
            return true;
        },
        .@"struct" => |s| {
            inline for (s.field_names) |name| {
                if (!eql(@field(a, name), @field(b, name))) return false;
            }
            return true;
        },
        .@"union" => |u| {
            const Tag = u.tag_type orelse @compileError("eql: untagged union " ++ @typeName(T));
            if (@as(Tag, a) != @as(Tag, b)) return false;
            switch (a) {
                inline else => |pa, tag| return eql(pa, @field(b, @tagName(tag))),
            }
        },
        else => @compileError("eql: unsupported type " ++ @typeName(T)),
    }
}

/// Like `eql`, but on a difference writes the path of the first differing
/// field (e.g. `.record.person.name.given_names`) into `path` and returns
/// false. For test diagnostics.
pub fn firstDifference(a: anytype, b: @TypeOf(a), path: *std.ArrayList(u8), gpa: std.mem.Allocator) error{OutOfMemory}!bool {
    const T = @TypeOf(a);
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            inline for (s.field_names) |name| {
                const len = path.items.len;
                try path.appendSlice(gpa, "." ++ name);
                if (!try firstDifference(@field(a, name), @field(b, name), path, gpa)) return false;
                path.shrinkRetainingCapacity(len);
            }
            return true;
        },
        .optional => {
            if (a) |pa| {
                if (b) |pb| return firstDifference(pa, pb, path, gpa);
                try path.appendSlice(gpa, " (null on the right)");
                return false;
            }
            if (b != null) {
                try path.appendSlice(gpa, " (null on the left)");
                return false;
            }
            return true;
        },
        .pointer => |p| if (p.size == .slice and p.child != u8) {
            if (a.len != b.len) {
                try path.print(gpa, " (length {d} vs {d})", .{ a.len, b.len });
                return false;
            }
            for (a, b, 0..) |x, y, i| {
                const len = path.items.len;
                try path.print(gpa, "[{d}]", .{i});
                if (!try firstDifference(x, y, path, gpa)) return false;
                path.shrinkRetainingCapacity(len);
            }
            return true;
        } else {
            if (eql(a, b)) return true;
            if (p.size == .slice) try path.print(gpa, " (\"{s}\" vs \"{s}\")", .{ a, b });
            return false;
        },
        .@"union" => |u| {
            const Tag = u.tag_type.?;
            if (@as(Tag, a) != @as(Tag, b)) {
                try path.print(gpa, " (.{s} vs .{s})", .{ @tagName(@as(Tag, a)), @tagName(@as(Tag, b)) });
                return false;
            }
            switch (a) {
                inline else => |pa, tag| {
                    try path.appendSlice(gpa, "." ++ @tagName(tag));
                    return firstDifference(pa, @field(b, @tagName(tag)), path, gpa);
                },
            }
        },
        else => {
            if (eql(a, b)) return true;
            try path.print(gpa, " ({any} vs {any})", .{ a, b });
            return false;
        },
    }
}

test "vocabularies keep unknown values" {
    const w = WorkType.parse("journal-article");
    try std.testing.expect(w.is(.@"journal-article"));
    try std.testing.expectEqualStrings("journal-article", w.text());
    const o = WorkType.parse("new-type");
    try std.testing.expect(o.isOther());
    try std.testing.expectEqualStrings("new-type", o.text());
    try std.testing.expectEqualStrings("registered-only", Visibility.parse("registered-only").text());
    try std.testing.expectEqualStrings("Member-referred", (CreationMethod{ .known = .@"Member-referred" }).text());
}

test "document orcid from path or identifier" {
    const d1: Document = .{ .root_name = "record", .root_path = " /0000-0003-0100-6634 ", .root = .{ .record = .{} } };
    try std.testing.expectEqualStrings("0000-0003-0100-6634", d1.orcid().?);
    const d2: Document = .{ .root_name = "record", .root = .{ .record = .{
        .orcid_identifier = .{ .path = "0000-0002-1825-0097" },
    } } };
    try std.testing.expectEqualStrings("0000-0002-1825-0097", d2.orcid().?);
    try std.testing.expectEqualStrings("a", firstPathSegment("/a/work/1"));
}

test "deep equality" {
    const a: Work = .{ .title = .{ .title = "x" }, .external_ids = &.{.{ .value = "1" }} };
    const b: Work = .{ .title = .{ .title = "x" }, .external_ids = &.{.{ .value = "1" }} };
    const c: Work = .{ .title = .{ .title = "x" }, .external_ids = &.{.{ .value = "2" }} };
    try std.testing.expect(eql(a, b));
    try std.testing.expect(!eql(a, c));
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(std.testing.allocator);
    try std.testing.expect(!try firstDifference(a, c, &path, std.testing.allocator));
    try std.testing.expect(std.mem.startsWith(u8, path.items, ".external_ids[0].value"));
}
