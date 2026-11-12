#import "IncidentsViewController.h"
#import "SnapshotStore.h"
#import "DispatchStore.h"
#import "IncidentModels.h"
#import "SFAction.h"

// The §12.2 incident action set, rendered as buttons. Each button's
// destination/operator/effect text (§12.5's access-review-form confirm
// sheet) comes from the manifest row itself (sf_actions via
// SnapshotStore.actions — id, name, kind, target, requires_confirm),
// never from strings in this file.
static NSString * const IncidentsActionDraftReply  = @"incident.email.draft_reply";
static NSString * const IncidentsActionSend        = @"incident.email.send";
static NSString * const IncidentsActionPhone       = @"incident.phone.call";
static NSString * const IncidentsActionComplaint   = @"incident.complaint.file";
static NSString * const IncidentsActionWatchArm    = @"incident.watch.arm";

@interface IncidentsViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong, readwrite) SnapshotStore *snapshotStore;
@property (nonatomic, strong, nullable) DispatchStore *dispatchStore;
@property (nonatomic, copy) NSArray<IncidentSummary *> *incidents;
@property (nonatomic, strong, nullable) IncidentSummary *selectedIncident;
@property (nonatomic, strong, nullable) IncidentDetail *currentDetail;
@property (nonatomic, copy) NSArray<SFAction *> *actions;

@property (nonatomic, strong) NSTextField *headerField;
@property (nonatomic, strong) NSTextField *subheaderField;
@property (nonatomic, strong) NSTableView *queueTable;
@property (nonatomic, strong) NSTableView *deadlineTable;
@property (nonatomic, strong) NSTableView *assetTable;
@property (nonatomic, strong) NSScrollView *queueScroll;
@property (nonatomic, strong) NSScrollView *detailScroll;
@property (nonatomic, strong) NSTextField *detailTitleField;
@property (nonatomic, strong) NSTextField *detailMetaField;
@property (nonatomic, strong) NSTextField *detailSummaryField;
@property (nonatomic, strong) NSTextField *deadlineHeaderField;
@property (nonatomic, strong) NSTextField *assetHeaderField;
@property (nonatomic, strong) NSTextField *timelineField;
@property (nonatomic, strong) NSTextField *statusField;
@property (nonatomic, strong) NSButton *draftButton;
@property (nonatomic, strong) NSButton *sendButton;
@property (nonatomic, strong) NSButton *phoneButton;
@property (nonatomic, strong) NSButton *complaintButton;
@property (nonatomic, strong) NSButton *watchButton;
@end

@implementation IncidentsViewController

- (instancetype)initWithSnapshotStore:(SnapshotStore *)store
                        dispatchStore:(DispatchStore *)dispatchStore {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _snapshotStore = store;
        _dispatchStore = dispatchStore;
        _incidents = @[];
        _actions = @[];
    }
    return self;
}

#pragma mark - View construction

- (NSTableColumn *)columnWithIdentifier:(NSString *)identifier
                                  title:(NSString *)title
                                  width:(CGFloat)width
                                inTable:(NSTableView *)table {
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifier];
    [column setTitle:title];
    [column setWidth:width];
    [column setMinWidth:40];
    [table addTableColumn:column];
    return column;
}

