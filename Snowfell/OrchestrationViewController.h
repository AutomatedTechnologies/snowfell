// OrchestrationViewController — the Orchestration Center (V4; SF-T5;
// design record §3, §8 D6). Three panes, all fed from data:
//
//   (a) ACTION MANIFEST — every sf_actions row from the verified
//       snapshot (name, kind, risk, requires-confirm, enabled), with the
//       selected action's target + payload_schema_json shown verbatim.
//       Disabled actions render struck and cannot be composed.
//   (b) DISPATCH COMPOSER — a form GENERATED from the selected action's
//       payload_schema_json: schema keys become fields, *_id keys that
//       reference boards / items / deploy targets become snapshot-fed
//       dropdowns, and a live preview shows the exact payload that will
//       be stored. Enqueueing passes through a confirm sheet in the §3
//       access-review form naming the lane and the destination.
//   (c) DISPATCH QUEUE + AUDIT — the local_dispatches rows with state
//       filters, cancel for queued rows, and the local audit log's
//       dispatch.* entries.
//
// THE TWO LANES (D6, as built in SF-T5):
//   * Estate lane — the row lands in DispatchStore (local_dispatches,
//     state queued) for Minion/hooks to execute (the consumer is
//     SF-T6). This app executes NOTHING from that queue.
//   * GitHub lane — ONLY manifest actions that map exactly onto a D3
//     write-back operation take it, translated into the SF-T4
//     WriteBackQueue (in this build: gh.project.move_item →
//     status_move). Every other GitHub-kind manifest action queues on
//     the estate lane for SF-T6's consumer; no direct-fire path is
//     invented for them here. See the README's SF-T5 lane table.
//
// This controller contains no network code and no execution engine.
#import <AppKit/AppKit.h>

@class SnapshotStore;
@class DispatchStore;
@class WriteBackQueue;

NS_ASSUME_NONNULL_BEGIN

@interface OrchestrationViewController : NSViewController

@property (nonatomic, strong, readonly) SnapshotStore *snapshotStore;
@property (nonatomic, strong, readonly, nullable) DispatchStore *dispatchStore;
@property (nonatomic, strong, readonly, nullable) WriteBackQueue *writeBackQueue;

- (instancetype)initWithSnapshotStore:(SnapshotStore *)snapshotStore
                        dispatchStore:(nullable DispatchStore *)dispatchStore
                       writeBackQueue:(nullable WriteBackQueue *)writeBackQueue;

// Re-reads the manifest + dropdown sources from the snapshot and the
// queue + audit from the local stores, and re-renders every pane.
- (void)reloadOrchestration;

// SF-T7 seam: preselect one manifest action in the composer (the ⌘K
// palette's action/draft routing lands here). Call AFTER
// reloadOrchestration (AppDelegate's show flow reloads first, then
// preselects, so the reload's keep-selection logic cannot override the
// routing). An unknown id leaves the current selection untouched.
- (void)selectActionWithID:(NSString *)actionID;

@end

NS_ASSUME_NONNULL_END
