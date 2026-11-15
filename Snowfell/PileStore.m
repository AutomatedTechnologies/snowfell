#import "PileStore.h"
#import "WriteBackQueue.h"
#import "SnapshotStore.h"
#import "BoardSummary.h"
#import "BoardItem.h"
#import <sqlite3.h>

NSString * const PileStoreErrorDomain = @"com.detroitautomationacademy.snowfell.PileStore";

NSString * const PileKindSystemInbox = @"system_inbox";
NSString * const PileKindSystemDone = @"system_done";
NSString * const PileKindBoard = @"board";
NSString * const PileKindCustom = @"custom";

@implementation Pile
@end

@implementation PileItem
@end

@interface PileStore () {
    sqlite3 *_db;
}
@property (nonatomic, copy, readwrite) NSString *storePath;
@property (nonatomic, strong, readwrite, nullable) SnapshotStore *snapshotStore;
@end

@implementation PileStore

+ (NSError *)errorWithCode:(PileStoreError)code description:(NSString *)description {
    return [NSError errorWithDomain:PileStoreErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

+ (NSString *)defaultStorePath {
    return [WriteBackQueue defaultStorePath];
}

+ (NSString *)iso8601Now {
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    [formatter setFormatOptions:NSISO8601DateFormatWithInternetDateTime];
    [formatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
    return [formatter stringFromDate:[NSDate date]];
}

- (instancetype)initWithStorePath:(NSString *)storePath
                  snapshotStore:(SnapshotStore *)snapshotStore
                          error:(NSError **)error {
    self = [super init];
    if (self) {
        _storePath = [storePath copy];
        _snapshotStore = snapshotStore;
        NSString *directory = [storePath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        sqlite3 *db = NULL;
        int rc = sqlite3_open_v2([storePath fileSystemRepresentation], &db,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
        if (rc != SQLITE_OK) {
            NSString *message = (db != NULL) ? [NSString stringWithUTF8String:sqlite3_errmsg(db)]
                                             : @"sqlite3_open_v2 failed";
            if (db != NULL) {
                sqlite3_close(db);
            }
            if (error != NULL) {
                *error = [[self class] errorWithCode:PileStoreErrorOpenFailed
                                         description:[NSString stringWithFormat:
                                                      @"Pile store could not be opened at %@: %@", storePath, message]];
            }
            return nil;
        }
        _db = db;
        if (![self ensureSchema:error]) {
            sqlite3_close(_db);
            _db = NULL;
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    [self close];
}

- (void)close {
    if (_db != NULL) {
        sqlite3_close(_db);
        _db = NULL;
    }
}

- (BOOL)ensureSchema:(NSError **)error {
    // Design record 13 section 2, verbatim shapes. local_audit_log is
    // the SHARED table — the same CREATE IF NOT EXISTS the other local
    // stores issue, so whichever store opens first creates it.
    const char *sql =
        "CREATE TABLE IF NOT EXISTS sf_piles ("
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  name TEXT NOT NULL,"
        "  kind TEXT NOT NULL CHECK (kind IN ('system_inbox','system_done','board','custom')),"
        "  board_node_id TEXT,"
        "  created_at TEXT NOT NULL"
        ");"
        "CREATE TABLE IF NOT EXISTS sf_pile_items ("
        "  pile_id INTEGER NOT NULL REFERENCES sf_piles(id),"
        "  item_node_id TEXT UNIQUE NOT NULL,"
        "  position INTEGER NOT NULL,"
        "  title TEXT NOT NULL,"
        "  board_title TEXT NOT NULL,"
        "  added_at TEXT NOT NULL"
        ");"
        "CREATE TABLE IF NOT EXISTS local_audit_log ("
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  ts TEXT NOT NULL,"
        "  actor TEXT NOT NULL,"
        "  action TEXT NOT NULL,"
        "  object_ref TEXT,"
        "  before_json TEXT,"
        "  after_json TEXT"
        ");";
    char *message = NULL;
    if (sqlite3_exec(_db, sql, NULL, NULL, &message) != SQLITE_OK) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:PileStoreErrorSchemaFailed
                                     description:[NSString stringWithFormat:
                                                  @"Pile schema failed: %s",
                                                  (message != NULL) ? message : sqlite3_errmsg(_db)]];
        }
        if (message != NULL) {
            sqlite3_free(message);
        }
        return NO;
    }
    return YES;
}

#pragma mark - Helpers

static NSString *PSColumnText(sqlite3_stmt *statement, int column) {
    const unsigned char *text = sqlite3_column_text(statement, column);
    return (text != NULL) ? [NSString stringWithUTF8String:(const char *)text] : @"";
}

static NSString *PSColumnNullableText(sqlite3_stmt *statement, int column) {
    if (sqlite3_column_type(statement, column) == SQLITE_NULL) {
        return nil;
    }
    const unsigned char *text = sqlite3_column_text(statement, column);
    return (text != NULL) ? [NSString stringWithUTF8String:(const char *)text] : nil;
}

- (BOOL)executeUpdate:(const char *)sql
            bindBlock:(void (^)(sqlite3_stmt *statement))bindBlock
                error:(NSError **)error {
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:PileStoreErrorMutationFailed
                                     description:[NSString stringWithFormat:
                                                  @"Statement failed: %s", sqlite3_errmsg(_db)]];
        }
        return NO;
    }
    if (bindBlock != nil) {
        bindBlock(statement);
    }
    BOOL ok = (sqlite3_step(statement) == SQLITE_DONE);
    if (!ok && error != NULL) {
        *error = [[self class] errorWithCode:PileStoreErrorMutationFailed
                                 description:[NSString stringWithFormat:
                                              @"Update failed: %s", sqlite3_errmsg(_db)]];
    }
    sqlite3_finalize(statement);
    return ok;
}

- (nullable NSString *)jsonStringForObject:(id)object {
    if (object == nil) {
        return nil;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    if (data == nil) {
        return nil;
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (BOOL)recordAuditAction:(NSString *)action
               objectRef:(NSString *)objectRef
                  before:(NSDictionary *)before
                   after:(NSDictionary *)after
                   error:(NSError **)error {
    NSString *beforeJSON = [self jsonStringForObject:before];
    NSString *afterJSON = [self jsonStringForObject:after];
    NSString *timestamp = [[self class] iso8601Now];
    return [self executeUpdate:"INSERT INTO local_audit_log (ts, actor, action, object_ref, before_json, after_json) VALUES (?, 'Snowfell (local user)', ?, ?, ?, ?)"
                     bindBlock:^(sqlite3_stmt *statement) {
                         sqlite3_bind_text(statement, 1, [timestamp UTF8String], -1, SQLITE_TRANSIENT);
                         sqlite3_bind_text(statement, 2, [action UTF8String], -1, SQLITE_TRANSIENT);
                         if (objectRef != nil) {
                             sqlite3_bind_text(statement, 3, [objectRef UTF8String], -1, SQLITE_TRANSIENT);
                         } else {
                             sqlite3_bind_null(statement, 3);
                         }
                         if (beforeJSON != nil) {
                             sqlite3_bind_text(statement, 4, [beforeJSON UTF8String], -1, SQLITE_TRANSIENT);
                         } else {
                             sqlite3_bind_null(statement, 4);
                         }
                         if (afterJSON != nil) {
                             sqlite3_bind_text(statement, 5, [afterJSON UTF8String], -1, SQLITE_TRANSIENT);
                         } else {
                             sqlite3_bind_null(statement, 5);
                         }
                     }
                         error:error];
}

- (NSInteger)countForSQL:(const char *)sql {
    sqlite3_stmt *statement = NULL;
    NSInteger count = 0;
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) == SQLITE_OK) {
        if (sqlite3_step(statement) == SQLITE_ROW) {
            count = sqlite3_column_int64(statement, 0);
        }
    }
    sqlite3_finalize(statement);
    return count;
}

- (NSInteger)maxPositionForPile:(int64_t)pileID {
    sqlite3_stmt *statement = NULL;
    NSInteger result = -1;
    if (sqlite3_prepare_v2(_db, "SELECT MAX(position) FROM sf_pile_items WHERE pile_id = ?",
                           -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, pileID);
        if (sqlite3_step(statement) == SQLITE_ROW &&
            sqlite3_column_type(statement, 0) != SQLITE_NULL) {
            result = sqlite3_column_int64(statement, 0);
        }
    }
    sqlite3_finalize(statement);
    return result;
}

// Rewrites one pile's positions as 0..n-1 in the given item order.
- (BOOL)rewritePositionsForPile:(int64_t)pileID
                     itemOrder:(NSArray<NSString *> *)itemOrder
                         error:(NSError **)error {
    for (NSUInteger i = 0; i < [itemOrder count]; i++) {
        NSString *itemID = itemOrder[i];
        NSInteger position = (NSInteger)i;
        BOOL ok = [self executeUpdate:"UPDATE sf_pile_items SET position = ? WHERE pile_id = ? AND item_node_id = ?"
                            bindBlock:^(sqlite3_stmt *statement) {
                                sqlite3_bind_int64(statement, 1, position);
                                sqlite3_bind_int64(statement, 2, pileID);
                                sqlite3_bind_text(statement, 3, [itemID UTF8String], -1, SQLITE_TRANSIENT);
                            }
                                error:error];
        if (!ok) {
            return NO;
        }
    }
    return YES;
}

#pragma mark - Pile queries

- (nullable Pile *)pileFromStatement:(sqlite3_stmt *)statement {
    Pile *pile = [[Pile alloc] init];
    pile.pileID = sqlite3_column_int64(statement, 0);
    pile.name = PSColumnText(statement, 1);
    pile.kind = PSColumnText(statement, 2);
    pile.boardNodeID = PSColumnNullableText(statement, 3);
    pile.createdAt = PSColumnText(statement, 4);
    return pile;
}

- (void)fillCountsForPile:(Pile *)pile {
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db,
            "SELECT COUNT(*), (SELECT title FROM sf_pile_items WHERE pile_id = ? ORDER BY position ASC LIMIT 1) "
            "FROM sf_pile_items WHERE pile_id = ?",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, pile.pileID);
        sqlite3_bind_int64(statement, 2, pile.pileID);
        if (sqlite3_step(statement) == SQLITE_ROW) {
            pile.itemCount = sqlite3_column_int64(statement, 0);
            pile.topItemTitle = PSColumnNullableText(statement, 1);
        }
    }
    sqlite3_finalize(statement);
}

