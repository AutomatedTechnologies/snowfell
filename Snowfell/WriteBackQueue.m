#import "WriteBackQueue.h"
#import <sqlite3.h>

NSString * const WriteBackQueueErrorDomain = @"com.detroitautomationacademy.snowfell.WriteBackQueue";

NSString * const WriteBackKindStatusMove = @"status_move";
NSString * const WriteBackKindCreateItem = @"create_item";
NSString * const WriteBackKindComment = @"comment";

NSString * const WriteBackStatePending = @"pending";
NSString * const WriteBackStateSending = @"sending";
NSString * const WriteBackStateSent = @"sent";
NSString * const WriteBackStateFailed = @"failed";

@implementation WriteBackMutation

- (NSString *)targetSummary {
    NSString *itemTitle = self.payload[@"item_title"];
    if ([self.kind isEqualToString:WriteBackKindStatusMove]) {
        NSString *optionName = self.payload[@"option_name"];
        return [NSString stringWithFormat:@"%@ → Status: %@",
                (itemTitle != nil) ? itemTitle : @"(item)",
                (optionName != nil) ? optionName : @"?"];
    }
    if ([self.kind isEqualToString:WriteBackKindCreateItem]) {
        NSString *title = self.payload[@"title"];
        NSString *optionName = self.payload[@"option_name"];
        NSString *base = [NSString stringWithFormat:@"New draft issue: %@",
                          (title != nil) ? title : @"(untitled)"];
        return (optionName != nil)
            ? [base stringByAppendingFormat:@" (Status: %@)", optionName] : base;
    }
    if ([self.kind isEqualToString:WriteBackKindComment]) {
        NSString *body = self.payload[@"body"];
        NSString *excerpt = (body != nil) ? body : @"";
        if ([excerpt length] > 60) {
            excerpt = [[excerpt substringToIndex:60] stringByAppendingString:@"…"];
        }
        return [NSString stringWithFormat:@"Comment on %@: “%@”",
                (itemTitle != nil) ? itemTitle : @"(item)", excerpt];
    }
    return self.kind;
}

@end

@interface WriteBackQueue () {
    sqlite3 *_db;
}
@property (nonatomic, copy, readwrite) NSString *storePath;
@end

@implementation WriteBackQueue

