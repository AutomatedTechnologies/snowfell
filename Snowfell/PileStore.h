// PileStore — Snowfell's LOCAL store for the pile organizational
// method (design record 13, snowfell-test-8).
//
// A pile is a named stack with a strict working order: the top item
// (position 0) is THE next action. Piles are a LOCAL organizational
// fact only — they live in the app's existing local store file
// (writeback.db, the file WriteBackQueue and DispatchStore already
// share, with its local_audit_log), as two new tables owned here:
//
//   sf_piles       id INTEGER PK, name TEXT, kind TEXT
//                  (system_inbox | system_done | board | custom),
//                  board_node_id TEXT NULL, created_at TEXT
//   sf_pile_items  pile_id INTEGER FK, item_node_id TEXT UNIQUE NOT
//                  NULL, position INTEGER NOT NULL, title TEXT,
//                  board_title TEXT, added_at TEXT
//
// The UNIQUE constraint on item_node_id IS the one-pile-per-item
// invariant, enforced by the store, not by UI care. title/board_title
// are denormalized at placement time so a pile renders truthfully
// even after the snapshot swaps underneath it.
//
// The snapshot (registry.db) stays read-only: this class reads it
// ONLY through SnapshotStore's public queries
// (portfolioBoardsWithError / itemsForBoard / statusOptionsForBoard).
// Pile membership is never written to the snapshot, never staged
// into the write-back queue, and never sent to GitHub — this class
// has no path to the write-back client and no network code at all.
// Every mutation writes a local_audit_log row, like every other
// local act.
#import <Foundation/Foundation.h>

@class SnapshotStore;

NS_ASSUME_NONNULL_BEGIN

extern NSString * const PileStoreErrorDomain;

typedef NS_ENUM(NSInteger, PileStoreError) {
    PileStoreErrorOpenFailed = 1,
    PileStoreErrorSchemaFailed = 2,
    PileStoreErrorQueryFailed = 3,
    PileStoreErrorMutationFailed = 4,
    PileStoreErrorSystemPileProtected = 5,
    PileStoreErrorNotFound = 6,
};

extern NSString * const PileKindSystemInbox;  // @"system_inbox"
extern NSString * const PileKindSystemDone;   // @"system_done"
extern NSString * const PileKindBoard;        // @"board"
extern NSString * const PileKindCustom;       // @"custom"

@interface Pile : NSObject
@property (nonatomic, assign) int64_t pileID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *kind;                 // one of the PileKind* constants
@property (nonatomic, copy, nullable) NSString *boardNodeID;
@property (nonatomic, copy) NSString *createdAt;
@property (nonatomic, assign) NSInteger itemCount;          // composed at query time
@property (nonatomic, copy, nullable) NSString *topItemTitle; // composed at query time; nil when empty
@end

@interface PileItem : NSObject
@property (nonatomic, assign) int64_t pileID;
@property (nonatomic, copy) NSString *itemNodeID;
@property (nonatomic, assign) NSInteger position;           // 0 is the top
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *boardTitle;
@property (nonatomic, copy) NSString *addedAt;
@end

@interface PileStore : NSObject

@property (nonatomic, copy, readonly) NSString *storePath;
@property (nonatomic, strong, readonly, nullable) SnapshotStore *snapshotStore;

// The default store path — WriteBackQueue's file. All local stores
// are one file with disjoint table sets and one shared
// local_audit_log.
+ (NSString *)defaultStorePath;

// Opens (creating tables if needed) the store at storePath. The
// snapshot store is held for materialization/reconcile reads only.
- (nullable instancetype)initWithStorePath:(NSString *)storePath
                            snapshotStore:(nullable SnapshotStore *)snapshotStore
                                    error:(NSError **)error;

// Design record 13 section 3: ensures Inbox + Done + one pile per
// board exist, then places every snapshot item found in no pile
// (statusless -> Inbox; otherwise its board pile). On first
// materialization board piles are ordered by the board's own
// Status-vocabulary position, then snapshot import order; reconcile
// adds only (statusless -> Inbox top, else board pile bottom),
// never removes, never reorders an existing row, and is idempotent
// — a second pass adds zero rows. Returns the number of rows added,
// or -1 and sets error.
- (NSInteger)materializeAndReconcileWithError:(NSError **)error;

// All piles in display order: Inbox, board piles (snapshot board
// order), custom piles (creation order), Done.
- (nullable NSArray<Pile *> *)pilesWithError:(NSError **)error;

// One pile by id; nil when unknown.
- (nullable Pile *)pileWithID:(int64_t)pileID error:(NSError **)error;

// The Inbox / Done system piles (created by materialization).
- (nullable Pile *)inboxPileWithError:(NSError **)error;
- (nullable Pile *)donePileWithError:(NSError **)error;

// The stack of one pile, top first (position ASC).
- (nullable NSArray<PileItem *> *)itemsForPile:(int64_t)pileID
                                         error:(NSError **)error;

// Moves one item to the bottom of the destination pile — one UPDATE
// against the UNIQUE(item_node_id) row, so the invariant holds by
// construction. Audited pile.move.
- (BOOL)moveItem:(NSString *)itemNodeID
          toPile:(int64_t)pileID
           error:(NSError **)error;

// Promotes one item to position 0 of its own pile. Audited pile.make_top.
- (BOOL)makeTopItem:(NSString *)itemNodeID error:(NSError **)error;

// The finishing verb: moves the top item of pileID to the Done pile.
// Returns NO (no error) when the pile is already empty. Audited
// pile.clear_top.
- (BOOL)clearTopOfPile:(int64_t)pileID error:(NSError **)error;

// Reorders one item within its own pile to a new position (the
// within-stack drag path). Audited pile.reorder.
- (BOOL)moveItem:(NSString *)itemNodeID
      toPosition:(NSInteger)position
           error:(NSError **)error;

// Custom piles. System piles can neither be renamed nor deleted.
- (int64_t)createPileWithName:(NSString *)name error:(NSError **)error;
- (BOOL)renamePile:(int64_t)pileID name:(NSString *)name error:(NSError **)error;

// Deleting a pile rehomes every item it held to the Inbox (never
// orphans an item; the invariant survives deletion). Audited
// pile.delete.
- (BOOL)deletePile:(int64_t)pileID error:(NSError **)error;

- (void)close;

@end

NS_ASSUME_NONNULL_END