- (NSArray<Pile *> *)pilesWithError:(NSError **)error {
    // Display order: Inbox first, Done last; board piles in the order
    // they were materialized (snapshot board order), custom piles by
    // creation, between the board piles and Done.
    const char *sql =
        "SELECT id, name, kind, board_node_id, created_at FROM sf_piles "
        "ORDER BY CASE kind WHEN 'system_inbox' THEN 0 WHEN 'board' THEN 1 "
        "WHEN 'custom' THEN 2 ELSE 3 END, id ASC";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:PileStoreErrorQueryFailed
                                     description:[NSString stringWithFormat:
                                                  @"Pile query failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    NSMutableArray<Pile *> *piles = [NSMutableArray array];
    while (sqlite3_step(statement) == SQLITE_ROW) {
        [piles addObject:[self pileFromStatement:statement]];
    }
    sqlite3_finalize(statement);
    for (Pile *pile in piles) {
        [self fillCountsForPile:pile];
    }
    return piles;
}

- (Pile *)pileWithID:(int64_t)pileID error:(NSError **)error {
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db,
            "SELECT id, name, kind, board_node_id, created_at FROM sf_piles WHERE id = ?",
            -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:PileStoreErrorQueryFailed
                                     description:[NSString stringWithFormat:
                                                  @"Pile query failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    sqlite3_bind_int64(statement, 1, pileID);
    Pile *pile = nil;
    if (sqlite3_step(statement) == SQLITE_ROW) {
        pile = [self pileFromStatement:statement];
    }
    sqlite3_finalize(statement);
    if (pile != nil) {
        [self fillCountsForPile:pile];
    }
    return pile;
}

- (Pile *)systemPileWithKind:(NSString *)kind error:(NSError **)error {
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db,
            "SELECT id, name, kind, board_node_id, created_at FROM sf_piles WHERE kind = ?",
            -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:PileStoreErrorQueryFailed
                                     description:[NSString stringWithFormat:
                                                  @"Pile query failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    sqlite3_bind_text(statement, 1, [kind UTF8String], -1, SQLITE_TRANSIENT);
    Pile *pile = nil;
    if (sqlite3_step(statement) == SQLITE_ROW) {
        pile = [self pileFromStatement:statement];
    }
    sqlite3_finalize(statement);
    if (pile != nil) {
        [self fillCountsForPile:pile];
    }
    return pile;
}

- (Pile *)inboxPileWithError:(NSError **)error {
    return [self systemPileWithKind:PileKindSystemInbox error:error];
}

- (Pile *)donePileWithError:(NSError **)error {
    return [self systemPileWithKind:PileKindSystemDone error:error];
}

- (NSArray<PileItem *> *)itemsForPile:(int64_t)pileID error:(NSError **)error {
    const char *sql =
        "SELECT pile_id, item_node_id, position, title, board_title, added_at "
        "FROM sf_pile_items WHERE pile_id = ? ORDER BY position ASC";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:PileStoreErrorQueryFailed
                                     description:[NSString stringWithFormat:
                                                  @"Pile items query failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    sqlite3_bind_int64(statement, 1, pileID);
    NSMutableArray<PileItem *> *items = [NSMutableArray array];
    while (sqlite3_step(statement) == SQLITE_ROW) {
        PileItem *item = [[PileItem alloc] init];
        item.pileID = sqlite3_column_int64(statement, 0);
        item.itemNodeID = PSColumnText(statement, 1);
        item.position = sqlite3_column_int64(statement, 2);
        item.title = PSColumnText(statement, 3);
        item.boardTitle = PSColumnText(statement, 4);
        item.addedAt = PSColumnText(statement, 5);
        [items addObject:item];
    }
    sqlite3_finalize(statement);
    return items;
}

- (nullable PileItem *)pileItemForItemNodeID:(NSString *)itemNodeID {
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db,
            "SELECT pile_id, item_node_id, position, title, board_title, added_at "
            "FROM sf_pile_items WHERE item_node_id = ?",
            -1, &statement, NULL) != SQLITE_OK) {
        return nil;
    }
    sqlite3_bind_text(statement, 1, [itemNodeID UTF8String], -1, SQLITE_TRANSIENT);
    PileItem *item = nil;
    if (sqlite3_step(statement) == SQLITE_ROW) {
        item = [[PileItem alloc] init];
        item.pileID = sqlite3_column_int64(statement, 0);
        item.itemNodeID = PSColumnText(statement, 1);
        item.position = sqlite3_column_int64(statement, 2);
        item.title = PSColumnText(statement, 3);
        item.boardTitle = PSColumnText(statement, 4);
        item.addedAt = PSColumnText(statement, 5);
    }
    sqlite3_finalize(statement);
    return item;
}

#pragma mark - Materialization + reconcile (design record 13 section 3)

- (int64_t)ensurePileWithName:(NSString *)name
                         kind:(NSString *)kind
                boardNodeID:(NSString *)boardNodeID
                      error:(NSError **)error {
    // Existing pile for this kind/board (system kinds are singletons;
    // board piles key on board_node_id; custom piles never come here).
    sqlite3_stmt *statement = NULL;
    const char *probeSQL = [kind isEqualToString:PileKindBoard]
        ? "SELECT id FROM sf_piles WHERE kind = ? AND board_node_id = ?"
        : "SELECT id FROM sf_piles WHERE kind = ?";
    if (sqlite3_prepare_v2(_db, probeSQL, -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_text(statement, 1, [kind UTF8String], -1, SQLITE_TRANSIENT);
        if ([kind isEqualToString:PileKindBoard]) {
            sqlite3_bind_text(statement, 2, [boardNodeID UTF8String], -1, SQLITE_TRANSIENT);
        }
        if (sqlite3_step(statement) == SQLITE_ROW) {
            int64_t existing = sqlite3_column_int64(statement, 0);
            sqlite3_finalize(statement);
            return existing;
        }
    }
    sqlite3_finalize(statement);
    NSString *now = [[self class] iso8601Now];
    BOOL ok = [self executeUpdate:"INSERT INTO sf_piles (name, kind, board_node_id, created_at) VALUES (?, ?, ?, ?)"
                        bindBlock:^(sqlite3_stmt *stmt) {
                            sqlite3_bind_text(stmt, 1, [name UTF8String], -1, SQLITE_TRANSIENT);
                            sqlite3_bind_text(stmt, 2, [kind UTF8String], -1, SQLITE_TRANSIENT);
                            if (boardNodeID != nil) {
                                sqlite3_bind_text(stmt, 3, [boardNodeID UTF8String], -1, SQLITE_TRANSIENT);
                            } else {
                                sqlite3_bind_null(stmt, 3);
                            }
                            sqlite3_bind_text(stmt, 4, [now UTF8String], -1, SQLITE_TRANSIENT);
                        }
                            error:error];
    return ok ? sqlite3_last_insert_rowid(_db) : -1;
}

- (NSInteger)materializeAndReconcileWithError:(NSError **)error {
    if (self.snapshotStore == nil || self.snapshotStore.snapshotPath == nil) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:PileStoreErrorQueryFailed
                                     description:@"No verified snapshot is loaded; piles cannot materialize."];
        }
        return -1;
    }
    BOOL initial = ([self countForSQL:"SELECT COUNT(*) FROM sf_pile_items"] == 0);
    int64_t inboxID = [self ensurePileWithName:@"Inbox" kind:PileKindSystemInbox boardNodeID:nil error:error];
    int64_t doneID = [self ensurePileWithName:@"Done" kind:PileKindSystemDone boardNodeID:nil error:error];
    if (inboxID < 0 || doneID < 0) {
        return -1;
    }
    NSError *queryError = nil;
    NSArray<BoardSummary *> *boards = [self.snapshotStore portfolioBoardsWithError:&queryError];
    if (boards == nil) {
        if (error != NULL) {
            *error = queryError;
        }
        return -1;
    }
    // One pile per board, named for the board.
    NSMutableDictionary<NSString *, NSNumber *> *pileIDByBoard = [NSMutableDictionary dictionary];
    for (BoardSummary *board in boards) {
        int64_t pileID = [self ensurePileWithName:board.title kind:PileKindBoard boardNodeID:board.nodeID error:error];
        if (pileID < 0) {
            return -1;
        }
        pileIDByBoard[board.nodeID] = @(pileID);
    }
    // Items already placed (the reconcile fence: adds only).
    NSMutableSet<NSString *> *placed = [NSMutableSet set];
    {
        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(_db, "SELECT item_node_id FROM sf_pile_items", -1, &statement, NULL) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                [placed addObject:PSColumnText(statement, 0)];
            }
        }
        sqlite3_finalize(statement);
    }
    NSString *now = [[self class] iso8601Now];
    NSInteger added = 0;
    sqlite3_exec(_db, "BEGIN IMMEDIATE", NULL, NULL, NULL);
    if (initial) {
        // First materialization: per destination pile, order is the
        // board's Status-vocabulary position first (earliest stage on
        // top), then snapshot import order. Statusless items go to
        // the Inbox in import order.
        for (BoardSummary *board in boards) {
            NSArray<NSString *> *options = [self.snapshotStore statusOptionsForBoard:board.nodeID error:NULL];
            NSMutableDictionary<NSString *, NSNumber *> *rank = [NSMutableDictionary dictionary];
            for (NSUInteger i = 0; i < [options count]; i++) {
                rank[options[i]] = @(i);
            }
            NSArray<BoardItem *> *items = [self.snapshotStore itemsForBoard:board.nodeID error:NULL];
            NSMutableArray<BoardItem *> *boardItems = [NSMutableArray array];
            NSMutableArray<BoardItem *> *inboxItems = [NSMutableArray array];
            for (BoardItem *item in items) {
                if ([placed containsObject:item.nodeID]) {
                    continue;
                }
                if (item.statusName == nil) {
                    [inboxItems addObject:item];
                } else {
                    [boardItems addObject:item];
                }
            }
            [boardItems sortUsingComparator:^NSComparisonResult(BoardItem *a, BoardItem *b) {
                NSInteger ra = (rank[a.statusName] != nil) ? [rank[a.statusName] integerValue] : (NSInteger)[options count];
                NSInteger rb = (rank[b.statusName] != nil) ? [rank[b.statusName] integerValue] : (NSInteger)[options count];
                if (ra != rb) {
                    return (ra < rb) ? NSOrderedAscending : NSOrderedDescending;
                }
                return NSOrderedSame;  // stable: import order survives within a rank
            }];
            int64_t boardPileID = [pileIDByBoard[board.nodeID] longLongValue];
            NSInteger position = [self maxPositionForPile:boardPileID] + 1;
            for (BoardItem *item in boardItems) {
                BOOL ok = [self executeUpdate:"INSERT INTO sf_pile_items (pile_id, item_node_id, position, title, board_title, added_at) VALUES (?, ?, ?, ?, ?, ?)"
                                    bindBlock:^(sqlite3_stmt *stmt) {
                                        sqlite3_bind_int64(stmt, 1, boardPileID);
                                        sqlite3_bind_text(stmt, 2, [item.nodeID UTF8String], -1, SQLITE_TRANSIENT);
                                        sqlite3_bind_int64(stmt, 3, position);
                                        sqlite3_bind_text(stmt, 4, [item.title UTF8String], -1, SQLITE_TRANSIENT);
                                        sqlite3_bind_text(stmt, 5, [board.title UTF8String], -1, SQLITE_TRANSIENT);
                                        sqlite3_bind_text(stmt, 6, [now UTF8String], -1, SQLITE_TRANSIENT);
                                    }
                                        error:error];
                if (!ok) {
                    sqlite3_exec(_db, "ROLLBACK", NULL, NULL, NULL);
                    return -1;
                }
                position++;
                added++;
                [placed addObject:item.nodeID];
            }
            for (BoardItem *item in inboxItems) {
                NSInteger inboxPosition = [self maxPositionForPile:inboxID] + 1;
                BOOL ok = [self executeUpdate:"INSERT INTO sf_pile_items (pile_id, item_node_id, position, title, board_title, added_at) VALUES (?, ?, ?, ?, ?, ?)"
                                    bindBlock:^(sqlite3_stmt *stmt) {
                                        sqlite3_bind_int64(stmt, 1, inboxID);
                                        sqlite3_bind_text(stmt, 2, [item.nodeID UTF8String], -1, SQLITE_TRANSIENT);
                                        sqlite3_bind_int64(stmt, 3, inboxPosition);
                                        sqlite3_bind_text(stmt, 4, [item.title UTF8String], -1, SQLITE_TRANSIENT);
                                        sqlite3_bind_text(stmt, 5, [board.title UTF8String], -1, SQLITE_TRANSIENT);
                                        sqlite3_bind_text(stmt, 6, [now UTF8String], -1, SQLITE_TRANSIENT);
                                    }
                                        error:error];
                if (!ok) {
                    sqlite3_exec(_db, "ROLLBACK", NULL, NULL, NULL);
                    return -1;
                }
                added++;
                [placed addObject:item.nodeID];
            }
        }
    } else {
        // Reconcile: adds only — statusless -> Inbox TOP, else its
        // board pile's BOTTOM. Never removes, never reorders.
        for (BoardSummary *board in boards) {
            NSArray<BoardItem *> *items = [self.snapshotStore itemsForBoard:board.nodeID error:NULL];
            int64_t boardPileID = [pileIDByBoard[board.nodeID] longLongValue];
            for (BoardItem *item in items) {
                if ([placed containsObject:item.nodeID]) {
                    continue;
                }
                if (item.statusName == nil) {
                    // Inbox top: shift the Inbox down one, insert at 0.
                    BOOL shifted = [self executeUpdate:"UPDATE sf_pile_items SET position = position + 1 WHERE pile_id = ?"
                                             bindBlock:^(sqlite3_stmt *stmt) {
                                                 sqlite3_bind_int64(stmt, 1, inboxID);
                                             }
                                                 error:error];
                    if (!shifted) {
                        sqlite3_exec(_db, "ROLLBACK", NULL, NULL, NULL);
                        return -1;
                    }
                    BOOL ok = [self executeUpdate:"INSERT INTO sf_pile_items (pile_id, item_node_id, position, title, board_title, added_at) VALUES (?, ?, 0, ?, ?, ?)"
                                        bindBlock:^(sqlite3_stmt *stmt) {
                                            sqlite3_bind_int64(stmt, 1, inboxID);
                                            sqlite3_bind_text(stmt, 2, [item.nodeID UTF8String], -1, SQLITE_TRANSIENT);
                                            sqlite3_bind_text(stmt, 3, [item.title UTF8String], -1, SQLITE_TRANSIENT);
                                            sqlite3_bind_text(stmt, 4, [board.title UTF8String], -1, SQLITE_TRANSIENT);
                                            sqlite3_bind_text(stmt, 5, [now UTF8String], -1, SQLITE_TRANSIENT);
                                        }
                                            error:error];
                    if (!ok) {
                        sqlite3_exec(_db, "ROLLBACK", NULL, NULL, NULL);
                        return -1;
                    }
                } else {
                    NSInteger position = [self maxPositionForPile:boardPileID] + 1;
                    BOOL ok = [self executeUpdate:"INSERT INTO sf_pile_items (pile_id, item_node_id, position, title, board_title, added_at) VALUES (?, ?, ?, ?, ?, ?)"
                                        bindBlock:^(sqlite3_stmt *stmt) {
                                            sqlite3_bind_int64(stmt, 1, boardPileID);
                                            sqlite3_bind_text(stmt, 2, [item.nodeID UTF8String], -1, SQLITE_TRANSIENT);
                                            sqlite3_bind_int64(stmt, 3, position);
                                            sqlite3_bind_text(stmt, 4, [item.title UTF8String], -1, SQLITE_TRANSIENT);
                                            sqlite3_bind_text(stmt, 5, [board.title UTF8String], -1, SQLITE_TRANSIENT);
                                            sqlite3_bind_text(stmt, 6, [now UTF8String], -1, SQLITE_TRANSIENT);
                                        }
                                            error:error];
                    if (!ok) {
                        sqlite3_exec(_db, "ROLLBACK", NULL, NULL, NULL);
                        return -1;
                    }
                }
                added++;
                [placed addObject:item.nodeID];
            }
        }
    }
    sqlite3_exec(_db, "COMMIT", NULL, NULL, NULL);
    if (added > 0 || initial) {
        [self recordAuditAction:(initial ? @"pile.materialize" : @"pile.reconcile")
                     objectRef:@"sf_piles"
                        before:nil
                         after:@{@"added": @(added)}
                         error:NULL];
    }
    return added;
}

