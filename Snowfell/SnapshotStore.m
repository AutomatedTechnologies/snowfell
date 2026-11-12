#import "SnapshotStore.h"
#import "BoardSummary.h"
#import "BoardItem.h"
#import "ItemFieldValue.h"
#import "ElementHandler.h"
#import "StatusField.h"
#import "SFAction.h"
#import "DeployTarget.h"
#import "DatedItem.h"
#import "DraftRow.h"
#import "PaletteResult.h"
#import "IncidentModels.h"
#import <sqlite3.h>
#import <CommonCrypto/CommonDigest.h>

NSString * const SnapshotStoreErrorDomain = @"com.detroitautomationacademy.snowfell.SnapshotStore";

@interface SnapshotStore () {
    sqlite3 *_db;
}
@property (nonatomic, copy, readwrite, nullable) NSString *snapshotPath;
@property (nonatomic, copy, readwrite, nullable) NSDictionary *manifest;
@property (nonatomic, strong, readwrite, nullable) NSError *loadError;
@end

@implementation SnapshotStore

- (void)dealloc {
    [self close];
}

- (void)close {
    if (_db != NULL) {
        sqlite3_close(_db);
        _db = NULL;
    }
    self.snapshotPath = nil;
    self.manifest = nil;
}

- (NSString *)snapshotVersion {
    return self.manifest[@"version"];
}

- (NSString *)snapshotSHA256 {
    return self.manifest[@"sha256"];
}

#pragma mark - Verification

+ (NSError *)errorWithCode:(SnapshotStoreError)code description:(NSString *)description {
    return [NSError errorWithDomain:SnapshotStoreErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

+ (BOOL)verifyDatabaseAtPath:(NSString *)databasePath
             againstManifest:(NSDictionary *)manifest
                       error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:databasePath error:error];
    if (attributes == nil) {
        return NO;
    }

    NSNumber *expectedSize = manifest[@"size_bytes"];
    NSString *expectedHash = manifest[@"sha256"];
    if (![expectedSize isKindOfClass:[NSNumber class]] || ![expectedHash isKindOfClass:[NSString class]]) {
        if (error != NULL) {
            *error = [self errorWithCode:SnapshotStoreErrorManifestMalformed
                             description:@"Snapshot manifest lacks size_bytes / sha256; refusing to open an unverifiable database."];
        }
        return NO;
    }

    unsigned long long actualSize = [attributes fileSize];
    if (actualSize != [expectedSize unsignedLongLongValue]) {
        if (error != NULL) {
            *error = [self errorWithCode:SnapshotStoreErrorSizeMismatch
                             description:[NSString stringWithFormat:
                                          @"Snapshot size mismatch: manifest %llu bytes, file %llu bytes. Load halted; no fallback.",
                                          [expectedSize unsignedLongLongValue], actualSize]];
        }
        return NO;
    }

    // Streaming SHA-256 (the snapshot is ~2 MB today; stream anyway so the
    // contract holds at any size).
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:databasePath];
    [stream open];
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    uint8_t buffer[64 * 1024];
    NSInteger bytesRead = 0;
    while ((bytesRead = [stream read:buffer maxLength:sizeof(buffer)]) > 0) {
        CC_SHA256_Update(&context, buffer, (CC_LONG)bytesRead);
    }
    [stream close];
    if (bytesRead < 0) {
        if (error != NULL) {
            *error = [self errorWithCode:SnapshotStoreErrorHashMismatch
                             description:@"Snapshot could not be read for hashing. Load halted; no fallback."];
        }
        return NO;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *actualHash = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [actualHash appendFormat:@"%02x", digest[i]];
    }
    if (![actualHash isEqualToString:[expectedHash lowercaseString]]) {
        if (error != NULL) {
            *error = [self errorWithCode:SnapshotStoreErrorHashMismatch
                             description:[NSString stringWithFormat:
                                          @"Snapshot SHA-256 mismatch: manifest %@, file %@. Load halted; no fallback.",
                                          expectedHash, actualHash]];
        }
        return NO;
    }
    return YES;
}

#pragma mark - Loading

- (BOOL)loadBundledSnapshot {
    NSString *databasePath = [[NSBundle mainBundle] pathForResource:@"registry" ofType:@"db"];
    NSString *manifestPath = [[NSBundle mainBundle] pathForResource:@"snapshot-manifest" ofType:@"json"];
    if (databasePath == nil) {
        self.loadError = [[self class] errorWithCode:SnapshotStoreErrorSnapshotNotFound
                                         description:@"Bundled registry.db snapshot not found in Resources."];
        return NO;
    }
    if (manifestPath == nil) {
        self.loadError = [[self class] errorWithCode:SnapshotStoreErrorManifestNotFound
                                         description:@"Bundled snapshot-manifest.json not found in Resources."];
        return NO;
    }
    return [self loadSnapshotAtPath:databasePath manifestPath:manifestPath];
}

- (BOOL)loadSnapshotAtPath:(NSString *)databasePath manifestPath:(NSString *)manifestPath {
    [self close];

    NSData *manifestData = [NSData dataWithContentsOfFile:manifestPath];
    NSDictionary *manifest = nil;
    if (manifestData != nil) {
        manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:NULL];
    }
    if (![manifest isKindOfClass:[NSDictionary class]]) {
        self.loadError = [[self class] errorWithCode:SnapshotStoreErrorManifestMalformed
                                         description:[NSString stringWithFormat:
                                                      @"Snapshot manifest at %@ is not valid JSON. Load halted.", manifestPath]];
        return NO;
    }

    NSError *verifyError = nil;
    if (![[self class] verifyDatabaseAtPath:databasePath againstManifest:manifest error:&verifyError]) {
        self.loadError = verifyError;
        return NO;
    }

    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2([databasePath fileSystemRepresentation], &db, SQLITE_OPEN_READONLY, NULL);
    if (rc != SQLITE_OK) {
        NSString *message = (db != NULL) ? [NSString stringWithUTF8String:sqlite3_errmsg(db)] : @"sqlite3_open_v2 failed";
        if (db != NULL) {
            sqlite3_close(db);
        }
        self.loadError = [[self class] errorWithCode:SnapshotStoreErrorOpenFailed
                                         description:[NSString stringWithFormat:
                                                      @"Verified snapshot could not be opened read-only: %@", message]];
        return NO;
    }

    _db = db;
    self.snapshotPath = databasePath;
    self.manifest = manifest;
    self.loadError = nil;
    return YES;
}

