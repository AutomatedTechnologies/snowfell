// SnapshotStore — Snowfell's local SQLite snapshot cache.
//
// The app reads a PINNED, HASH-VERIFIED registry snapshot (design record §2,
// the distro-test-39+ build-query contract): the database is verified
// against its manifest — SHA-256 and byte size — BEFORE it is opened, and a
// mismatch halts the load. There is no fallback to an unverified database.
// The snapshot is opened READ-ONLY through the sqlite3 C API; SF-T2 writes
// nothing, anywhere.
#import <Foundation/Foundation.h>

@class BoardSummary;
@class BoardItem;
@class ItemFieldValue;
@class ElementHandler;
@class StatusField;
@class SFAction;
@class DeployTarget;
@class IncidentSummary;
@class IncidentDetail;
@class DatedItem;
@class DraftRow;
@class PaletteResult;

NS_ASSUME_NONNULL_BEGIN

extern NSString * const SnapshotStoreErrorDomain;

typedef NS_ENUM(NSInteger, SnapshotStoreError) {
    SnapshotStoreErrorSnapshotNotFound = 1,
    SnapshotStoreErrorManifestNotFound = 2,
    SnapshotStoreErrorManifestMalformed = 3,
    SnapshotStoreErrorSizeMismatch = 4,
    SnapshotStoreErrorHashMismatch = 5,
    SnapshotStoreErrorOpenFailed = 6,
    SnapshotStoreErrorQueryFailed = 7,
};

@interface SnapshotStore : NSObject

// Set only after a snapshot has been verified AND opened.
@property (nonatomic, copy, readonly, nullable) NSString *snapshotPath;
@property (nonatomic, copy, readonly, nullable) NSDictionary *manifest;
@property (nonatomic, strong, readonly, nullable) NSError *loadError;

// Convenience accessors over the verified manifest.
@property (nonatomic, copy, readonly, nullable) NSString *snapshotVersion;  // e.g. "v7-0026"
@property (nonatomic, copy, readonly, nullable) NSString *snapshotSHA256;

// Loads the bundled snapshot: Resources/registry.db verified against
// Resources/snapshot-manifest.json. Returns YES only on verified open.
- (BOOL)loadBundledSnapshot;

// Loads an explicit snapshot pair (File > Open Snapshot...). Same contract:
// verify first, open read-only, halt on any mismatch.
- (BOOL)loadSnapshotAtPath:(NSString *)databasePath
              manifestPath:(NSString *)manifestPath;

// Pure verification: size + SHA-256 of the file at databasePath against the
// manifest dictionary (keys: size_bytes, sha256 — the snapshot-manifest.json
// shape published by academy-registry's publish_snapshot.py).
+ (BOOL)verifyDatabaseAtPath:(NSString *)databasePath
             againstManifest:(NSDictionary *)manifest
                       error:(NSError **)error;

// V2 Portfolio data: every board in sf_boards with its Status-vocabulary
// summary composed from sf_item_values. Requires a verified open snapshot;
// returns nil and sets error when no snapshot is loaded.
- (nullable NSArray<BoardSummary *> *)portfolioBoardsWithError:(NSError **)error;

// SF-T3 read queries (V1 Board + V3 Detail). Same contract as the Portfolio
// query: read-only SELECTs against the already-verified open snapshot.

// The board's Status options in the board's own sf_field_options order —
// the V1 column derivation. Vocabulary is per-board data, never hardcoded.
- (nullable NSArray<NSString *> *)statusOptionsForBoard:(NSString *)boardNodeID
                                                  error:(NSError **)error;

// Every item on the board, each carrying its Status option_name and its
// parsed Labels from the EAV layer, in snapshot (import) order.
- (nullable NSArray<BoardItem *> *)itemsForBoard:(NSString *)boardNodeID
                                           error:(NSError **)error;

// Every EAV value stored for one item, ordered by the board's field order
// (sf_fields.position) — the V3 field list.
- (nullable NSArray<ItemFieldValue *> *)fieldValuesForItem:(NSString *)itemNodeID
                                                     error:(NSError **)error;