#pragma mark - Mutations

- (BOOL)moveItem:(NSString *)itemNodeID toPile:(int64_t)pileID error:(NSError **)error {
    PileItem *before = [self pileItemForItemNodeID:itemNodeID];
    Pile *destination = [self pileWithID:pileID error:error];
    if (before == nil || destination == nil) {
        if (error != NULL && before == nil) {
            *error = [[self class] errorWithCode:PileStoreErrorNotFound
                                     description:[NSString stringWithFormat:@"No piled item %@.", itemNodeID]];
        }
        return NO;
    }
    if (before.pileID == pileID) {
        return YES;  // already there: a move to its own pile changes nothing
    }
    int64_t sourcePileID = before.pileID;
    NSInteger position = [self maxPositionForPile:pileID] + 1;
    sqlite3_exec(_db, "BEGIN IMMEDIATE", NULL, NULL, NULL);
    BOOL ok = [self executeUpdate:"UPDATE sf_pile_items SET pile_id = ?, position = ? WHERE item_node_id = ?"
                        bindBlock:^(sqlite3_stmt *stmt) {
                            sqlite3_bind_int64(stmt, 1, pileID);
                            sqlite3_bind_int64(stmt, 2, position);
                            sqlite3_bind_text(stmt, 3, [itemNodeID UTF8String], -1, SQLITE_TRANSIENT);
                        }
                            error:error];
    if (ok) {
        // Close the gap left in the source pile.
        NSArray<PileItem *> *remaining = [self itemsForPile:sourcePileID error:NULL];
        NSMutableArray<NSString *> *order = [NSMutableArray array];
        for (PileItem *item in remaining) {
            [order addObject:item.itemNodeID];
        }
        ok = [self rewritePositionsForPile:sourcePileID itemOrder:order error:error];
    }
    sqlite3_exec(_db, ok ? "COMMIT" : "ROLLBACK", NULL, NULL, NULL);
    if (!ok) {
        return NO;
    }
    [self recordAuditAction:@"pile.move"
                 objectRef:[NSString stringWithFormat:@"sf_pile_items:%@", itemNodeID]
                    before:@{@"pile_id": @(sourcePileID)}
                     after:@{@"pile_id": @(pileID)}
                     error:NULL];
    return YES;
}