- (NSButton *)actionButtonWithTitle:(NSString *)title {
    NSButton *button = [NSButton buttonWithTitle:title
                                          target:self
                                          action:@selector(actionButtonClicked:)];
    [button setBezelStyle:NSRoundedBezelStyle];
    return button;
}

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1120, 680)];

    _headerField = [NSTextField labelWithString:@""];
    [_headerField setFont:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]];
    [_headerField setFrame:NSMakeRect(16, 652, 1088, 18)];
    [_headerField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:_headerField];

    _subheaderField = [NSTextField labelWithString:@""];
    [_subheaderField setFont:[NSFont systemFontOfSize:12]];
    [_subheaderField setTextColor:[NSColor secondaryLabelColor]];
    [[_subheaderField cell] setWraps:YES];
    [_subheaderField setFrame:NSMakeRect(16, 610, 1088, 36)];
    [_subheaderField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:_subheaderField];

    // Left: the queue.
    _queueTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 400, 560)];
    [self columnWithIdentifier:@"key" title:@"Incident" width:150 inTable:_queueTable];
    [self columnWithIdentifier:@"severity" title:@"Severity" width:74 inTable:_queueTable];
    [self columnWithIdentifier:@"state" title:@"State" width:96 inTable:_queueTable];
    [self columnWithIdentifier:@"deadline" title:@"Next deadline" width:76 inTable:_queueTable];
    [_queueTable setDataSource:self];
    [_queueTable setDelegate:self];
    [_queueTable setAllowsMultipleSelection:NO];
    [_queueTable setTarget:self];
    [_queueTable setDoubleAction:@selector(queueDoubleClicked:)];

    _queueScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 44, 400, 560)];
    [_queueScroll setHasVerticalScroller:YES];
    [_queueScroll setBorderType:NSBezelBorder];
    [_queueScroll setDocumentView:_queueTable];
    [_queueScroll setAutoresizingMask:NSViewHeightSizable];
    [root addSubview:_queueScroll];

    // Right: the detail, scrolling as one pane.
    NSView *detail = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 560)];
    CGFloat y = 560.0;

    _detailTitleField = [NSTextField labelWithString:@""];
    [_detailTitleField setFont:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]];
    [[_detailTitleField cell] setWraps:YES];
    y -= 44.0;
    [_detailTitleField setFrame:NSMakeRect(12, y, 616, 40)];
    [detail addSubview:_detailTitleField];

    _detailMetaField = [NSTextField labelWithString:@""];
    [_detailMetaField setFont:[NSFont systemFontOfSize:12]];
    [[_detailMetaField cell] setWraps:YES];
    y -= 76.0;
    [_detailMetaField setFrame:NSMakeRect(12, y, 616, 72)];
    [detail addSubview:_detailMetaField];

    _detailSummaryField = [NSTextField labelWithString:@""];
    [_detailSummaryField setFont:[NSFont systemFontOfSize:12]];
    [[_detailSummaryField cell] setWraps:YES];
    y -= 92.0;
    [_detailSummaryField setFrame:NSMakeRect(12, y, 616, 88)];
    [detail addSubview:_detailSummaryField];

    // Dispatch buttons (the §12.2 actions) under the summary.
    _draftButton = [self actionButtonWithTitle:@"Draft Reply"];
    _sendButton = [self actionButtonWithTitle:@"Send Email…"];
    _phoneButton = [self actionButtonWithTitle:@"Call"];
    _complaintButton = [self actionButtonWithTitle:@"File Complaint"];
    _watchButton = [self actionButtonWithTitle:@"Arm Watch"];
    NSArray<NSButton *> *buttons = @[_draftButton, _sendButton, _phoneButton,
                                     _complaintButton, _watchButton];
    CGFloat bx = 12.0;
    y -= 30.0;
    for (NSButton *button in buttons) {
        [button setFrame:NSMakeRect(bx, y, 118, 26)];
        [detail addSubview:button];
        bx += 124.0;
    }

    y -= 22.0;
    _statusField = [NSTextField labelWithString:@""];
    [_statusField setFont:[NSFont systemFontOfSize:11]];
    [_statusField setTextColor:[NSColor secondaryLabelColor]];
    [[_statusField cell] setWraps:YES];
    [_statusField setFrame:NSMakeRect(12, y, 616, 20)];
    [detail addSubview:_statusField];

    _deadlineHeaderField = [NSTextField labelWithString:@"Deadlines"];
    [_deadlineHeaderField setFont:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]];
    y -= 24.0;
    [_deadlineHeaderField setFrame:NSMakeRect(12, y, 616, 18)];
    [detail addSubview:_deadlineHeaderField];

    _deadlineTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 616, 110)];
    [self columnWithIdentifier:@"due" title:@"Due" width:130 inTable:_deadlineTable];
    [self columnWithIdentifier:@"kind" title:@"Kind" width:96 inTable:_deadlineTable];
    [self columnWithIdentifier:@"dstate" title:@"State" width:110 inTable:_deadlineTable];
    [self columnWithIdentifier:@"label" title:@"Label" width:276 inTable:_deadlineTable];
    [_deadlineTable setDataSource:self];
    [_deadlineTable setDelegate:self];
    [_deadlineTable setAllowsMultipleSelection:NO];
    NSScrollView *deadlineScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(12, 0, 616, 110)];
    [deadlineScroll setHasVerticalScroller:YES];
    [deadlineScroll setBorderType:NSBezelBorder];
    [deadlineScroll setDocumentView:_deadlineTable];
    y -= 116.0;
    [deadlineScroll setFrame:NSMakeRect(12, y, 616, 110)];
    [detail addSubview:deadlineScroll];

    _assetHeaderField = [NSTextField labelWithString:@"Assets — evidence on the record"];
    [_assetHeaderField setFont:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]];
    y -= 24.0;
    [_assetHeaderField setFrame:NSMakeRect(12, y, 616, 18)];
    [detail addSubview:_assetHeaderField];

    _assetTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 616, 150)];
    [self columnWithIdentifier:@"atype" title:@"Type" width:100 inTable:_assetTable];
    [self columnWithIdentifier:@"alabel" title:@"Label" width:252 inTable:_assetTable];
    [self columnWithIdentifier:@"aref" title:@"Ref (message / path)" width:150 inTable:_assetTable];
    [self columnWithIdentifier:@"asha" title:@"SHA-256" width:110 inTable:_assetTable];
    [_assetTable setDataSource:self];
    [_assetTable setDelegate:self];
    [_assetTable setAllowsMultipleSelection:NO];
    NSScrollView *assetScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(12, 0, 616, 150)];
    [assetScroll setHasVerticalScroller:YES];
    [assetScroll setBorderType:NSBezelBorder];
    [assetScroll setDocumentView:_assetTable];
    y -= 156.0;
    [assetScroll setFrame:NSMakeRect(12, y, 616, 150)];
    [detail addSubview:assetScroll];

    _timelineField = [NSTextField labelWithString:@""];
    [_timelineField setFont:[NSFont systemFontOfSize:11]];
    [_timelineField setTextColor:[NSColor secondaryLabelColor]];
    [[_timelineField cell] setWraps:YES];
    y -= 52.0;
    [_timelineField setFrame:NSMakeRect(12, y, 616, 48)];
    [detail addSubview:_timelineField];

    _detailScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(432, 44, 664, 560)];
    [_detailScroll setHasVerticalScroller:YES];
    [_detailScroll setBorderType:NSNoBorder];
    [_detailScroll setDocumentView:detail];
    [_detailScroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [root addSubview:_detailScroll];

    self.view = root;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self reloadIncidents];
}