// The element-kind → handler-app routing table (design §9.1), as stored.
- (nullable NSArray<ElementHandler *> *)elementHandlersWithError:(NSError **)error;

// SF-T4 write-back addressing: the board's Status field with its GitHub
// field ID and per-option GitHub option IDs (sf_fields.gh_field_id /
// sf_field_options.gh_option_id). Read-only like every query here; the
// IDs feed WriteBackQueue payloads, never a direct mutation from the UI.
- (nullable StatusField *)statusFieldForBoard:(NSString *)boardNodeID
                                        error:(NSError **)error;

// SF-T5 orchestration queries (V4). Same contract as every query above:
// read-only SELECTs against the already-verified open snapshot.

// The action manifest, as stored (design record §3: actions are data).
// Every row, enabled or not, in sf_actions.id order.
- (nullable NSArray<SFAction *> *)actionsWithError:(NSError **)error;

// The deploy targets at account granularity (design record §11.1), as
// stored — the composer's target_id dropdown source.
- (nullable NSArray<DeployTarget *> *)deployTargetsWithError:(NSError **)error;

// SF-T7 queries (V5 Roadmap + V6 Palette + the §11.3 drafts scope).
// Same contract as every query above: read-only SELECTs against the
// already-verified open snapshot.

// Every item carrying at least one date value (its board's 'Start date'
// and/or 'Target date' EAV value, date_value non-NULL), grouped-ready:
// ordered by board (owner, number) then title; each row carries both
// stored ISO date texts (either may be nil — a one-ended item is a
// milestone, never a fabricated span). Items with no date value are
// excluded by definition; boards without date fields contribute none.
- (nullable NSArray<DatedItem *> *)datedItemsWithError:(NSError **)error;

// How many boards carry a 'Start date' or 'Target date' field at all
// (19 of 74 in snapshot v7-0026) — the Roadmap header's denominator.
// Returns -1 and sets error when no snapshot is loaded.
- (NSInteger)boardsWithDateFieldsCountWithError:(NSError **)error;

// One item by node ID, with the same Status/Labels EAV dressing
// itemsForBoard: applies — the palette's item-routing resolution.
- (nullable BoardItem *)itemWithNodeID:(NSString *)itemNodeID
                                 error:(NSError **)error;

// Unified ⌘K search over the five palette scopes (boards by title,
// items by title, actions by id/name, deploy targets by
// id/platform/account, drafts by name/item/board/account — the
// sf_upcoming_drafts projection). Matching is a case-insensitive
// substring (SQL LIKE with the query's LIKE metacharacters escaped);
// an empty query browses boards/actions/targets/drafts and skips
// items (614 titles are not a browse list). Per-scope cap 50.
- (nullable NSArray<PaletteResult *> *)paletteResultsForQuery:(NSString *)query
                                                        error:(NSError **)error;

// Every row of the sf_upcoming_drafts view (design record §11.3), in
// scheduled order (publish_at NULLs last, then name). Zero rows is a
// truthful result — the view is empty until compositions exist.
- (nullable NSArray<DraftRow *> *)draftRowsWithError:(NSError **)error;

// SF-T11 queries (V11 Incidents; design record §12.5). Same contract as
// every query above: read-only SELECTs against the verified snapshot.
// State and severity names are the snapshot's own vocabulary rows
// (sf_incident_states / sf_incident_severities), joined — never an
// app-side enum (§12.1). A snapshot predating changes/0031 has no
// incident tables: the queries return an empty array, not an error,
// and the lens states the snapshot's version as the reason.

// The incident queue: every sf_incidents row with its state/severity
// names, counterparty, asset count, and next open deadline, ordered
// by next deadline (deadline-less last), then severity position DESC.
- (nullable NSArray<IncidentSummary *> *)incidentSummariesWithError:(NSError **)error;

// One incident in full: summary + deadlines (due order) + assets
// (id order), by its human key. Nil when the key is unknown.
- (nullable IncidentDetail *)incidentDetailForKey:(NSString *)key
                                            error:(NSError **)error;

- (void)close;

@end

NS_ASSUME_NONNULL_END