- (BOOL)makeTopItem:(NSString *)itemNodeID error:(NSError **)error {
    PileItem *before = [self pileItemForItemNodeID:itemNodeID];
    if (before == nil) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:PileStoreErrorNotFound
                                     description:[NSString stringWithFormat:@"No piled item %@.", itemNodeID]];
        }
        return NO;
    }
    if (before.position == 0) {
        return YES;
    }
    NSArray<PileItem *> *items = [self itemsForPile:before.pileID error:error];
    if (items == nil) {
        return NO;
    }
    NSMutableArray<NSString *> *order = [NSMutableArray arrayWithObject:itemNodeID];
    for (PileItem *item in items) {
        if (![item.itemNodeID isEqualToString:itemNodeID]) {
            [order addObject:item.itemNodeID];
        }
    }
    sqlite3_exec(_db, "BEGIN IMMEDIATE", NULL, NULL, NULL);
    BOOL ok = [self rewritePositionsForPile:before.pileID itemOrder:order error:error];
    sqlite3_exec(_db, ok ? "COMMIT" : "ROLLBACK", NULL, NULL, NULL);
    if (!ok) {
        return NO;
    }
    [self recordAuditAction:@"pile.make_top"
                 objectRef:[NSString stringWithFormat:@"sf_pile_items:%@", itemNodeID]
                    before:@{@"position": @(before.position)}
                     after:@{@"position": @0}
                     error:NULL];
    return YES;
}

