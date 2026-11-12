// DispatchStore — Snowfell's LOCAL store for estate-lane dispatches
// (SF-T5; design record §3 trigger path (b), §8 D6).
//
// D6: estate actions are enqueued as sf_dispatches-shaped rows and
// executed by Minion/hooks — NOT by this app. This class is the local
// half of that contract: enqueue / list / state transitions ONLY. There
// is deliberately no execution engine here (the estate consumer is
// SF-T6's tranche) and no network code of any kind.
//
// Storage: the SAME writable file WriteBackQueue owns
// (~/Library/Application Support/Snowfell/writeback.db), as a sibling
// table set — local_dispatches beside writeback_queue, sharing the one
// local_audit_log (WriteBackQueue's sf_audit_log-shaped table; both
// classes create it IF NOT EXISTS). The verified snapshot is never
// opened by this class, and never written by anyone.
//
// Rows mirror sf_dispatches semantics: a manifest action id, the payload
// exactly as composed, and a state machine — queued → approved →
// sent_to_lane → done | failed, with cancelled reachable from queued.
// Every enqueue, cancel, and transition appends a local_audit_log row
// (actions dispatch.enqueue / dispatch.cancel / dispatch.transition).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const DispatchStoreErrorDomain;

typedef NS_ENUM(NSInteger, DispatchStoreError) {
    DispatchStoreErrorOpenFailed = 1,
    DispatchStoreErrorSchemaFailed = 2,
    DispatchStoreErrorEnqueueFailed = 3,
    DispatchStoreErrorQueryFailed = 4,
    DispatchStoreErrorTransitionFailed = 5,
    DispatchStoreErrorInvalidTransition = 6,
};

// Row states (stored verbatim in local_dispatches.state; the schema's
// CHECK admits exactly these six).
extern NSString * const DispatchStateQueued;       // @"queued"
extern NSString * const DispatchStateApproved;     // @"approved"
extern NSString * const DispatchStateSentToLane;   // @"sent_to_lane"
extern NSString * const DispatchStateDone;         // @"done"
extern NSString * const DispatchStateFailed;       // @"failed"
extern NSString * const DispatchStateCancelled;    // @"cancelled"

// All six states, in lifecycle order — the Queue pane's filter source.
extern NSArray<NSString *> *DispatchAllStates(void);

@interface LocalDispatch : NSObject

@property (nonatomic, assign) int64_t dispatchID;
@property (nonatomic, copy) NSString *actionID;            // sf_actions.id
@property (nonatomic, copy) NSDictionary *payload;         // decoded payload_json
@property (nonatomic, copy) NSString *payloadJSON;         // payload_json, verbatim
@property (nonatomic, copy) NSString *state;               // one of the DispatchState* constants
@property (nonatomic, copy) NSString *createdAt;           // ISO 8601 UTC
@property (nonatomic, copy) NSString *updatedAt;           // ISO 8601 UTC
@property (nonatomic, copy, nullable) NSString *resultRef;
@property (nonatomic, copy, nullable) NSString *lastError;

// Human one-liner for the Queue pane, derived from the payload itself
// (the store never re-reads the snapshot to describe its rows).
@property (nonatomic, readonly) NSString *payloadSummary;

@end

@interface LocalAuditEntry : NSObject

@property (nonatomic, assign) int64_t auditID;
@property (nonatomic, copy) NSString *ts;
@property (nonatomic, copy) NSString *actor;
@property (nonatomic, copy) NSString *action;              // e.g. "dispatch.enqueue"
@property (nonatomic, copy, nullable) NSString *objectRef;
@property (nonatomic, copy, nullable) NSString *beforeJSON;
@property (nonatomic, copy, nullable) NSString *afterJSON;

@end

@interface DispatchStore : NSObject

@property (nonatomic, copy, readonly) NSString *storePath;

// The default store path — WriteBackQueue's file. The two stores are one
// file with disjoint table sets (local_dispatches here, writeback_queue
// there) and one shared local_audit_log.
+ (NSString *)defaultStorePath;

// Opens (creating tables if needed) the store at storePath. Returns nil
// and sets error on failure.
- (nullable instancetype)initWithStorePath:(NSString *)storePath
                                     error:(NSError **)error;

// Enqueues one estate-lane dispatch in state queued and appends the
// matching local_audit_log row (action dispatch.enqueue). Returns the
// row id, or -1 and sets error.
- (int64_t)enqueueDispatchWithActionID:(NSString *)actionID
                               payload:(NSDictionary *)payload
                                 error:(NSError **)error;

// SF-T11 (design record §12.5): enqueue one §12.2 incident action
// against one incident. Payload is {"incident_key": <key>} plus any
// extra fields the caller carries (e.g. a watch reference for
// incident.watch.arm). incident.email.send starts 'queued' BY DESIGN —
// a queued dispatch is a request for the owner's approval, never a
// send: the executor's approval gate (with the action's requires_confirm
// read from sf_actions, data not code) is what moves it, exactly as
// for every estate action. Returns the row id, or -1 and sets error.
- (int64_t)enqueueDispatchWithActionID:(NSString *)actionID
                           incidentKey:(NSString *)incidentKey
                          extraPayload:(nullable NSDictionary *)extraPayload
                                 error:(NSError **)error;

// All rows in FIFO order (id ASC).
- (nullable NSArray<LocalDispatch *> *)allDispatchesWithError:(NSError **)error;

// Rows in one state, FIFO.
- (nullable NSArray<LocalDispatch *> *)dispatchesWithState:(NSString *)state
                                                     error:(NSError **)error;

- (NSInteger)queuedCount;

// A generic audited transition (dispatch.transition). Refused with
// DispatchStoreErrorInvalidTransition when the target state is not one
// of the six, or the row does not exist. A non-nil resultRef replaces
// the row's result_ref; nil leaves it untouched.
- (BOOL)transitionDispatch:(int64_t)dispatchID
                   toState:(NSString *)state
                 resultRef:(nullable NSString *)resultRef
                     error:(NSError **)error;

// Cancel is the one transition the SF-T5 UI offers: queued → cancelled
// ONLY. Any other starting state is refused (a row an executor may
// already hold is never yanked silently), audited as dispatch.cancel.
- (BOOL)cancelDispatch:(int64_t)dispatchID error:(NSError **)error;

// The local audit log's dispatch.* entries, oldest first — the Queue
// pane's audit table. (writeback.* entries share the table and are the
// Write-back Queue panel's business, so they are filtered out here.)
- (nullable NSArray<LocalAuditEntry *> *)dispatchAuditEntriesWithError:(NSError **)error;

- (void)close;

@end

NS_ASSUME_NONNULL_END
