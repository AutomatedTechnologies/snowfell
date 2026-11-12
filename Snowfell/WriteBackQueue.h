// WriteBackQueue — Snowfell's LOCAL writable store for pending GitHub
// mutations (SF-T4; design record §2 D1 split authority, §3, D3).
//
// D1: GitHub owns items and status; the snapshot stays PRISTINE. This
// store is a separate SQLite file in Application Support
// (~/Library/Application Support/Snowfell/writeback.db), opened read-write
// through the sqlite3 C API. It never touches the verified snapshot.
//
// Rows mirror sf_dispatches semantics: a queued mutation with a state
// machine (pending → sending → sent | failed), an attempt counter, and the
// last error as a plain fact. Enqueue + list + state transitions ONLY —
// this class builds no GraphQL, reads no Keychain, and makes no network
// call. Sending lives in GitHubProjectsClient behind the arm discipline.
//
// D3: exactly three kinds exist in write-back v1 — status_move,
// create_item, comment. The CHECK constraint in the schema refuses any
// other kind, so a fourth operation cannot be queued by accident.
//
// Every enqueue and every send outcome also appends an sf_audit_log-shaped
// row to local_audit_log (design §2/§3: every mutation is audited).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const WriteBackQueueErrorDomain;

typedef NS_ENUM(NSInteger, WriteBackQueueError) {
    WriteBackQueueErrorOpenFailed = 1,
    WriteBackQueueErrorSchemaFailed = 2,
    WriteBackQueueErrorEnqueueFailed = 3,
    WriteBackQueueErrorQueryFailed = 4,
    WriteBackQueueErrorTransitionFailed = 5,
};

// The three D3 kinds (stored verbatim in writeback_queue.kind).
extern NSString * const WriteBackKindStatusMove;   // @"status_move"
extern NSString * const WriteBackKindCreateItem;   // @"create_item"
extern NSString * const WriteBackKindComment;      // @"comment"

// Row states (stored verbatim in writeback_queue.state).
extern NSString * const WriteBackStatePending;     // @"pending"
extern NSString * const WriteBackStateSending;     // @"sending"
extern NSString * const WriteBackStateSent;        // @"sent"
extern NSString * const WriteBackStateFailed;      // @"failed"

@interface WriteBackMutation : NSObject

@property (nonatomic, assign) int64_t queueID;
@property (nonatomic, copy) NSString *kind;              // one of the WriteBackKind* constants
@property (nonatomic, copy) NSString *boardID;           // sf_boards.gh_node_id
@property (nonatomic, copy, nullable) NSString *itemID;  // sf_items.gh_node_id; nil for create_item
@property (nonatomic, copy) NSDictionary *payload;       // decoded payload_json
@property (nonatomic, copy) NSString *payloadJSON;       // payload_json, verbatim
@property (nonatomic, copy) NSString *state;             // one of the WriteBackState* constants
@property (nonatomic, copy) NSString *createdAt;         // ISO 8601 UTC
@property (nonatomic, assign) NSInteger attempts;
@property (nonatomic, copy, nullable) NSString *lastError;

// Human one-liner for the Queue panel, derived from the payload's display
// keys (titles / option names ride the payload for exactly this purpose —
// the queue never re-reads the snapshot to describe itself).
@property (nonatomic, readonly) NSString *targetSummary;

@end

@interface WriteBackQueue : NSObject

@property (nonatomic, copy, readonly) NSString *storePath;

// The default store: Application Support/Snowfell/writeback.db (the
// directory is created on open). This is the ONLY writable database the
// app owns; the snapshot contract is untouched by it.
+ (NSString *)defaultStorePath;

// Opens (creating if needed) the store at storePath and ensures the
// schema. Returns nil and sets error on failure.
- (nullable instancetype)initWithStorePath:(NSString *)storePath
                                     error:(NSError **)error;

// Enqueues one mutation in state pending and appends the matching
// local_audit_log row (action writeback.enqueue). Returns the row id,
// or -1 and sets error.
- (int64_t)enqueueMutationWithKind:(NSString *)kind
                           boardID:(NSString *)boardID
                            itemID:(nullable NSString *)itemID
                           payload:(NSDictionary *)payload
                             error:(NSError **)error;

// All rows in FIFO order (id ASC) — the Queue panel's list.
- (nullable NSArray<WriteBackMutation *> *)allMutationsWithError:(NSError **)error;

// Pending rows only, FIFO — the send pass's work list.
- (nullable NSArray<WriteBackMutation *> *)pendingMutationsWithError:(NSError **)error;

- (NSInteger)pendingCount;

// State transitions. markSending also increments attempts (one attempt
// per send action per row — the caller never loops a row inside a pass).
- (BOOL)markSending:(int64_t)queueID error:(NSError **)error;
- (BOOL)markSent:(int64_t)queueID error:(NSError **)error;
- (BOOL)markFailed:(int64_t)queueID message:(NSString *)message error:(NSError **)error;

// Appends one sf_audit_log-shaped row (ts, actor, action, object_ref,
// before_json, after_json) to local_audit_log.
- (BOOL)recordAuditAction:(NSString *)action
               objectRef:(nullable NSString *)objectRef
                  before:(nullable NSDictionary *)before
                   after:(nullable NSDictionary *)after
                   error:(NSError **)error;

- (void)close;

@end

NS_ASSUME_NONNULL_END