#pragma mark - Loading

- (SFAction *)manifestActionWithID:(NSString *)actionID {
    for (SFAction *action in self.actions) {
        if ([action.actionID isEqualToString:actionID]) {
            return action;
        }
    }
    return nil;
}

- (void)reloadIncidents {
    if (self.snapshotStore.snapshotPath == nil) {
        NSString *reason = (self.snapshotStore.loadError != nil)
            ? self.snapshotStore.loadError.localizedDescription : @"No snapshot is loaded.";
        [_headerField setStringValue:@"Incidents unavailable"];
        [_subheaderField setStringValue:[NSString stringWithFormat:
            @"No verified snapshot is loaded (%@). The Incidents lens reads only the verified snapshot.", reason]];
        self.incidents = @[];
        [_queueTable reloadData];
        [self showDetailForIncident:nil detail:nil];
        return;
    }
    NSError *error = nil;
    NSArray<IncidentSummary *> *summaries = [self.snapshotStore incidentSummariesWithError:&error];
    NSArray<SFAction *> *actions = [self.snapshotStore actionsWithError:&error];
    self.actions = (actions != nil) ? actions : @[];
    if (summaries == nil) {
        [_headerField setStringValue:@"Incidents unavailable"];
        [_subheaderField setStringValue:[NSString stringWithFormat:
            @"The incidents query failed: %@.",
            (error != nil) ? error.localizedDescription : @"unknown error"]];
        self.incidents = @[];
        [_queueTable reloadData];
        [self showDetailForIncident:nil detail:nil];
        return;
    }
    if ([summaries count] == 0) {
        self.incidents = @[];
        [_queueTable reloadData];
        [self showDetailForIncident:nil detail:nil];
        [_headerField setStringValue:@"Incidents — none on the record"];
        if ([self manifestActionWithID:IncidentsActionSend] != nil) {
            [_subheaderField setStringValue:
             @"No incident is recorded in this snapshot yet. Incidents arrive from your mail and watches; "
             @"the list is never padded."];
        } else {
            [_subheaderField setStringValue:[NSString stringWithFormat:
             @"This snapshot (%@) predates the incident record. "
             @"Update the snapshot (Sync ▸ Check for Snapshot Update, or Distro) and the lens fills from the record.",
             (self.snapshotVersion != nil) ? self.snapshotVersion : @"unknown version"]];
        }
        return;
    }
    self.incidents = summaries;
    [_queueTable reloadData];
    NSUInteger openCount = 0;
    for (IncidentSummary *incident in summaries) {
        if (!incident.stateIsTerminal) {
            openCount++;
        }
    }
    [_headerField setStringValue:[NSString stringWithFormat:
        @"Incidents — %lu on the record, %lu not closed",
        (unsigned long)[summaries count], (unsigned long)openCount]];
    [_subheaderField setStringValue:
     @"Next open deadline first. Actions are staged on this Mac — nothing is sent without your approval."];
    [self selectIncidentAtRow:([_queueTable selectedRow] >= 0 ? [_queueTable selectedRow] : 0)];
}

