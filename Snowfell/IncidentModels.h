// IncidentModels — the V11 Incidents lens data types (SF-T11; design
// record §12.5): the incident queue row, its deadlines, its assets, and
// the detail aggregate. Every vocabulary string (state, severity) is
// the snapshot's own data — the `name` rows of sf_incident_states /
// sf_incident_severities, joined on sf_incidents.state_id /
// severity_id at query time, never an app-side enum (§12.1 doctrine).
// Children (assets, deadlines) key on the integer sf_incidents.id in
// the applied schema (changes/0031); the lens joins them in the store.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface IncidentSummary : NSObject

@property (nonatomic, copy) NSString *key;               // sf_incidents.key
@property (nonatomic, copy) NSString *title;             // sf_incidents.title
@property (nonatomic, copy) NSString *stateName;         // sf_incident_states.name (data)
@property (nonatomic, assign) BOOL stateIsTerminal;      // sf_incident_states.is_terminal (data)
@property (nonatomic, copy) NSString *severityName;      // sf_incident_severities.name (data)
@property (nonatomic, assign) NSInteger severityPosition; // sort weight from the data row
@property (nonatomic, copy, nullable) NSString *counterpartyName;  // sf_counterparties.name
@property (nonatomic, copy) NSString *sourceChannel;     // sf_incidents.source_channel
@property (nonatomic, copy) NSString *openedAt;          // sf_incidents.opened_at
@property (nonatomic, assign) NSInteger assetCount;      // sf_incident_assets rows
@property (nonatomic, copy, nullable) NSString *nextDeadlineDue;   // MIN open due_at, ISO
@property (nonatomic, copy, nullable) NSString *nextDeadlineLabel; // its label

@property (nonatomic, readonly) NSString *deadlineDisplay;  // "2026-11-18 — <label>" | "—"

@end

@interface IncidentDeadline : NSObject

@property (nonatomic, copy) NSString *kind;              // sf_incident_deadlines.kind (data)
@property (nonatomic, copy) NSString *dueAt;             // sf_incident_deadlines.due_at
@property (nonatomic, copy) NSString *label;             // sf_incident_deadlines.label
@property (nonatomic, copy) NSString *state;             // open | met | missed | waived (data)

@end

@interface IncidentAsset : NSObject

@property (nonatomic, copy) NSString *assetType;         // sf_incident_assets.asset_type (data)
@property (nonatomic, copy) NSString *label;             // sf_incident_assets.label
@property (nonatomic, copy, nullable) NSString *accountRef;
@property (nonatomic, copy, nullable) NSString *messageID;
@property (nonatomic, copy, nullable) NSString *threadID;
@property (nonatomic, copy, nullable) NSString *localPath;
@property (nonatomic, copy, nullable) NSString *externalRef;
@property (nonatomic, copy, nullable) NSString *sha256;  // integrity, where a file exists
@property (nonatomic, strong, nullable) NSNumber *sizeBytes;
@property (nonatomic, copy) NSString *createdBy;
@property (nonatomic, copy) NSString *createdAt;

@end

@interface IncidentDetail : NSObject

@property (nonatomic, strong) IncidentSummary *summary;
@property (nonatomic, copy, nullable) NSString *summaryText;   // sf_incidents.summary
@property (nonatomic, copy, nullable) NSString *sourceRef;     // sf_incidents.source_ref
@property (nonatomic, copy) NSArray<IncidentDeadline *> *deadlines;
@property (nonatomic, copy) NSArray<IncidentAsset *> *assets;
// sf_audit_log lines for object_ref 'incident:<key>', oldest first —
// "ts — actor — action" composed at query time. Empty until a dispatch
// on this incident has executed and been published in a snapshot.
@property (nonatomic, copy) NSArray<NSString *> *timelineEntries;

@end

NS_ASSUME_NONNULL_END