- (BOOL)clearTopOfPile:(int64_t)pileID error:(NSError **)error {
    NSArray<PileItem *> *items = [self itemsForPile:pileID error:error];
    if (items == nil) {
        return NO;
    }
    if ([items count] == 0) {
        return NO;  // empty pile is done; nothing to clear
    }
    Pile *done = [self donePileWithError:error];
    if (done == nil) {
        return NO;
    }
    PileItem *top = items[0];
    if (pileID == done.pileID) {
        return NO;  // the Done pile's top is already done
    }
    BOOL ok = [self moveItem:top.itemNodeID toPile:done.pileID error:error];
    if (ok) {
        [self recordAuditAction:@"pile.clear_top"
                     objectRef:[NSString stringWithFormat:@"sf_pile_items:%@", top.itemNodeID]
                        before:@{@"pile_id": @(pileID)}
                         after:@{@"pile_id": @(done.pileID)}
                         error:NULL];
    }
    return ok;
}

- (BOOL)moveItem:(NSString *)itemNodeID toPosition:(NSInteger)position error:(NSError **)error {
    PileItem *before = [self pileItemForItemNodeID:itemNodeID];
    if (before == nil) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:PileStoreErrorNotFound
                                     description:[NSString stringWithFormat:@"No piled item %@.", itemNodeID]];
        }
        return NO;
    }
    NSArray<PileItem *> *items = [self itemsForPile:before.pileID error:error];
    if (items == nil) {
        return NO;
    }
    NSInteger clamped = MAX(0, MIN(position, (NSInteger)[items count] - 1));
    if (clamped == before.position) {
        return YES;
    }
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (PileItem *item in items) {
        if (![item.itemNodeID isEqualToString:itemNodeID]) {
            [order addObject:item.itemNodeID];
        }
    }
    [order insertObject:itemNodeID atIndex:(NSUInteger)clamped];
    sqlite3_exec(_db, "BEGIN IMMEDIATE", NULL, NULL, NULL);
    BOOL ok = [self rewritePositionsForPile:before.pileID itemOrder:order error:error];
    sqlite3_exec(_db, ok ? "COMMIT" : "ROLLBACK", NULL, NULL, NULL);
    if (!ok) {
        return NO;
    }
    [self recordAuditAction:@"pile.reorder"
                 objectRef:[NSString stringWithFormat:@"sf_pile_items:%@", itemNodeID]
                    before:@{@"position": @(before.position)}
                     after:@{@"position": @(clamped)}
                     error:NULL];
    return YES;
}