#pragma mark - Portfolio query

static NSString *ColumnText(sqlite3_stmt *statement, int column) {
    const unsigned char *text = sqlite3_column_text(statement, column);
    return (text != NULL) ? [NSString stringWithUTF8String:(const char *)text] : @"";
}

static NSString *ColumnNullableText(sqlite3_stmt *statement, int column) {
    if (sqlite3_column_type(statement, column) == SQLITE_NULL) {
        return nil;
    }
    const unsigned char *text = sqlite3_column_text(statement, column);
    return (text != NULL) ? [NSString stringWithUTF8String:(const char *)text] : nil;
}

- (NSError *)queryErrorWithDescription:(NSString *)description {
    return [[self class] errorWithCode:SnapshotStoreErrorQueryFailed description:description];
}

- (BOOL)requireOpenDatabase:(NSError **)error {
    if (_db == NULL) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:SnapshotStoreErrorOpenFailed
                                     description:@"No verified snapshot is loaded."];
        }
        return NO;
    }
    return YES;
}

// The board's Status options in the board's own order (sf_field_options.position).
- (NSArray<NSString *> *)statusOptionNamesForBoard:(NSString *)boardNodeID {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    const char *sql =
        "SELECT o.name FROM sf_fields f "
        "JOIN sf_field_options o ON o.field_id = f.id "
        "WHERE f.board_id = ? AND f.name = 'Status' ORDER BY o.position ASC";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) != SQLITE_OK) {
        return names;
    }
    sqlite3_bind_text(statement, 1, [boardNodeID UTF8String], -1, SQLITE_TRANSIENT);
    while (sqlite3_step(statement) == SQLITE_ROW) {
        [names addObject:ColumnText(statement, 0)];
    }
    sqlite3_finalize(statement);
    return names;
}

// Item counts per Status value, from the EAV layer (sf_item_values.option_name).
- (NSDictionary<NSString *, NSNumber *> *)statusCountsForBoard:(NSString *)boardNodeID {
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    const char *sql =
        "SELECT v.option_name, COUNT(*) FROM sf_item_values v "
        "JOIN sf_items i ON i.gh_node_id = v.item_id "
        "JOIN sf_fields f ON f.id = v.field_id "
        "WHERE i.board_id = ? AND f.name = 'Status' AND v.option_name IS NOT NULL "
        "GROUP BY v.option_name";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) != SQLITE_OK) {
        return counts;
    }
    sqlite3_bind_text(statement, 1, [boardNodeID UTF8String], -1, SQLITE_TRANSIENT);
    while (sqlite3_step(statement) == SQLITE_ROW) {
        counts[ColumnText(statement, 0)] = @(sqlite3_column_int64(statement, 1));
    }
    sqlite3_finalize(statement);
    return counts;
}

- (NSString *)statusSummaryForBoard:(NSString *)boardNodeID {
    NSArray<NSString *> *options = [self statusOptionNamesForBoard:boardNodeID];
    if ([options count] == 0) {
        return @"—";
    }
    NSDictionary<NSString *, NSNumber *> *counts = [self statusCountsForBoard:boardNodeID];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *option in options) {
        NSNumber *count = counts[option];
        if (count != nil) {
            [parts addObject:[NSString stringWithFormat:@"%@ %@", option, count]];
        }
    }
    if ([parts count] == 0) {
        // No valued items yet: show the vocabulary itself, not an invention.
        return [options componentsJoinedByString:@" · "];
    }
    return [parts componentsJoinedByString:@" · "];
}

- (NSArray<BoardSummary *> *)portfolioBoardsWithError:(NSError **)error {
    if (_db == NULL) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:SnapshotStoreErrorOpenFailed
                                     description:@"No verified snapshot is loaded."];
        }
        return nil;
    }
    // Derived board state (schema v9, sf_board_state — design note
    // 04): present only in snapshots at v9-0042 and later. Older
    // snapshots keep the exact raw-state behavior; the join is
    // presence-guarded, never assumed.
    BOOL hasBoardState = NO;
    sqlite3_stmt *probe = NULL;
    if (sqlite3_prepare_v2(_db,
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='sf_board_state'",
            -1, &probe, NULL) == SQLITE_OK) {
        hasBoardState = (sqlite3_step(probe) == SQLITE_ROW);
    }
    sqlite3_finalize(probe);
    NSString *sqlString = hasBoardState
        ? @"SELECT b.gh_node_id, b.title, b.owner_login, b.owner_type, b.number, "
          @"b.short_description, b.closed, b.archived_hidden, b.url, b.item_count, "
          @"s.derived_state, s.items_total, s.items_terminal, s.terminal_option_name "
          @"FROM sf_boards b LEFT JOIN sf_board_state s ON s.board_id = b.gh_node_id "
          @"ORDER BY b.closed ASC, b.archived_hidden ASC, b.owner_type DESC, b.number ASC"
        : @"SELECT gh_node_id, title, owner_login, owner_type, number, "
          @"short_description, closed, archived_hidden, url, item_count "
          @"FROM sf_boards ORDER BY closed ASC, archived_hidden ASC, owner_type DESC, number ASC";
    const char *sql = [sqlString UTF8String];
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:SnapshotStoreErrorQueryFailed
                                     description:[NSString stringWithFormat:
                                                  @"sf_boards query failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    NSMutableArray<BoardSummary *> *boards = [NSMutableArray array];
    while (sqlite3_step(statement) == SQLITE_ROW) {
        BoardSummary *board = [[BoardSummary alloc] init];
        board.nodeID = ColumnText(statement, 0);
        board.title = ColumnText(statement, 1);
        board.ownerLogin = ColumnText(statement, 2);
        board.ownerType = ColumnText(statement, 3);
        board.number = sqlite3_column_int64(statement, 4);
        const unsigned char *description = sqlite3_column_text(statement, 5);
        board.shortDescription = (description != NULL) ? [NSString stringWithUTF8String:(const char *)description] : nil;
        board.closed = (sqlite3_column_int(statement, 6) != 0);
        board.archivedHidden = (sqlite3_column_int(statement, 7) != 0);
        board.url = ColumnText(statement, 8);
        board.itemCount = sqlite3_column_int64(statement, 9);
        if (hasBoardState && sqlite3_column_type(statement, 10) != SQLITE_NULL) {
            board.hasDerivedState = YES;
            board.derivedState = ColumnText(statement, 10);
            board.derivedItemsTotal = sqlite3_column_int64(statement, 11);
            board.derivedItemsTerminal = sqlite3_column_int64(statement, 12);
            const unsigned char *termName = sqlite3_column_text(statement, 13);
            board.terminalOptionName = (termName != NULL)
                ? [NSString stringWithUTF8String:(const char *)termName] : nil;
        }
        board.statusSummary = [self statusSummaryForBoard:board.nodeID];
        [boards addObject:board];
    }
    sqlite3_finalize(statement);
    return boards;
}

