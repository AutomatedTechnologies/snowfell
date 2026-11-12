// IncidentsViewController — V11 Incidents (SF-T11; design record
// §12.5): the incident queue + detail inside V3's frame (≥1100×680,
// split so structure and evidence sit side by side). The queue (left)
// is SnapshotStore.incidentSummaries — ordered by next open deadline,
// with each row's state/severity/counterparty names straight from the
// snapshot's vocabulary tables. The detail (right) shows the summary,
// deadlines, and the asset inventory with hashes where a file exists —
// corroboration assets are the safety net, on the record with their
// sha256 (§12.5). Dispatch buttons for the §12.2 incident actions go
// through DispatchStore.enqueueDispatchWithActionID:incidentKey: —
// enqueues only; sending stays owner-gated (incident.email.send sits
// queued until the owner's approval moves it). The incident timeline
// is the §12.5 sf_audit_log slice via object_ref 'incident:<key>' —
// it rides the NEXT snapshot; this lens states that plainly instead of
// showing an empty table that looks like an empty history.
#import <AppKit/AppKit.h>

@class SnapshotStore;
@class DispatchStore;
@class IncidentSummary;

NS_ASSUME_NONNULL_BEGIN

@interface IncidentsViewController : NSViewController

@property (nonatomic, strong, readonly) SnapshotStore *snapshotStore;

// The counts line under the window title states the snapshot version
// when the incident domain is absent from it (pre-0031 snapshots) —
// AppDelegate supplies it via this property after init.
@property (nonatomic, copy, nullable) NSString *snapshotVersion;

// A dispatch was enqueued (the orchestrator's Queue pane picks it up).
@property (nonatomic, copy, nullable) void (^dispatchEnqueuedHandler)(NSInteger dispatchID, NSString *actionID);

// Selecting a queue row activates the incident: AppDelegate records it
// (and may surface it elsewhere) — the detail pane is this controller's.
@property (nonatomic, copy, nullable) void (^incidentActivationHandler)(IncidentSummary *incident);

- (instancetype)initWithSnapshotStore:(SnapshotStore *)store
                        dispatchStore:(nullable DispatchStore *)dispatchStore;

// Re-queries the snapshot (queue + current detail). Safe with no
// snapshot loaded and with a pre-0031 snapshot: the view states the
// fact (and the snapshot version, when supplied) instead.
- (void)reloadIncidents;

@end

NS_ASSUME_NONNULL_END