- (int64_t)createPileWithName:(NSString *)name error:(NSError **)error {
    NSString *now = [[self class] iso8601Now];
    BOOL ok = [self executeUpdate:"INSERT INTO sf_piles (name, kind, board_node_id, created_at) VALUES (?, 'custom', NULL, ?)"
                        bindBlock:^(sqlite3_stmt *stmt) {
                            sqlite3_bind_text(stmt, 1, [name UTF8String], -1, SQLITE_TRANSIENT);
                            sqlite3_bind_text(stmt, 2, [now UTF8String], -1, SQLITE_TRANSIENT);
                        }
                            error:error];
    if (!ok) {
        return -1;
    }
    int64_t pileID = sqlite3_last_insert_rowid(_db);
    [self recordAuditAction:@"pile.create"
                 objectRef:[NSString stringWithFormat:@"sf_piles:%lld", pileID]
                    before:nil
                     after:@{@"name": name, @"kind": PileKindCustom}
                     error:NULL];
    return pileID;
}

- (BOOL)renamePile:(int64_t)pileID name:(NSString *)name error:(NSError **)error {
    Pile *pile = [self pileWithID:pileID error:error];
    if (pile == nil) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:PileStoreErrorNotFound
                                     description:[NSString stringWithFormat:@"No pile %lld.", pileID]];
        }
        return NO;
    }
    if ([pile.kind isEqualToString:PileKindSystemInbox] || [pile.kind isEqualToString:PileKindSystemDone]) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:PileStoreErrorSystemPileProtected
                                     description:@"The Inbox and Done piles cannot be renamed."];
        }
        return NO;
    }
    BOOL ok = [self executeUpdate:"UPDATE sf_piles SET name = ? WHERE id = ?"
                        bindBlock:^(sqlite3_stmt *stmt) {
                            sqlite3_bind_text(stmt, 1, [name UTF8String], -1, SQLITE_TRANSIENT);
                            sqlite3_bind_int64(stmt, 2, pileID);
                        }
                            error:error];
    if (!ok) {
        return NO;
    }
    [self recordAuditAction:@"pile.rename"
                 objectRef:[NSString stringWithFormat:@"sf_piles:%lld", pileID]
                    before:@{@"name": pile.name}
                     after:@{@"name": name}
                     error:NULL];
    return YES;
}