- (void)selectIncidentAtRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)[self.incidents count]) {
        self.selectedIncident = nil;
        [self showDetailForIncident:nil detail:nil];
        return;
    }
    IncidentSummary *incident = self.incidents[(NSUInteger)row];
    self.selectedIncident = incident;
    NSError *error = nil;
    IncidentDetail *detail = [self.snapshotStore incidentDetailForKey:incident.key error:&error];
    [self showDetailForIncident:incident detail:detail];
    if (self.incidentActivationHandler != nil) {
        self.incidentActivationHandler(incident);
    }
}

- (void)showDetailForIncident:(IncidentSummary *)incident detail:(IncidentDetail *)detail {
    BOOL hasIncident = (incident != nil);
    for (NSButton *button in @[_draftButton, _sendButton, _phoneButton,
                               _complaintButton, _watchButton]) {
        [button setEnabled:hasIncident];
    }
    if (!hasIncident) {
        [_detailTitleField setStringValue:@""];
        [_detailMetaField setStringValue:@""];
        [_detailSummaryField setStringValue:@""];
        [_deadlineTable reloadData];
        [_assetTable reloadData];
        [_timelineField setStringValue:@""];
        [_statusField setStringValue:@""];
        return;
    }
    [_detailTitleField setStringValue:[NSString stringWithFormat:@"%@ — %@",
                                       incident.key, incident.title]];
    NSMutableString *meta = [NSMutableString stringWithFormat:
        @"State: %@   ·   Severity: %@   ·   Opened: %@\nCounterparty: %@   ·   Source: %@   ·   Assets: %ld",
        incident.stateName, incident.severityName, incident.openedAt,
        (incident.counterpartyName != nil) ? incident.counterpartyName : @"(none)",
        incident.sourceChannel, (long)incident.assetCount];
    if (detail != nil && detail.sourceRef != nil) {
        [meta appendFormat:@"\nSource ref: %@", detail.sourceRef];
    }
    [_detailMetaField setStringValue:meta];
    [_detailSummaryField setStringValue:(detail != nil && detail.summaryText != nil)
        ? detail.summaryText : @""];
    self.currentDetail = detail;
    [_deadlineTable reloadData];
    [_assetTable reloadData];
    if (detail != nil && [detail.timelineEntries count] > 0) {
        [_timelineField setStringValue:[NSString stringWithFormat:@"Timeline (sf_audit_log):\n%@",
                                        [detail.timelineEntries componentsJoinedByString:@"\n"]]];
    } else {
        [_timelineField setStringValue:
         @"Timeline: no sf_audit_log entries for this incident in this snapshot yet. Entries ride the "
         @"next served snapshot after a dispatch on the incident executes — an empty timeline here is a "
         @"fact about the snapshot, not a claim that nothing happened."];
    }
    [_statusField setStringValue:@""];
}

#pragma mark - Table data source / delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == _queueTable) {
        return (NSInteger)[self.incidents count];
    }
    if (tableView == _deadlineTable) {
        return (NSInteger)[self.currentDetail.deadlines count];
    }
    if (tableView == _assetTable) {
        return (NSInteger)[self.currentDetail.assets count];
    }
    return 0;
}