#pragma mark - SF-T3 queries (V1 Board + V3 Detail)

- (NSArray<NSString *> *)statusOptionsForBoard:(NSString *)boardNodeID
                                         error:(NSError **)error {
    if (![self requireOpenDatabase:error]) {
        return nil;
    }
    // Same derivation the Portfolio summary uses, surfaced on its own:
    // the board's Status field options, in sf_field_options.position order.
    return [self statusOptionNamesForBoard:boardNodeID];
}

- (NSArray<BoardItem *> *)itemsForBoard:(NSString *)boardNodeID
                                  error:(NSError **)error {
    if (![self requireOpenDatabase:error]) {
        return nil;
    }
    // One pass: the item rows, each LEFT JOINed to its own board's Status
    // value and Labels value in the EAV layer (fields are per-board, so the
    // field joins key on the item's board, never on a global field id).
    const char *sql =
        "SELECT i.gh_node_id, i.content_kind, i.content_repo, i.content_number, "
        "i.title, i.state, i.url, sv.option_name, lv.json_value "
        "FROM sf_items i "
        "LEFT JOIN sf_fields sf ON sf.board_id = i.board_id AND sf.name = 'Status' "
        "LEFT JOIN sf_item_values sv ON sv.item_id = i.gh_node_id AND sv.field_id = sf.id "
        "LEFT JOIN sf_fields lf ON lf.board_id = i.board_id AND lf.name = 'Labels' "
        "LEFT JOIN sf_item_values lv ON lv.item_id = i.gh_node_id AND lv.field_id = lf.id "
        "WHERE i.board_id = ? ORDER BY i.rowid ASC";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [self queryErrorWithDescription:
                      [NSString stringWithFormat:@"sf_items query failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    sqlite3_bind_text(statement, 1, [boardNodeID UTF8String], -1, SQLITE_TRANSIENT);
    NSMutableArray<BoardItem *> *items = [NSMutableArray array];
    while (sqlite3_step(statement) == SQLITE_ROW) {
        BoardItem *item = [[BoardItem alloc] init];
        item.nodeID = ColumnText(statement, 0);
        item.boardID = boardNodeID;
        item.contentKind = ColumnText(statement, 1);
        item.contentRepo = ColumnNullableText(statement, 2);
        item.contentNumber = (sqlite3_column_type(statement, 3) == SQLITE_NULL)
            ? nil : @(sqlite3_column_int64(statement, 3));
        item.title = ColumnText(statement, 4);
        item.state = ColumnNullableText(statement, 5);
        item.url = ColumnNullableText(statement, 6);
        item.statusName = ColumnNullableText(statement, 7);
        NSString *labelsJSON = ColumnNullableText(statement, 8);
        if (labelsJSON != nil) {
            id parsed = [NSJSONSerialization JSONObjectWithData:[labelsJSON dataUsingEncoding:NSUTF8StringEncoding]
                                                        options:0
                                                          error:NULL];
            if ([parsed isKindOfClass:[NSArray class]]) {
                NSMutableArray<NSString *> *labels = [NSMutableArray array];
                for (id entry in (NSArray *)parsed) {
                    if ([entry isKindOfClass:[NSString class]]) {
                        [labels addObject:entry];
                    }
                }
                item.labels = labels;
            }
        }
        [items addObject:item];
    }
    sqlite3_finalize(statement);
    return items;
}

- (NSArray<ItemFieldValue *> *)fieldValuesForItem:(NSString *)itemNodeID
                                            error:(NSError **)error {
    if (![self requireOpenDatabase:error]) {
        return nil;
    }
    const char *sql =
        "SELECT f.name, f.data_type, v.value_kind, v.text_value, v.number_value, "
        "v.date_value, v.option_name, v.json_value "
        "FROM sf_item_values v "
        "JOIN sf_fields f ON f.id = v.field_id "
        "WHERE v.item_id = ? ORDER BY f.position ASC";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [self queryErrorWithDescription:
                      [NSString stringWithFormat:@"sf_item_values query failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    sqlite3_bind_text(statement, 1, [itemNodeID UTF8String], -1, SQLITE_TRANSIENT);
    NSMutableArray<ItemFieldValue *> *values = [NSMutableArray array];
    while (sqlite3_step(statement) == SQLITE_ROW) {
        ItemFieldValue *value = [[ItemFieldValue alloc] init];
        value.fieldName = ColumnText(statement, 0);
        value.dataType = ColumnNullableText(statement, 1);
        value.valueKind = ColumnText(statement, 2);
        value.textValue = ColumnNullableText(statement, 3);
        value.numberValue = (sqlite3_column_type(statement, 4) == SQLITE_NULL)
            ? nil : @(sqlite3_column_double(statement, 4));
        value.dateValue = ColumnNullableText(statement, 5);
        value.optionName = ColumnNullableText(statement, 6);
        value.jsonValue = ColumnNullableText(statement, 7);
        [values addObject:value];
    }
    sqlite3_finalize(statement);
    return values;
}

- (StatusField *)statusFieldForBoard:(NSString *)boardNodeID
                               error:(NSError **)error {
    if (![self requireOpenDatabase:error]) {
        return nil;
    }
    StatusField *field = [[StatusField alloc] init];
    const char *fieldSQL =
        "SELECT gh_field_id FROM sf_fields WHERE board_id = ? AND name = 'Status'";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, fieldSQL, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [self queryErrorWithDescription:
                      [NSString stringWithFormat:@"sf_fields query failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    sqlite3_bind_text(statement, 1, [boardNodeID UTF8String], -1, SQLITE_TRANSIENT);
    BOOL foundField = (sqlite3_step(statement) == SQLITE_ROW);
    if (foundField) {
        field.ghFieldID = ColumnText(statement, 0);
    }
    sqlite3_finalize(statement);
    if (!foundField) {
        if (error != NULL) {
            *error = [self queryErrorWithDescription:
                      [NSString stringWithFormat:@"Board %@ carries no Status field in the snapshot.", boardNodeID]];
        }
        return nil;
    }

    const char *optionsSQL =
        "SELECT o.gh_option_id, o.name FROM sf_field_options o "
        "JOIN sf_fields f ON f.id = o.field_id "
        "WHERE f.board_id = ? AND f.name = 'Status' ORDER BY o.position ASC";
    if (sqlite3_prepare_v2(_db, optionsSQL, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [self queryErrorWithDescription:
                      [NSString stringWithFormat:@"sf_field_options query failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    sqlite3_bind_text(statement, 1, [boardNodeID UTF8String], -1, SQLITE_TRANSIENT);
    NSMutableArray<StatusOptionRef *> *options = [NSMutableArray array];
    while (sqlite3_step(statement) == SQLITE_ROW) {
        StatusOptionRef *option = [[StatusOptionRef alloc] init];
        option.ghOptionID = ColumnText(statement, 0);
        option.name = ColumnText(statement, 1);
        [options addObject:option];
    }
    sqlite3_finalize(statement);
    field.options = options;
    return field;
}

#pragma mark - SF-T5 queries (V4 Orchestration Center)

- (NSArray<SFAction *> *)actionsWithError:(NSError **)error {
    if (![self requireOpenDatabase:error]) {
        return nil;
    }
    const char *sql =
        "SELECT id, name, kind, target, payload_schema_json, risk_class, "
        "requires_confirm, enabled FROM sf_actions ORDER BY id ASC";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [self queryErrorWithDescription:
                      [NSString stringWithFormat:@"sf_actions query failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    NSMutableArray<SFAction *> *actions = [NSMutableArray array];
    while (sqlite3_step(statement) == SQLITE_ROW) {
        SFAction *action = [[SFAction alloc] init];
        action.actionID = ColumnText(statement, 0);
        action.name = ColumnText(statement, 1);
        action.kind = ColumnText(statement, 2);
        action.target = ColumnText(statement, 3);
        action.payloadSchemaJSON = ColumnText(statement, 4);
        action.riskClass = ColumnText(statement, 5);
        action.requiresConfirm = (sqlite3_column_int(statement, 6) != 0);
        action.enabled = (sqlite3_column_int(statement, 7) != 0);
        [actions addObject:action];
    }
    sqlite3_finalize(statement);
    return actions;
}

- (NSArray<DeployTarget *> *)deployTargetsWithError:(NSError **)error {
    if (![self requireOpenDatabase:error]) {
        return nil;
    }
    const char *sql =
        "SELECT id, platform, account_ref, account_label "
        "FROM sf_deploy_targets ORDER BY platform ASC, id ASC";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [self queryErrorWithDescription:
                      [NSString stringWithFormat:@"sf_deploy_targets query failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    NSMutableArray<DeployTarget *> *targets = [NSMutableArray array];
    while (sqlite3_step(statement) == SQLITE_ROW) {
        DeployTarget *target = [[DeployTarget alloc] init];
        target.targetID = ColumnText(statement, 0);
        target.platform = ColumnText(statement, 1);
        target.accountRef = ColumnText(statement, 2);
        target.accountLabel = ColumnText(statement, 3);
        [targets addObject:target];
    }
    sqlite3_finalize(statement);
    return targets;
}

#pragma mark - SF-T7 queries (V5 Roadmap + V6 Palette + drafts)

// The Roadmap's row set: items joined to their board, with the Status,
// Start date, and Target date values pulled from the item's OWN board's
// fields (fields are per-board rows; the joins key on i.board_id, never
// on a global field). The EXISTS fence is the definition of "dated":
// at least one of the two date fields holds a non-NULL date_value.
- (NSArray<DatedItem *> *)datedItemsWithError:(NSError **)error {
    if (![self requireOpenDatabase:error]) {
        return nil;
    }
    const char *sql =
        "SELECT i.gh_node_id, i.board_id, b.title, b.owner_type, b.number, i.title, "
        "(SELECT sv.option_name FROM sf_item_values sv "
        " JOIN sf_fields sf ON sf.id = sv.field_id "
        " WHERE sv.item_id = i.gh_node_id AND sf.board_id = i.board_id AND sf.name = 'Status'), "
        "(SELECT dv.date_value FROM sf_item_values dv "
        " JOIN sf_fields df ON df.id = dv.field_id "
        " WHERE dv.item_id = i.gh_node_id AND df.board_id = i.board_id AND df.name = 'Start date'), "
        "(SELECT dv.date_value FROM sf_item_values dv "
        " JOIN sf_fields df ON df.id = dv.field_id "
        " WHERE dv.item_id = i.gh_node_id AND df.board_id = i.board_id AND df.name = 'Target date') "
        "FROM sf_items i "
        "JOIN sf_boards b ON b.gh_node_id = i.board_id "
        "WHERE EXISTS (SELECT 1 FROM sf_item_values xv "
        " JOIN sf_fields xf ON xf.id = xv.field_id "
        " WHERE xv.item_id = i.gh_node_id AND xf.name IN ('Start date', 'Target date') "
        " AND xv.date_value IS NOT NULL) "
        "ORDER BY b.owner_type DESC, b.number ASC, i.title ASC";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [self queryErrorWithDescription:
                      [NSString stringWithFormat:@"dated items query failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    NSMutableArray<DatedItem *> *items = [NSMutableArray array];
    while (sqlite3_step(statement) == SQLITE_ROW) {
        DatedItem *item = [[DatedItem alloc] init];
        item.nodeID = ColumnText(statement, 0);
        item.boardID = ColumnText(statement, 1);
        item.boardTitle = ColumnText(statement, 2);
        item.boardOwnerType = ColumnText(statement, 3);
        item.boardNumber = sqlite3_column_int64(statement, 4);
        item.title = ColumnText(statement, 5);
        item.statusName = ColumnNullableText(statement, 6);
        item.startDate = ColumnNullableText(statement, 7);
        item.targetDate = ColumnNullableText(statement, 8);
        [items addObject:item];
    }
    sqlite3_finalize(statement);
    return items;
}

- (NSInteger)boardsWithDateFieldsCountWithError:(NSError **)error {
    if (![self requireOpenDatabase:error]) {
        return -1;
    }
    const char *sql =
        "SELECT COUNT(DISTINCT board_id) FROM sf_fields "
        "WHERE name IN ('Start date', 'Target date')";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [self queryErrorWithDescription:
                      [NSString stringWithFormat:@"date-field boards query failed: %s", sqlite3_errmsg(_db)]];
        }
        return -1;
    }
    NSInteger count = -1;
    if (sqlite3_step(statement) == SQLITE_ROW) {
        count = sqlite3_column_int64(statement, 0);
    }
    sqlite3_finalize(statement);
    return count;
}

- (BoardItem *)itemWithNodeID:(NSString *)itemNodeID
                        error:(NSError **)error {
    if (![self requireOpenDatabase:error]) {
        return nil;
    }
    // itemsForBoard:'s dressing (Status + Labels from the item's own
    // board's fields), narrowed to the one item the palette routed to.
    const char *sql =
        "SELECT i.board_id, i.content_kind, i.content_repo, i.content_number, "
        "i.title, i.state, i.url, sv.option_name, lv.json_value "
        "FROM sf_items i "
        "LEFT JOIN sf_fields sf ON sf.board_id = i.board_id AND sf.name = 'Status' "
        "LEFT JOIN sf_item_values sv ON sv.item_id = i.gh_node_id AND sv.field_id = sf.id "
        "LEFT JOIN sf_fields lf ON lf.board_id = i.board_id AND lf.name = 'Labels' "
        "LEFT JOIN sf_item_values lv ON lv.item_id = i.gh_node_id AND lv.field_id = lf.id "
        "WHERE i.gh_node_id = ?";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [self queryErrorWithDescription:
                      [NSString stringWithFormat:@"sf_items lookup failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    sqlite3_bind_text(statement, 1, [itemNodeID UTF8String], -1, SQLITE_TRANSIENT);
    BoardItem *item = nil;
    if (sqlite3_step(statement) == SQLITE_ROW) {
        item = [[BoardItem alloc] init];
        item.nodeID = itemNodeID;
        item.boardID = ColumnText(statement, 0);
        item.contentKind = ColumnText(statement, 1);
        item.contentRepo = ColumnNullableText(statement, 2);
        item.contentNumber = (sqlite3_column_type(statement, 3) == SQLITE_NULL)
            ? nil : @(sqlite3_column_int64(statement, 3));
        item.title = ColumnText(statement, 4);
        item.state = ColumnNullableText(statement, 5);
        item.url = ColumnNullableText(statement, 6);
        item.statusName = ColumnNullableText(statement, 7);
        NSString *labelsJSON = ColumnNullableText(statement, 8);
        if (labelsJSON != nil) {
            id parsed = [NSJSONSerialization JSONObjectWithData:[labelsJSON dataUsingEncoding:NSUTF8StringEncoding]
                                                        options:0
                                                          error:NULL];
            if ([parsed isKindOfClass:[NSArray class]]) {
                NSMutableArray<NSString *> *labels = [NSMutableArray array];
                for (id entry in (NSArray *)parsed) {
                    if ([entry isKindOfClass:[NSString class]]) {
                        [labels addObject:entry];
                    }
                }
                item.labels = labels;
            }
        }
    }
    sqlite3_finalize(statement);
    if (item == nil && error != NULL) {
        *error = [self queryErrorWithDescription:
                  [NSString stringWithFormat:@"No item %@ in the snapshot.", itemNodeID]];
    }
    return item;
}

// LIKE pattern for a user query: the query's own LIKE metacharacters
// are escaped (paired with ESCAPE '\' in the SQL), then wrapped in %…%.
// An empty query becomes "%%" — matches everything, which is exactly
// the browse behavior for the small scopes.
+ (NSString *)likePatternForQuery:(NSString *)query {
    NSString *escaped = [query stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"%" withString:@"\\%"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"_" withString:@"\\_"];
    return [NSString stringWithFormat:@"%%%@%%", escaped];
}

- (NSArray<PaletteResult *> *)paletteResultsForQuery:(NSString *)query
                                               error:(NSError **)error {
    if (![self requireOpenDatabase:error]) {
        return nil;
    }
    NSString *trimmed = [(query != nil) ? query : @""
                         stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *pattern = [[self class] likePatternForQuery:trimmed];
    const char *patternUTF8 = [pattern UTF8String];
    NSMutableArray<PaletteResult *> *results = [NSMutableArray array];
    sqlite3_stmt *statement = NULL;

    // — Boards (title) —
    const char *boardSQL =
        "SELECT gh_node_id, title, owner_type, number FROM sf_boards "
        "WHERE title LIKE ? ESCAPE '\\' "
        "ORDER BY owner_type DESC, number ASC LIMIT 50";
    if (sqlite3_prepare_v2(_db, boardSQL, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [self queryErrorWithDescription:
                      [NSString stringWithFormat:@"palette boards query failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    sqlite3_bind_text(statement, 1, patternUTF8, -1, SQLITE_TRANSIENT);
    while (sqlite3_step(statement) == SQLITE_ROW) {
        PaletteResult *result = [[PaletteResult alloc] init];
        result.kind = PaletteResultKindBoard;
        result.referenceID = ColumnText(statement, 0);
        result.title = ColumnText(statement, 1);
        result.subtitle = [NSString stringWithFormat:@"%@ #%lld",
                           ColumnText(statement, 2), sqlite3_column_int64(statement, 3)];
        result.boardID = result.referenceID;
        [results addObject:result];
    }
    sqlite3_finalize(statement);
    statement = NULL;

    // — Items (title) — skipped for the empty browse query (see header).
    if ([trimmed length] > 0) {
        const char *itemSQL =
            "SELECT i.gh_node_id, i.title, i.board_id, b.title FROM sf_items i "
            "JOIN sf_boards b ON b.gh_node_id = i.board_id "
            "WHERE i.title LIKE ? ESCAPE '\\' "
            "ORDER BY i.title ASC LIMIT 50";
        if (sqlite3_prepare_v2(_db, itemSQL, -1, &statement, NULL) != SQLITE_OK) {
            if (error != NULL) {
                *error = [self queryErrorWithDescription:
                          [NSString stringWithFormat:@"palette items query failed: %s", sqlite3_errmsg(_db)]];
            }
            return nil;
        }
        sqlite3_bind_text(statement, 1, patternUTF8, -1, SQLITE_TRANSIENT);
        while (sqlite3_step(statement) == SQLITE_ROW) {
            PaletteResult *result = [[PaletteResult alloc] init];
            result.kind = PaletteResultKindItem;
            result.referenceID = ColumnText(statement, 0);
            result.title = ColumnText(statement, 1);
            result.boardID = ColumnText(statement, 2);
            result.subtitle = ColumnText(statement, 3);
            [results addObject:result];
        }
        sqlite3_finalize(statement);
        statement = NULL;
    }

    // — Actions (id / name) —
    const char *actionSQL =
        "SELECT id, name, kind FROM sf_actions "
        "WHERE id LIKE ? ESCAPE '\\' OR name LIKE ? ESCAPE '\\' "
        "ORDER BY id ASC LIMIT 50";
    if (sqlite3_prepare_v2(_db, actionSQL, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [self queryErrorWithDescription:
                      [NSString stringWithFormat:@"palette actions query failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    sqlite3_bind_text(statement, 1, patternUTF8, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(statement, 2, patternUTF8, -1, SQLITE_TRANSIENT);
    while (sqlite3_step(statement) == SQLITE_ROW) {
        PaletteResult *result = [[PaletteResult alloc] init];
        result.kind = PaletteResultKindAction;
        result.referenceID = ColumnText(statement, 0);
        result.title = ColumnText(statement, 0);
        result.subtitle = [NSString stringWithFormat:@"%@ — %@",
                           ColumnText(statement, 2), ColumnText(statement, 1)];
        [results addObject:result];
    }
    sqlite3_finalize(statement);
    statement = NULL;

    // — Deploy targets (id / platform / account) —
    const char *targetSQL =
        "SELECT id, platform, account_label FROM sf_deploy_targets "
        "WHERE id LIKE ? ESCAPE '\\' OR platform LIKE ? ESCAPE '\\' "
        "OR account_label LIKE ? ESCAPE '\\' "
        "ORDER BY platform ASC, id ASC LIMIT 50";
    if (sqlite3_prepare_v2(_db, targetSQL, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [self queryErrorWithDescription:
                      [NSString stringWithFormat:@"palette targets query failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    sqlite3_bind_text(statement, 1, patternUTF8, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(statement, 2, patternUTF8, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(statement, 3, patternUTF8, -1, SQLITE_TRANSIENT);
    while (sqlite3_step(statement) == SQLITE_ROW) {
        PaletteResult *result = [[PaletteResult alloc] init];
        result.kind = PaletteResultKindDeployTarget;
        result.referenceID = ColumnText(statement, 0);
        result.title = ColumnText(statement, 0);
        result.subtitle = [NSString stringWithFormat:@"%@ — %@",
                           ColumnText(statement, 1), ColumnText(statement, 2)];
        [results addObject:result];
    }
    sqlite3_finalize(statement);
    statement = NULL;

    // — Drafts (name / item / board / account — §11.3 ⌘K scope) —
    const char *draftSQL =
        "SELECT composition_id, name, item_title, board_title, deploy_target_id "
        "FROM sf_upcoming_drafts "
        "WHERE name LIKE ? ESCAPE '\\' OR item_title LIKE ? ESCAPE '\\' "
        "OR board_title LIKE ? ESCAPE '\\' OR account_label LIKE ? ESCAPE '\\' "
        "ORDER BY name ASC LIMIT 50";
    if (sqlite3_prepare_v2(_db, draftSQL, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [self queryErrorWithDescription:
                      [NSString stringWithFormat:@"palette drafts query failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    sqlite3_bind_text(statement, 1, patternUTF8, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(statement, 2, patternUTF8, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(statement, 3, patternUTF8, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(statement, 4, patternUTF8, -1, SQLITE_TRANSIENT);
    while (sqlite3_step(statement) == SQLITE_ROW) {
        PaletteResult *result = [[PaletteResult alloc] init];
        result.kind = PaletteResultKindDraft;
        result.referenceID = [NSString stringWithFormat:@"%lld", sqlite3_column_int64(statement, 0)];
        result.title = ColumnText(statement, 1);
        result.subtitle = ColumnText(statement, 2);
        result.boardID = nil;
        result.deployTargetID = ColumnNullableText(statement, 4);
        [results addObject:result];
    }
    sqlite3_finalize(statement);
    return results;
}

- (NSArray<DraftRow *> *)draftRowsWithError:(NSError **)error {
    if (![self requireOpenDatabase:error]) {
        return nil;
    }
    const char *sql =
        "SELECT composition_id, name, version, state, publish_at, "
        "deploy_target_id, platform, account_label, item_id, item_title, "
        "board_id, board_title, element_count, render_asset_id "
        "FROM sf_upcoming_drafts "
        "ORDER BY (publish_at IS NULL) ASC, publish_at ASC, name ASC";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [self queryErrorWithDescription:
                      [NSString stringWithFormat:@"sf_upcoming_drafts query failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    NSMutableArray<DraftRow *> *rows = [NSMutableArray array];
    while (sqlite3_step(statement) == SQLITE_ROW) {
        DraftRow *row = [[DraftRow alloc] init];
        row.compositionID = sqlite3_column_int64(statement, 0);
        row.name = ColumnText(statement, 1);
        row.version = sqlite3_column_int64(statement, 2);
        row.state = ColumnText(statement, 3);
        row.publishAt = ColumnNullableText(statement, 4);
        row.deployTargetID = ColumnNullableText(statement, 5);
        row.platform = ColumnNullableText(statement, 6);
        row.accountLabel = ColumnNullableText(statement, 7);
        row.itemID = ColumnNullableText(statement, 8);
        row.itemTitle = ColumnNullableText(statement, 9);
        row.boardID = ColumnNullableText(statement, 10);
        row.boardTitle = ColumnNullableText(statement, 11);
        row.elementCount = sqlite3_column_int64(statement, 12);
        row.renderAssetID = (sqlite3_column_type(statement, 13) == SQLITE_NULL)
            ? nil : @(sqlite3_column_int64(statement, 13));
        [rows addObject:row];
    }
    sqlite3_finalize(statement);
    return rows;
}

- (NSArray<ElementHandler *> *)elementHandlersWithError:(NSError **)error {
    if (![self requireOpenDatabase:error]) {
        return nil;
    }
    const char *sql =
        "SELECT element_kind, handler_app, handler_bundle_id, invocation_kind "
        "FROM sf_element_handlers ORDER BY id ASC";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [self queryErrorWithDescription:
                      [NSString stringWithFormat:@"sf_element_handlers query failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    NSMutableArray<ElementHandler *> *handlers = [NSMutableArray array];
    while (sqlite3_step(statement) == SQLITE_ROW) {
        ElementHandler *handler = [[ElementHandler alloc] init];
        handler.elementKind = ColumnText(statement, 0);
        handler.handlerApp = ColumnText(statement, 1);
        handler.handlerBundleID = ColumnNullableText(statement, 2);
        handler.invocationKind = ColumnText(statement, 3);
        [handlers addObject:handler];
    }
    sqlite3_finalize(statement);
    return handlers;
}

#pragma mark - SF-T11 incidents (V11; design record §12.5)

// A snapshot predating changes/0031 (e.g. bundled v7-0026) has no
// incident domain. The lens must state that fact, not fail: callers
// check this first and show "no incident domain in snapshot <version>".
- (BOOL)hasIncidentDomainWithError:(NSError **)error {
    if (![self requireOpenDatabase:error]) {
        return NO;
    }
    sqlite3_stmt *statement = NULL;
    const char *sql =
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='sf_incidents'";
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) != SQLITE_OK) {
        return NO;
    }
    BOOL present = NO;
    if (sqlite3_step(statement) == SQLITE_ROW) {
        present = sqlite3_column_int(statement, 0) > 0;
    }
    sqlite3_finalize(statement);
    return present;
}

- (NSArray<IncidentSummary *> *)incidentSummariesWithError:(NSError **)error {
    if (![self requireOpenDatabase:error]) {
        return nil;
    }
    if (![self hasIncidentDomainWithError:error]) {
        return [NSArray array];
    }
    // The applied schema (changes/0031) keys children by the integer
    // sf_incidents.id and vocabulary by *_id → sf_incident_states.id /
    // sf_incident_severities.id / sf_counterparties.id. Names shown are
    // those tables' `name` rows — vocabulary is data, never an enum.
    const char *sql =
        "SELECT i.key, i.title, st.name, sv.name, sv.position, c.name, "
        "       i.source_channel, i.opened_at, st.is_terminal, "
        "       (SELECT COUNT(*) FROM sf_incident_assets a WHERE a.incident_id = i.id), "
        "       (SELECT d.due_at FROM sf_incident_deadlines d WHERE d.incident_id = i.id "
        "          AND d.state = 'open' ORDER BY d.due_at ASC LIMIT 1), "
        "       (SELECT d.label FROM sf_incident_deadlines d WHERE d.incident_id = i.id "
        "          AND d.state = 'open' ORDER BY d.due_at ASC LIMIT 1) "
        "FROM sf_incidents i "
        "JOIN sf_incident_states st ON st.id = i.state_id "
        "JOIN sf_incident_severities sv ON sv.id = i.severity_id "
        "LEFT JOIN sf_counterparties c ON c.id = i.counterparty_id "
        "ORDER BY (SELECT MIN(d2.due_at) FROM sf_incident_deadlines d2 "
        "            WHERE d2.incident_id = i.id AND d2.state = 'open') IS NULL, "
        "         (SELECT MIN(d2.due_at) FROM sf_incident_deadlines d2 "
        "            WHERE d2.incident_id = i.id AND d2.state = 'open') ASC, "
        "         sv.position DESC, i.key ASC";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [self queryErrorWithDescription:
                      [NSString stringWithFormat:@"sf_incidents query failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    NSMutableArray<IncidentSummary *> *summaries = [NSMutableArray array];
    while (sqlite3_step(statement) == SQLITE_ROW) {
        IncidentSummary *summary = [[IncidentSummary alloc] init];
        summary.key = ColumnText(statement, 0);
        summary.title = ColumnText(statement, 1);
        summary.stateName = ColumnText(statement, 2);
        summary.severityName = ColumnText(statement, 3);
        summary.severityPosition = sqlite3_column_int(statement, 4);
        summary.counterpartyName = ColumnNullableText(statement, 5);
        summary.sourceChannel = ColumnText(statement, 6);
        summary.openedAt = ColumnText(statement, 7);
        summary.stateIsTerminal = sqlite3_column_int(statement, 8) != 0;
        summary.assetCount = sqlite3_column_int(statement, 9);
        summary.nextDeadlineDue = ColumnNullableText(statement, 10);
        summary.nextDeadlineLabel = ColumnNullableText(statement, 11);
        [summaries addObject:summary];
    }
    sqlite3_finalize(statement);
    return summaries;
}

- (IncidentDetail *)incidentDetailForKey:(NSString *)key error:(NSError **)error {
    if (![self requireOpenDatabase:error]) {
        return nil;
    }
    if (![self hasIncidentDomainWithError:error]) {
        return nil;
    }
    IncidentSummary *found = nil;
    NSString *summaryText = nil;
    NSString *sourceRef = nil;
    const char *sql =
        "SELECT i.id, i.key, i.title, st.name, sv.name, sv.position, c.name, "
        "       i.source_channel, i.opened_at, st.is_terminal, i.summary, i.source_ref, "
        "       (SELECT COUNT(*) FROM sf_incident_assets a WHERE a.incident_id = i.id), "
        "       (SELECT d.due_at FROM sf_incident_deadlines d WHERE d.incident_id = i.id "
        "          AND d.state = 'open' ORDER BY d.due_at ASC LIMIT 1), "
        "       (SELECT d.label FROM sf_incident_deadlines d WHERE d.incident_id = i.id "
        "          AND d.state = 'open' ORDER BY d.due_at ASC LIMIT 1) "
        "FROM sf_incidents i "
        "JOIN sf_incident_states st ON st.id = i.state_id "
        "JOIN sf_incident_severities sv ON sv.id = i.severity_id "
        "LEFT JOIN sf_counterparties c ON c.id = i.counterparty_id "
        "WHERE i.key = ?";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [self queryErrorWithDescription:
                      [NSString stringWithFormat:@"sf_incidents detail query failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    sqlite3_bind_text(statement, 1, [key UTF8String], -1, SQLITE_TRANSIENT);
    int64_t incidentID = 0;
    if (sqlite3_step(statement) == SQLITE_ROW) {
        incidentID = sqlite3_column_int64(statement, 0);
        found = [[IncidentSummary alloc] init];
        found.key = ColumnText(statement, 1);
        found.title = ColumnText(statement, 2);
        found.stateName = ColumnText(statement, 3);
        found.severityName = ColumnText(statement, 4);
        found.severityPosition = sqlite3_column_int(statement, 5);
        found.counterpartyName = ColumnNullableText(statement, 6);
        found.sourceChannel = ColumnText(statement, 7);
        found.openedAt = ColumnText(statement, 8);
        found.stateIsTerminal = sqlite3_column_int(statement, 9) != 0;
        summaryText = ColumnNullableText(statement, 10);
        sourceRef = ColumnNullableText(statement, 11);
        found.assetCount = sqlite3_column_int(statement, 12);
        found.nextDeadlineDue = ColumnNullableText(statement, 13);
        found.nextDeadlineLabel = ColumnNullableText(statement, 14);
    }
    sqlite3_finalize(statement);
    if (found == nil) {
        return nil;
    }

    IncidentDetail *detail = [[IncidentDetail alloc] init];
    detail.summary = found;
    detail.summaryText = summaryText;
    detail.sourceRef = sourceRef;

    NSMutableArray<IncidentDeadline *> *deadlines = [NSMutableArray array];
    const char *deadlineSQL =
        "SELECT kind, due_at, label, state FROM sf_incident_deadlines "
        "WHERE incident_id = ? ORDER BY due_at ASC, id ASC";
    statement = NULL;
    if (sqlite3_prepare_v2(_db, deadlineSQL, -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, incidentID);
        while (sqlite3_step(statement) == SQLITE_ROW) {
            IncidentDeadline *deadline = [[IncidentDeadline alloc] init];
            deadline.kind = ColumnText(statement, 0);
            deadline.dueAt = ColumnText(statement, 1);
            deadline.label = ColumnText(statement, 2);
            deadline.state = ColumnText(statement, 3);
            [deadlines addObject:deadline];
        }
    }
    sqlite3_finalize(statement);
    detail.deadlines = deadlines;

    NSMutableArray<IncidentAsset *> *assets = [NSMutableArray array];
    const char *assetSQL =
        "SELECT asset_type, label, account_ref, message_id, thread_id, local_path, "
        "       external_ref, sha256, size_bytes, created_by, created_at "
        "FROM sf_incident_assets WHERE incident_id = ? ORDER BY id ASC";
    statement = NULL;
    if (sqlite3_prepare_v2(_db, assetSQL, -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, incidentID);
        while (sqlite3_step(statement) == SQLITE_ROW) {
            IncidentAsset *asset = [[IncidentAsset alloc] init];
            asset.assetType = ColumnText(statement, 0);
            asset.label = ColumnText(statement, 1);
            asset.accountRef = ColumnNullableText(statement, 2);
            asset.messageID = ColumnNullableText(statement, 3);
            asset.threadID = ColumnNullableText(statement, 4);
            asset.localPath = ColumnNullableText(statement, 5);
            asset.externalRef = ColumnNullableText(statement, 6);
            asset.sha256 = ColumnNullableText(statement, 7);
            if (sqlite3_column_type(statement, 8) != SQLITE_NULL) {
                asset.sizeBytes = [NSNumber numberWithLongLong:sqlite3_column_int64(statement, 8)];
            }
            asset.createdBy = ColumnText(statement, 9);
            asset.createdAt = ColumnText(statement, 10);
            [assets addObject:asset];
        }
    }
    sqlite3_finalize(statement);
    detail.assets = assets;

    // §12.5 timeline: this incident's sf_audit_log entries, oldest first.
    NSMutableArray<NSString *> *timeline = [NSMutableArray array];
    const char *auditSQL =
        "SELECT ts, actor, action FROM sf_audit_log "
        "WHERE object_ref = ? ORDER BY id ASC";
    statement = NULL;
    if (sqlite3_prepare_v2(_db, auditSQL, -1, &statement, NULL) == SQLITE_OK) {
        NSString *objectRef = [NSString stringWithFormat:@"incident:%@", key];
        sqlite3_bind_text(statement, 1, [objectRef UTF8String], -1, SQLITE_TRANSIENT);
        while (sqlite3_step(statement) == SQLITE_ROW) {
            [timeline addObject:[NSString stringWithFormat:@"%@ — %@ — %@",
                                  ColumnText(statement, 0),
                                  ColumnText(statement, 1),
                                  ColumnText(statement, 2)]];
        }
    }
    sqlite3_finalize(statement);
    detail.timelineEntries = timeline;
    return detail;
}

@end