- (BOOL)deletePile:(int64_t)pileID error:(NSError **)error {
    Pile *pile = [self pileWithID:pileID error:error];
    if (pile == nil) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:PileStoreErrorNotFound
                                     description:[NSString stringWithFormat:@"No pile %lld.", pileID]];
        }
        return NO;
    }
    if ([pile.kind isEqualToString:PileKindSystemInbox] || [pile.kind isEqualToString:PileKindSystemDone]) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:PileStoreErrorSystemPileProtected
                                     description:@"The Inbox and Done piles cannot be deleted."];
        }
        return NO;
    }
    Pile *inbox = [self inboxPileWithError:error];
    if (inbox == nil) {
        return NO;
    }
    NSArray<PileItem *> *items = [self itemsForPile:pileID error:error];
    if (items == nil) {
        return NO;
    }
    sqlite3_exec(_db, "BEGIN IMMEDIATE", NULL, NULL, NULL);
    NSInteger position = [self maxPositionForPile:inbox.pileID] + 1;
    BOOL ok = YES;
    for (PileItem *item in items) {
        NSInteger pos = position++;
        ok = [self executeUpdate:"UPDATE sf_pile_items SET pile_id = ?, position = ? WHERE item_node_id = ?"
                        bindBlock:^(sqlite3_stmt *stmt) {
                            sqlite3_bind_int64(stmt, 1, inbox.pileID);
                            sqlite3_bind_int64(stmt, 2, pos);
                            sqlite3_bind_text(stmt, 3, [item.itemNodeID UTF8String], -1, SQLITE_TRANSIENT);
                        }
                            error:error];
        if (!ok) {
            break;
        }
    }
    if (ok) {
        ok = [self executeUpdate:"DELETE FROM sf_piles WHERE id = ?"
                        bindBlock:^(sqlite3_stmt *stmt) {
                            sqlite3_bind_int64(stmt, 1, pileID);
                        }
                            error:error];
    }
    sqlite3_exec(_db, ok ? "COMMIT" : "ROLLBACK", NULL, NULL, NULL);
    if (!ok) {
        return NO;
    }
    [self recordAuditAction:@"pile.delete"
                 objectRef:[NSString stringWithFormat:@"sf_piles:%lld", pileID]
                    before:@{@"name": pile.name, @"kind": pile.kind}
                     after:@{@"rehomed_to_inbox": @([items count])}
                     error:NULL];
    return YES;
}

@end