+ (NSError *)errorWithCode:(WriteBackQueueError)code description:(NSString *)description {
    return [NSError errorWithDomain:WriteBackQueueErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

+ (NSString *)defaultStorePath {
    NSArray<NSString *> *directories =
        NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *base = ([directories count] > 0) ? directories[0]
                                               : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
    NSString *directory = [base stringByAppendingPathComponent:@"Snowfell"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return [directory stringByAppendingPathComponent:@"writeback.db"];
}

+ (NSString *)iso8601Now {
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    [formatter setFormatOptions:NSISO8601DateFormatWithInternetDateTime];
    [formatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
    return [formatter stringFromDate:[NSDate date]];
}

- (instancetype)initWithStorePath:(NSString *)storePath
                            error:(NSError **)error {
    self = [super init];
    if (self) {
        _storePath = [storePath copy];
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
                *error = [[self class] errorWithCode:WriteBackQueueErrorOpenFailed
                                         description:[NSString stringWithFormat:
                                                      @"Write-back store could not be opened at %@: %@", storePath, message]];
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
    // Mirrors sf_dispatches semantics (design §2) in a local table, plus a
    // local sf_audit_log-shaped table. The kind CHECK is the D3 fence:
    // write-back v1 is exactly three operations.
    const char *sql =
        "CREATE TABLE IF NOT EXISTS writeback_queue ("
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  kind TEXT NOT NULL CHECK (kind IN ('status_move','create_item','comment')),"
        "  board_id TEXT NOT NULL,"
        "  item_id TEXT,"
        "  payload_json TEXT NOT NULL,"
        "  state TEXT NOT NULL DEFAULT 'pending'"
        "    CHECK (state IN ('pending','sending','sent','failed')),"
        "  created_at TEXT NOT NULL,"
        "  attempts INTEGER NOT NULL DEFAULT 0,"
        "  last_error TEXT"
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
            *error = [[self class] errorWithCode:WriteBackQueueErrorSchemaFailed
                                     description:[NSString stringWithFormat:
                                                  @"Write-back schema failed: %s",
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

static NSString *WBColumnText(sqlite3_stmt *statement, int column) {
    const unsigned char *text = sqlite3_column_text(statement, column);
    return (text != NULL) ? [NSString stringWithUTF8String:(const char *)text] : @"";
}

static NSString *WBColumnNullableText(sqlite3_stmt *statement, int column) {
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
            *error = [[self class] errorWithCode:WriteBackQueueErrorTransitionFailed
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
        *error = [[self class] errorWithCode:WriteBackQueueErrorTransitionFailed
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

#pragma mark - Enqueue

- (int64_t)enqueueMutationWithKind:(NSString *)kind
                           boardID:(NSString *)boardID
                            itemID:(NSString *)itemID
                           payload:(NSDictionary *)payload
                             error:(NSError **)error {
    NSString *payloadJSON = [self jsonStringForObject:payload];
    if (payloadJSON == nil) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:WriteBackQueueErrorEnqueueFailed
                                     description:@"Payload could not be serialized to JSON; nothing was queued."];
        }
        return -1;
    }
    NSString *createdAt = [[self class] iso8601Now];
    const char *sql =
        "INSERT INTO writeback_queue (kind, board_id, item_id, payload_json, state, created_at, attempts, last_error) "
        "VALUES (?, ?, ?, ?, 'pending', ?, 0, NULL)";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:WriteBackQueueErrorEnqueueFailed
                                     description:[NSString stringWithFormat:
                                                  @"Enqueue prepare failed: %s", sqlite3_errmsg(_db)]];
        }
        return -1;
    }
    sqlite3_bind_text(statement, 1, [kind UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(statement, 2, [boardID UTF8String], -1, SQLITE_TRANSIENT);
    if (itemID != nil) {
        sqlite3_bind_text(statement, 3, [itemID UTF8String], -1, SQLITE_TRANSIENT);
    } else {
        sqlite3_bind_null(statement, 3);
    }
    sqlite3_bind_text(statement, 4, [payloadJSON UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(statement, 5, [createdAt UTF8String], -1, SQLITE_TRANSIENT);
    BOOL ok = (sqlite3_step(statement) == SQLITE_DONE);
    sqlite3_finalize(statement);
    if (!ok) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:WriteBackQueueErrorEnqueueFailed
                                     description:[NSString stringWithFormat:
                                                  @"Enqueue failed: %s", sqlite3_errmsg(_db)]];
        }
        return -1;
    }
    int64_t queueID = sqlite3_last_insert_rowid(_db);
    // Design §3: every mutation is audited — the enqueue itself included.
    [self recordAuditAction:@"writeback.enqueue"
                 objectRef:[NSString stringWithFormat:@"writeback_queue:%lld", queueID]
                    before:nil
                     after:@{@"kind": kind,
                             @"board_id": boardID,
                             @"item_id": (itemID != nil) ? itemID : [NSNull null],
                             @"payload": payload,
                             @"state": WriteBackStatePending}
                     error:NULL];
    return queueID;
}

#pragma mark - Listing

- (NSArray<WriteBackMutation *> *)mutationsWhere:(NSString *)whereClause
                                           error:(NSError **)error {
    NSString *sql = [NSString stringWithFormat:
                     @"SELECT id, kind, board_id, item_id, payload_json, state, created_at, attempts, last_error "
                     @"FROM writeback_queue %@ ORDER BY id ASC", whereClause];
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, [sql UTF8String], -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:WriteBackQueueErrorQueryFailed
                                     description:[NSString stringWithFormat:
                                                  @"Queue query failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    NSMutableArray<WriteBackMutation *> *rows = [NSMutableArray array];
    while (sqlite3_step(statement) == SQLITE_ROW) {
        WriteBackMutation *mutation = [[WriteBackMutation alloc] init];
        mutation.queueID = sqlite3_column_int64(statement, 0);
        mutation.kind = WBColumnText(statement, 1);
        mutation.boardID = WBColumnText(statement, 2);
        mutation.itemID = WBColumnNullableText(statement, 3);
        mutation.payloadJSON = WBColumnText(statement, 4);
        mutation.state = WBColumnText(statement, 5);
        mutation.createdAt = WBColumnText(statement, 6);
        mutation.attempts = sqlite3_column_int64(statement, 7);
        mutation.lastError = WBColumnNullableText(statement, 8);
        id parsed = [NSJSONSerialization JSONObjectWithData:[mutation.payloadJSON dataUsingEncoding:NSUTF8StringEncoding]
                                                    options:0
                                                      error:NULL];
        mutation.payload = [parsed isKindOfClass:[NSDictionary class]] ? parsed : @{};
        [rows addObject:mutation];
    }
    sqlite3_finalize(statement);
    return rows;
}

- (NSArray<WriteBackMutation *> *)allMutationsWithError:(NSError **)error {
    return [self mutationsWhere:@"" error:error];
}

- (NSArray<WriteBackMutation *> *)pendingMutationsWithError:(NSError **)error {
    return [self mutationsWhere:@"WHERE state = 'pending'" error:error];
}

- (NSInteger)pendingCount {
    sqlite3_stmt *statement = NULL;
    NSInteger count = 0;
    if (sqlite3_prepare_v2(_db, "SELECT COUNT(*) FROM writeback_queue WHERE state = 'pending'",
                           -1, &statement, NULL) == SQLITE_OK) {
        if (sqlite3_step(statement) == SQLITE_ROW) {
            count = sqlite3_column_int64(statement, 0);
        }
    }
    sqlite3_finalize(statement);
    return count;
}

#pragma mark - State transitions

- (BOOL)markSending:(int64_t)queueID error:(NSError **)error {
    return [self executeUpdate:"UPDATE writeback_queue SET state = 'sending', attempts = attempts + 1 WHERE id = ?"
                     bindBlock:^(sqlite3_stmt *statement) {
                         sqlite3_bind_int64(statement, 1, queueID);
                     }
                         error:error];
}

- (BOOL)markSent:(int64_t)queueID error:(NSError **)error {
    return [self executeUpdate:"UPDATE writeback_queue SET state = 'sent', last_error = NULL WHERE id = ?"
                     bindBlock:^(sqlite3_stmt *statement) {
                         sqlite3_bind_int64(statement, 1, queueID);
                     }
                         error:error];
}

- (BOOL)markFailed:(int64_t)queueID message:(NSString *)message error:(NSError **)error {
    return [self executeUpdate:"UPDATE writeback_queue SET state = 'failed', last_error = ? WHERE id = ?"
                     bindBlock:^(sqlite3_stmt *statement) {
                         sqlite3_bind_text(statement, 1, [message UTF8String], -1, SQLITE_TRANSIENT);
                         sqlite3_bind_int64(statement, 2, queueID);
                     }
                         error:error];
}

#pragma mark - Audit

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

@end