- (id)tableView:(NSTableView *)tableView
objectValueForTableColumn:(NSTableColumn *)tableColumn
            row:(NSInteger)row {
    NSString *identifier = [tableColumn identifier];
    if (tableView == _queueTable) {
        IncidentSummary *incident = self.incidents[(NSUInteger)row];
        if ([identifier isEqualToString:@"key"]) {
            return incident.key;
        }
        if ([identifier isEqualToString:@"severity"]) {
            return incident.severityName;
        }
        if ([identifier isEqualToString:@"state"]) {
            return incident.stateName;
        }
        if ([identifier isEqualToString:@"deadline"]) {
            return (incident.nextDeadlineDue != nil) ? incident.nextDeadlineDue : @"—";
        }
        return @"";
    }
    if (tableView == _deadlineTable) {
        IncidentDeadline *deadline = self.currentDetail.deadlines[(NSUInteger)row];
        if ([identifier isEqualToString:@"due"]) {
            return deadline.dueAt;
        }
        if ([identifier isEqualToString:@"kind"]) {
            return deadline.kind;
        }
        if ([identifier isEqualToString:@"dstate"]) {
            return deadline.state;
        }
        if ([identifier isEqualToString:@"label"]) {
            return deadline.label;
        }
        return @"";
    }
    if (tableView == _assetTable) {
        IncidentAsset *asset = self.currentDetail.assets[(NSUInteger)row];
        if ([identifier isEqualToString:@"atype"]) {
            return asset.assetType;
        }
        if ([identifier isEqualToString:@"alabel"]) {
            return asset.label;
        }
        if ([identifier isEqualToString:@"aref"]) {
            if (asset.messageID != nil) {
                return asset.messageID;
            }
            if (asset.localPath != nil) {
                return asset.localPath;
            }
            return (asset.externalRef != nil) ? asset.externalRef : @"";
        }
        if ([identifier isEqualToString:@"asha"]) {
            return (asset.sha256 != nil) ? asset.sha256 : @"—";
        }
        return @"";
    }
    return @"";
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if ([notification object] == _queueTable) {
        [self selectIncidentAtRow:[_queueTable selectedRow]];
    }
}

- (void)queueDoubleClicked:(id)sender {
    NSInteger row = [_queueTable clickedRow];
    if (row >= 0) {
        [self selectIncidentAtRow:row];
    }
}

#pragma mark - Dispatch buttons (§12.2 actions, access-review confirm)

- (NSDictionary *)buttonActionMap {
    return @{IncidentsActionDraftReply: _draftButton,
             IncidentsActionSend: _sendButton,
             IncidentsActionPhone: _phoneButton,
             IncidentsActionComplaint: _complaintButton,
             IncidentsActionWatchArm: _watchButton};
}

- (void)actionButtonClicked:(id)sender {
    IncidentSummary *incident = self.selectedIncident;
    if (incident == nil) {
        return;
    }
    NSString *actionID = nil;
    NSDictionary *map = [self buttonActionMap];
    for (NSString *key in map) {
        if (map[key] == sender) {
            actionID = key;
            break;
        }
    }
    if (actionID == nil) {
        return;
    }
    SFAction *action = [self manifestActionWithID:actionID];
    if (action == nil || !action.enabled) {
        [_statusField setStringValue:(action != nil)
            ? [NSString stringWithFormat:@"%@ is not available in this snapshot; nothing was staged.", action.name]
            : @"That action is not in this snapshot's action list; nothing was staged."];
        return;
    }
    if (self.dispatchStore == nil) {
        [_statusField setStringValue:@"The action queue is unavailable in this session; nothing was staged."];
        return;
    }

    // Primary copy in the owner's terms (verdict 2026-11-12): the
    // action named plainly, and the one safety fact that matters —
    // staging sends nothing; the email send in particular stays
    // queued until the owner approves it. The full record (action id,
    // lane, store, payload, destination) sits behind Details.
    NSString *plainEffect = nil;
    if ([actionID isEqualToString:IncidentsActionSend]) {
        plainEffect = @"An email about this incident is staged for your approval. It stays in the queue until you approve it — staging sends nothing, and no email leaves any account.";
    } else if ([actionID isEqualToString:IncidentsActionPhone]) {
        plainEffect = @"A call about this incident is staged for your approval. The call is placed only after approval — never by this app.";
    } else if ([actionID isEqualToString:IncidentsActionComplaint]) {
        plainEffect = @"A complaint filing is staged for your approval, prepared from this incident's evidence on the record. Staging files nothing.";
    } else if ([actionID isEqualToString:IncidentsActionWatchArm]) {
        plainEffect = @"A watch on this incident's deadlines and counterparty is staged for your approval. Staging arms nothing.";
    } else if ([actionID isEqualToString:IncidentsActionDraftReply]) {
        plainEffect = @"A reply draft is staged for preparation. Nothing is sent.";
    } else {
        plainEffect = @"This action is staged in the queue on this Mac. Nothing runs and nothing is sent by staging.";
    }
    NSMutableString *details = [NSMutableString stringWithFormat:
        @"Action: %@ (%@)\n"
        @"Lane: ESTATE QUEUE. Confirming records a row in the local dispatch store (%@, table "
        @"local_dispatches) in state “queued”, with payload {\"incident_key\": \"%@\"}. "
        @"Minion/hooks — the estate consumer — execute approved rows; THIS APP EXECUTES NOTHING "
        @"from this queue.\n\n"
        @"Destination / operator (per the manifest): %@\n",
        action.actionID, action.kind, [DispatchStore defaultStorePath], incident.key, action.target];
    if ([actionID isEqualToString:IncidentsActionSend]) {
        [details appendString:
         @"\nOWNER GATE: the manifest marks incident.email.send requires-confirm. This dispatch will "
         @"sit QUEUED until the owner approves it in the Orchestration Queue pane — queueing sends "
         @"nothing, and no email leaves any account by queueing.\n"];
    }
    if ([actionID isEqualToString:IncidentsActionPhone]) {
        [details appendString:
         @"\nThe call itself is placed by the phone lane at execution, after approval — never by this app.\n"];
    }
    if ([actionID isEqualToString:IncidentsActionComplaint]) {
        [details appendString:
         @"\nFiling happens at execution from the incident's asset inventory (the corroboration "
         @"packet). Queueing files nothing.\n"];
    }
    if ([actionID isEqualToString:IncidentsActionWatchArm]) {
        [details appendString:
         @"\nArming registers a watch on the incident's deadlines/counterparty at execution; "
         @"queueing arms nothing.\n"];
    }
    [details appendString:@"\nDeclining stages nothing."];

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:[NSString stringWithFormat:@"%@ — %@?", action.name, incident.key]];
    [alert setInformativeText:plainEffect];
    [alert addButtonWithTitle:@"Stage"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:@"Details…"];

    NSWindow *window = self.view.window;
    if (window == nil) {
        return;
    }
    __weak IncidentsViewController *weakSelf = self;
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse result) {
        if (result == NSAlertThirdButtonReturn) {
            NSAlert *detailsAlert = [[NSAlert alloc] init];
            [detailsAlert setMessageText:@"Details"];
            [detailsAlert setInformativeText:details];
            [detailsAlert addButtonWithTitle:@"Back"];
            [detailsAlert addButtonWithTitle:@"Cancel"];
            [detailsAlert beginSheetModalForWindow:window completionHandler:^(NSModalResponse back) {
                if (back == NSAlertFirstButtonReturn) {
                    [weakSelf actionButtonClicked:sender];
                }
            }];
            return;
        }
        if (result != NSAlertFirstButtonReturn) {
            return;
        }
        NSError *error = nil;
        int64_t dispatchID = [weakSelf.dispatchStore enqueueDispatchWithActionID:actionID
                                                                     incidentKey:incident.key
                                                                    extraPayload:nil
                                                                           error:&error];
        if (dispatchID < 0) {
            [weakSelf.statusField setStringValue:[NSString stringWithFormat:
                @"Not staged: %@.",
                (error != nil) ? error.localizedDescription : @"unknown error"]];
            return;
        }
        [weakSelf.statusField setStringValue:[NSString stringWithFormat:
            @"Staged for %@ — see View ▸ Orchestration (⌘5), Queue pane.",
            incident.key]];
        if (weakSelf.dispatchEnqueuedHandler != nil) {
            weakSelf.dispatchEnqueuedHandler((NSInteger)dispatchID, actionID);
        }
    }];
}


#pragma mark - Cell tooltips (the full value behind any truncated cell)

- (NSString *)tableView:(NSTableView *)tableView toolTipForCell:(NSCell *)cell rect:(NSRectPointer)rect tableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row mouseLocation:(NSPoint)mouseLocation {
    id value = [self tableView:tableView objectValueForTableColumn:tableColumn row:row];
    return ([value isKindOfClass:[NSString class]] && [value length] > 0) ? value : nil;
}

@end
