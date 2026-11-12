#import "OrchestrationViewController.h"
#import "SnapshotStore.h"
#import "DispatchStore.h"
#import "WriteBackQueue.h"
#import "GitHubProjectsClient.h"
#import "SFAction.h"
#import "DeployTarget.h"
#import "BoardSummary.h"
#import "BoardItem.h"
#import "StatusField.h"

// Field kinds the composer generates from a schema key + type.
static NSString * const FieldKindText = @"text";            // "string"
static NSString * const FieldKindInteger = @"integer";      // "integer"
static NSString * const FieldKindArray = @"array";          // "array" (comma-separated in the form)
static NSString * const FieldKindObject = @"object";        // "object" (JSON text in the form)
static NSString * const FieldKindChoices = @"choices";      // "a|b|c" union in the schema
static NSString * const FieldKindLiteral = @"literal";      // schema value is a literal (e.g. "proxy720")
static NSString * const FieldKindBoard = @"board";          // key "board" → snapshot boards
static NSString * const FieldKindItem = @"item";            // key "item" → selected board's items
static NSString * const FieldKindStatus = @"status";        // key "status" → selected board's Status options
static NSString * const FieldKindTarget = @"target";        // key "target_id" → sf_deploy_targets

@interface OrchestrationViewController () <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>
@property (nonatomic, strong, readwrite) SnapshotStore *snapshotStore;
@property (nonatomic, strong, readwrite, nullable) DispatchStore *dispatchStore;
@property (nonatomic, strong, readwrite, nullable) WriteBackQueue *writeBackQueue;

// Data (reloaded by reloadOrchestration)
@property (nonatomic, copy) NSArray<SFAction *> *actions;
@property (nonatomic, copy) NSArray<BoardSummary *> *boards;
@property (nonatomic, copy) NSArray<DeployTarget *> *deployTargets;
@property (nonatomic, copy) NSArray<LocalDispatch *> *dispatchRows;
@property (nonatomic, copy) NSArray<LocalAuditEntry *> *auditRows;
@property (nonatomic, strong, nullable) SFAction *selectedAction;
@property (nonatomic, copy) NSArray<NSMutableDictionary *> *fields;  // composer field descriptors

// Panes
@property (nonatomic, strong) NSTextField *headerField;
@property (nonatomic, strong) NSTableView *manifestTable;
@property (nonatomic, strong) NSTextView *schemaView;
@property (nonatomic, strong) NSPopUpButton *actionPopup;
@property (nonatomic, strong) NSTextField *laneField;
@property (nonatomic, strong) NSTextField *preconditionField;
@property (nonatomic, strong) NSView *fieldsContainer;
@property (nonatomic, strong) NSTextField *disabledNoteField;
@property (nonatomic, strong) NSTextField *validationField;
@property (nonatomic, strong) NSTextField *previewLabel;
@property (nonatomic, strong) NSTextView *previewView;
@property (nonatomic, strong) NSButton *enqueueButton;
@property (nonatomic, strong) NSTableView *queueTable;
@property (nonatomic, strong) NSPopUpButton *stateFilterPopup;
@property (nonatomic, strong) NSButton *cancelButton;
@property (nonatomic, strong) NSTableView *auditTable;
@end

@implementation OrchestrationViewController

- (instancetype)initWithSnapshotStore:(SnapshotStore *)snapshotStore
                        dispatchStore:(DispatchStore *)dispatchStore
                       writeBackQueue:(WriteBackQueue *)writeBackQueue {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _snapshotStore = snapshotStore;
        _dispatchStore = dispatchStore;
        _writeBackQueue = writeBackQueue;
        _actions = @[];
        _boards = @[];
        _deployTargets = @[];
        _dispatchRows = @[];
        _auditRows = @[];
        _fields = @[];
    }
    return self;
}

#pragma mark - View construction

- (NSTextField *)sectionLabel:(NSString *)text frame:(NSRect)frame {
    NSTextField *label = [NSTextField labelWithString:text];
    [label setFont:[NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]];
    [label setTextColor:[NSColor secondaryLabelColor]];
    [label setFrame:frame];
    return label;
}

- (NSTableView *)tableWithColumns:(NSArray<NSArray *> *)columns {
    NSTableView *table = [[NSTableView alloc] init];
    [table setDataSource:self];
    [table setDelegate:self];
    [table setUsesAlternatingRowBackgroundColors:YES];
    [table setRowHeight:20];
    [table setAllowsMultipleSelection:NO];
    for (NSArray *spec in columns) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:spec[0]];
        [[column headerCell] setStringValue:spec[1]];
        [column setWidth:[spec[2] doubleValue]];
        [table addTableColumn:column];
    }
    return table;
}

- (NSScrollView *)scrollViewForTable:(NSTableView *)table frame:(NSRect)frame {
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:frame];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setBorderType:NSBezelBorder];
    [scrollView setDocumentView:table];
    return scrollView;
}

- (NSScrollView *)scrollViewForTextView:(NSTextView *)textView frame:(NSRect)frame {
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:frame];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setBorderType:NSBezelBorder];
    [scrollView setDocumentView:textView];
    return scrollView;
}

- (NSTextView *)readOnlyTextView {
    NSTextView *textView = [[NSTextView alloc] init];
    [textView setEditable:NO];
    [textView setFont:[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular]];
    [textView setTextContainerInset:NSMakeSize(6, 6)];
    return textView;
}

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1180, 720)];

    _headerField = [NSTextField labelWithString:@""];
    [_headerField setFont:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]];
    [_headerField setFrame:NSMakeRect(16, 690, 1148, 18)];
    [_headerField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:_headerField];

    // — Pane (a): Action Manifest (left column) —
    [root addSubview:[self sectionLabel:@"ACTION MANIFEST — sf_actions (data, not code)"
                                 frame:NSMakeRect(16, 660, 470, 14)]];
    _manifestTable = [self tableWithColumns:@[
        @[@"name", @"Action", @164],
        @[@"kind", @"Kind", @92],
        @[@"risk", @"Risk", @46],
        @[@"confirm", @"Confirm", @62],
        @[@"enabled", @"On", @44],
    ]];
    [root addSubview:[self scrollViewForTable:_manifestTable frame:NSMakeRect(16, 452, 470, 204)]];

    [root addSubview:[self sectionLabel:@"SELECTED ACTION — target + payload schema, verbatim"
                                 frame:NSMakeRect(16, 428, 470, 14)]];
    _schemaView = [self readOnlyTextView];
    [root addSubview:[self scrollViewForTextView:_schemaView frame:NSMakeRect(16, 268, 470, 156)]];

    // — Pane (b): Dispatch Composer (right column) —
    [root addSubview:[self sectionLabel:@"DISPATCH COMPOSER — form generated from payload_schema_json"
                                 frame:NSMakeRect(502, 660, 662, 14)]];
    _actionPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(502, 626, 662, 26) pullsDown:NO];
    [_actionPopup setTarget:self];
    [_actionPopup setAction:@selector(actionPopupChanged:)];
    [root addSubview:_actionPopup];

    _laneField = [NSTextField labelWithString:@""];
    [_laneField setFont:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]];
    [_laneField setFrame:NSMakeRect(502, 600, 662, 18)];
    [root addSubview:_laneField];

    _preconditionField = [NSTextField labelWithString:@""];
    [_preconditionField setFont:[NSFont systemFontOfSize:12]];
    [_preconditionField setTextColor:[NSColor secondaryLabelColor]];
    [[_preconditionField cell] setWraps:YES];
    [_preconditionField setFrame:NSMakeRect(502, 556, 662, 40)];
    [root addSubview:_preconditionField];

    _fieldsContainer = [[NSView alloc] initWithFrame:NSMakeRect(502, 402, 662, 150)];
    [root addSubview:_fieldsContainer];

    _disabledNoteField = [NSTextField labelWithString:@""];
    [_disabledNoteField setFont:[NSFont systemFontOfSize:12]];
    [[_disabledNoteField cell] setWraps:YES];
    [_disabledNoteField setFrame:NSMakeRect(502, 402, 662, 40)];
    [root addSubview:_disabledNoteField];

    _validationField = [NSTextField labelWithString:@""];
    [_validationField setFont:[NSFont systemFontOfSize:12]];
    [_validationField setFrame:NSMakeRect(502, 378, 520, 18)];
    [root addSubview:_validationField];

    _enqueueButton = [[NSButton alloc] initWithFrame:NSMakeRect(1034, 374, 130, 28)];
    [_enqueueButton setTitle:@"Enqueue…"];
    [_enqueueButton setBezelStyle:NSBezelStyleRounded];
    [_enqueueButton setTarget:self];
    [_enqueueButton setAction:@selector(enqueueClicked:)];
    [root addSubview:_enqueueButton];

    _previewLabel = [NSTextField labelWithString:@"Payload (live) — exactly what will be stored"];
    [_previewLabel setFont:[NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]];
    [_previewLabel setTextColor:[NSColor secondaryLabelColor]];
    [_previewLabel setFrame:NSMakeRect(502, 352, 662, 14)];
    [root addSubview:_previewLabel];

    _previewView = [self readOnlyTextView];
    [root addSubview:[self scrollViewForTextView:_previewView frame:NSMakeRect(502, 268, 662, 80)]];

    // — Pane (c): Dispatch Queue + Audit (bottom band) —
    [root addSubview:[self sectionLabel:@"DISPATCH QUEUE — estate lane (local_dispatches)"
                                 frame:NSMakeRect(16, 240, 320, 14)]];
    _stateFilterPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(330, 234, 130, 22) pullsDown:NO];
    [_stateFilterPopup setTarget:self];
    [_stateFilterPopup setAction:@selector(stateFilterChanged:)];
    [root addSubview:_stateFilterPopup];

    _cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(466, 233, 126, 24)];
    [_cancelButton setTitle:@"Cancel Staged Action"];
    [_cancelButton setBezelStyle:NSBezelStyleRounded];
    [_cancelButton setTarget:self];
    [_cancelButton setAction:@selector(cancelClicked:)];
    [root addSubview:_cancelButton];

    _queueTable = [self tableWithColumns:@[
        @[@"id", @"#", @28],
        @[@"action", @"Action", @132],
        @[@"state", @"State", @70],
        @[@"payload", @"Payload", @168],
        @[@"queued", @"Queued", @150],
    ]];
    [root addSubview:[self scrollViewForTable:_queueTable frame:NSMakeRect(16, 16, 576, 212)]];

    [root addSubview:[self sectionLabel:@"AUDIT — dispatch events (local_audit_log)"
                                 frame:NSMakeRect(608, 240, 430, 14)]];
    NSButton *refreshButton = [[NSButton alloc] initWithFrame:NSMakeRect(1064, 233, 100, 24)];
    [refreshButton setTitle:@"Refresh"];
    [refreshButton setBezelStyle:NSBezelStyleRounded];
    [refreshButton setTarget:self];
    [refreshButton setAction:@selector(refreshClicked:)];
    [root addSubview:refreshButton];

    _auditTable = [self tableWithColumns:@[
        @[@"ts", @"Time", @150],
        @[@"action", @"Action", @110],
        @[@"object", @"Object", @130],
        @[@"after", @"After", @150],
    ]];
    [root addSubview:[self scrollViewForTable:_auditTable frame:NSMakeRect(608, 16, 556, 212)]];

    self.view = root;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self reloadOrchestration];
}

#pragma mark - Lane rules (D6, as built in SF-T5)

+ (BOOL)actionUsesGitHubLane:(SFAction *)action {
    // GITHUB LANE (via the SF-T4 WriteBackQueue) is taken ONLY by a
    // manifest action that maps exactly onto one of the three D3
    // write-back operations. In this build exactly one does:
    // gh.project.move_item → status_move (same translation the Board's
    // Status popup performs: board/item/status display values resolve
    // through StatusField to the GitHub field/option IDs the queue
    // payload carries). The other GitHub-kind seeds do NOT map, and take
    // the estate lane for SF-T6's consumer instead:
    //   gh.workflow.dispatch — workflow dispatch is not a D3 operation
    //     (and the task fences it to the estate lane explicitly);
    //   gh.project.add_item — addProjectV2ItemById ships in the client
    //     but is NOT a D3 queue kind (the queue schema's CHECK refuses
    //     a fourth kind);
    //   gh.issue.create — a repository issue via REST is a different
    //     operation from D3's create_item (a draft issue on a board);
    //   gh.issue.comment — D3 comment rows are anchored to a board item
    //     (the send path resolves the issue from the item's own snapshot
    //     record); this manifest payload names a repo issue directly
    //     with no board anchor, and silently inventing one is exactly
    //     what design §3's ambiguity protocol forbids.
    return [action.actionID isEqualToString:@"gh.project.move_item"];
}

+ (NSString *)laneNameForAction:(SFAction *)action {
    return [self actionUsesGitHubLane:action]
        ? @"GitHub lane — SF-T4 write-back queue"
        : @"Estate lane — local dispatch queue (executed by Minion/hooks, SF-T6)";
}

#pragma mark - Reload

- (void)reloadOrchestration {
    NSError *error = nil;
    if (self.snapshotStore.snapshotPath != nil) {
        NSArray<SFAction *> *actions = [self.snapshotStore actionsWithError:&error];
        self.actions = (actions != nil) ? actions : @[];
        NSArray<BoardSummary *> *boards = [self.snapshotStore portfolioBoardsWithError:&error];
        self.boards = (boards != nil) ? boards : @[];
        NSArray<DeployTarget *> *targets = [self.snapshotStore deployTargetsWithError:&error];
        self.deployTargets = (targets != nil) ? targets : @[];
    } else {
        self.actions = @[];
        self.boards = @[];
        self.deployTargets = @[];
    }
    if (self.dispatchStore != nil) {
        NSArray<LocalDispatch *> *rows = [self.dispatchStore allDispatchesWithError:&error];
        self.dispatchRows = (rows != nil) ? rows : @[];
        NSArray<LocalAuditEntry *> *audit = [self.dispatchStore dispatchAuditEntriesWithError:&error];
        self.auditRows = (audit != nil) ? audit : @[];
    } else {
        self.dispatchRows = @[];
        self.auditRows = @[];
    }

    NSInteger queued = (self.dispatchStore != nil) ? [self.dispatchStore queuedCount] : 0;
    [_headerField setStringValue:[NSString stringWithFormat:
                                  @"Orchestration Center — %lu manifest action(s) · %ld dispatch(es) queued · snapshot %@",
                                  (unsigned long)[self.actions count], (long)queued,
                                  (self.snapshotStore.snapshotVersion != nil)
                                      ? self.snapshotStore.snapshotVersion : @"(none loaded)"]];

    [_manifestTable reloadData];

    // Action popup mirrors the manifest (disabled actions are visible
    // but their popup items are disabled — shown, never composable).
    [_actionPopup removeAllItems];
    for (SFAction *action in self.actions) {
        [_actionPopup addItemWithTitle:[NSString stringWithFormat:@"%@ — %@", action.actionID, action.name]];
        NSMenuItem *item = [_actionPopup lastItem];
        [item setRepresentedObject:action.actionID];
        if (!action.enabled) {
            [item setEnabled:NO];
        }
    }

    // Keep the current selection where possible; otherwise default to
    // the first enabled action (or the first row, so its struck state
    // and schema are what the pane explains).
    SFAction *keep = nil;
    for (SFAction *action in self.actions) {
        if (self.selectedAction != nil && [action.actionID isEqualToString:self.selectedAction.actionID]) {
            keep = action;
            break;
        }
    }
    if (keep == nil) {
        for (SFAction *action in self.actions) {
            if (action.enabled) {
                keep = action;
                break;
            }
        }
    }
    if (keep == nil && [self.actions count] > 0) {
        keep = self.actions[0];
    }
    [self selectAction:keep syncManifest:YES];

    // State filter popup: All + the six states.
    if ([_stateFilterPopup numberOfItems] == 0) {
        [_stateFilterPopup addItemWithTitle:@"All states"];
        [[_stateFilterPopup lastItem] setRepresentedObject:@""];
        for (NSString *state in DispatchAllStates()) {
            [_stateFilterPopup addItemWithTitle:state];
            [[_stateFilterPopup lastItem] setRepresentedObject:state];
        }
    }
    [self refreshQueuePane];
}

- (void)refreshQueuePane {
    [_queueTable reloadData];
    [_auditTable reloadData];
    // Cancel arms exactly when the selected queue row is queued.
    NSInteger row = [_queueTable selectedRow];
    BOOL canCancel = NO;
    if (row >= 0) {
        NSArray<LocalDispatch *> *visible = [self visibleDispatches];
        if (row < (NSInteger)[visible count]) {
            canCancel = [visible[(NSUInteger)row].state isEqualToString:DispatchStateQueued];
        }
    }
    [_cancelButton setEnabled:canCancel];
}

- (NSArray<LocalDispatch *> *)visibleDispatches {
    NSString *filter = [[_stateFilterPopup selectedItem] representedObject];
    if (filter == nil || [filter length] == 0) {
        return self.dispatchRows;
    }
    NSMutableArray<LocalDispatch *> *visible = [NSMutableArray array];
    for (LocalDispatch *dispatch in self.dispatchRows) {
        if ([dispatch.state isEqualToString:filter]) {
            [visible addObject:dispatch];
        }
    }
    return visible;
}

#pragma mark - Manifest selection

- (void)selectAction:(SFAction *)action syncManifest:(BOOL)syncManifest {
    self.selectedAction = action;
    if (action == nil) {
        [_schemaView setString:@""];
        [self rebuildForm];
        return;
    }
    [_schemaView setString:[NSString stringWithFormat:@"%@\nid: %@\nkind: %@ · risk: %@ · requires_confirm: %@ · enabled: %@\n\n%@",
                            action.target, action.actionID, action.kind, action.riskClass,
                            action.requiresConfirm ? @"yes" : @"no",
                            action.enabled ? @"yes" : @"no",
                            action.payloadSchemaJSON]];
    if (syncManifest) {
        NSUInteger index = [self.actions indexOfObject:action];
        if (index != NSNotFound) {
            [_manifestTable selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
        }
    }
    NSUInteger popupIndex = [[_actionPopup itemTitles] indexOfObjectPassingTest:^BOOL(NSString *title, NSUInteger idx, BOOL *stop) {
        return [[[_actionPopup itemAtIndex:idx] representedObject] isEqualToString:action.actionID];
    }];
    if (popupIndex != NSNotFound) {
        [_actionPopup selectItemAtIndex:(NSInteger)popupIndex];
    }
    [self rebuildForm];
}

- (void)selectActionWithID:(NSString *)actionID {
    // SF-T7 palette seam: resolve the id against the loaded manifest and
    // run the same selection path the manifest table and popup use.
    for (SFAction *action in self.actions) {
        if ([action.actionID isEqualToString:actionID]) {
            [self selectAction:action syncManifest:YES];
            return;
        }
    }
}

- (void)actionPopupChanged:(id)sender {
    NSString *actionID = [[_actionPopup selectedItem] representedObject];
    for (SFAction *action in self.actions) {
        if ([action.actionID isEqualToString:actionID]) {
            [self selectAction:action syncManifest:YES];
            return;
        }
    }
}

#pragma mark - Composer form generation

- (NSString *)fieldKindForKey:(NSString *)key type:(NSString *)type {
    if ([key isEqualToString:@"board"]) {
        return FieldKindBoard;
    }
    if ([key isEqualToString:@"item"]) {
        return FieldKindItem;
    }
    if ([key isEqualToString:@"status"]) {
        return FieldKindStatus;
    }
    if ([key isEqualToString:@"target_id"]) {
        return FieldKindTarget;
    }
    if ([type containsString:@"|"]) {
        return FieldKindChoices;
    }
    if ([type isEqualToString:@"string"]) {
        return FieldKindText;
    }
    if ([type isEqualToString:@"integer"]) {
        return FieldKindInteger;
    }
    if ([type isEqualToString:@"array"]) {
        return FieldKindArray;
    }
    if ([type isEqualToString:@"object"]) {
        return FieldKindObject;
    }
    // Anything else in the type slot is the schema naming a literal
    // value (e.g. "profile": "proxy720") — prefilled, still editable.
    return FieldKindLiteral;
}

- (NSPopUpButton *)popupInContainer:(NSView *)container frame:(NSRect)frame {
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:frame pullsDown:NO];
    [popup setTarget:self];
    [popup setAction:@selector(fieldChanged:)];
    [container addSubview:popup];
    return popup;
}

- (void)populateBoardPopup:(NSPopUpButton *)popup {
    [popup removeAllItems];
    for (BoardSummary *board in self.boards) {
        [popup addItemWithTitle:[NSString stringWithFormat:@"%@ #%lld — %@",
                                 board.ownerType, (long long)board.number, board.title]];
        [[popup lastItem] setRepresentedObject:board.nodeID];
    }
}

- (void)populateTargetPopup:(NSPopUpButton *)popup {
    [popup removeAllItems];
    for (DeployTarget *target in self.deployTargets) {
        [popup addItemWithTitle:target.displayName];
        [[popup lastItem] setRepresentedObject:target.targetID];
    }
}

- (NSString *)selectedBoardNodeID {
    for (NSMutableDictionary *field in self.fields) {
        if ([field[@"kind"] isEqualToString:FieldKindBoard]) {
            NSPopUpButton *popup = field[@"control"];
            return [[popup selectedItem] representedObject];
        }
    }
    return nil;
}

- (void)populateBoardDependentPopups {
    NSString *boardID = [self selectedBoardNodeID];
    NSArray<BoardItem *> *items = @[];
    NSArray<NSString *> *statuses = @[];
    if (boardID != nil) {
        NSError *error = nil;
        NSArray<BoardItem *> *fetched = [self.snapshotStore itemsForBoard:boardID error:&error];
        items = (fetched != nil) ? fetched : @[];
        NSArray<NSString *> *fetchedStatuses = [self.snapshotStore statusOptionsForBoard:boardID error:&error];
        statuses = (fetchedStatuses != nil) ? fetchedStatuses : @[];
    }
    for (NSMutableDictionary *field in self.fields) {
        if ([field[@"kind"] isEqualToString:FieldKindItem]) {
            NSPopUpButton *popup = field[@"control"];
            NSString *keep = [[popup selectedItem] representedObject];
            [popup removeAllItems];
            for (BoardItem *item in items) {
                [popup addItemWithTitle:item.title];
                [[popup lastItem] setRepresentedObject:item.nodeID];
            }
            if (keep != nil) {
                for (NSMenuItem *menuItem in [popup itemArray]) {
                    if ([[menuItem representedObject] isEqualToString:keep]) {
                        [popup selectItem:menuItem];
                        break;
                    }
                }
            }
            field[@"items"] = items;
        }
        if ([field[@"kind"] isEqualToString:FieldKindStatus]) {
            NSPopUpButton *popup = field[@"control"];
            NSString *keep = [[popup selectedItem] representedObject];
            [popup removeAllItems];
            for (NSString *status in statuses) {
                [popup addItemWithTitle:status];
                [[popup lastItem] setRepresentedObject:status];
            }
            if (keep != nil && [statuses containsObject:keep]) {
                [popup selectItemWithTitle:keep];
            }
        }
    }
}

- (void)rebuildForm {
    for (NSView *subview in [[_fieldsContainer subviews] copy]) {
        [subview removeFromSuperview];
    }
    NSMutableArray<NSMutableDictionary *> *fields = [NSMutableArray array];
    self.fields = fields;

    SFAction *action = self.selectedAction;
    BOOL composable = (action != nil && action.enabled);
    [_disabledNoteField setStringValue:composable ? @"" :
        (action == nil ? @"No manifest action is selected."
                       : @"This action is DISABLED in the manifest (enabled = 0). It is shown struck in the manifest and cannot be composed or queued.")];
    [_fieldsContainer setHidden:!composable];
    [_enqueueButton setEnabled:composable];

    if (action != nil) {
        [_laneField setStringValue:[NSString stringWithFormat:@"Lane: %@",
                                    [[self class] laneNameForAction:action]]];
        [_preconditionField setStringValue:[self preconditionTextForAction:action]];
    } else {
        [_laneField setStringValue:@""];
        [_preconditionField setStringValue:@""];
    }
    if (!composable) {
        [_previewView setString:@""];
        [_validationField setStringValue:@""];
        return;
    }

    NSDictionary *schema = action.payloadSchema;
    NSArray<NSString *> *keys = action.schemaKeysInOrder;
    CGFloat containerHeight = [_fieldsContainer frame].size.height;
    NSUInteger rowIndex = 0;
    for (NSString *key in keys) {
        NSString *type = schema[key];
        if (![type isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *kind = [self fieldKindForKey:key type:type];
        CGFloat rowY = containerHeight - 30.0 * (CGFloat)(rowIndex + 1) + 4.0;

        NSTextField *label = [NSTextField labelWithString:
                              [NSString stringWithFormat:@"%@ (%@)", key, type]];
        [label setFont:[NSFont systemFontOfSize:12]];
        [label setAlignment:NSTextAlignmentRight];
        [label setFrame:NSMakeRect(0, rowY + 3, 150, 18)];
        [_fieldsContainer addSubview:label];

        NSRect controlFrame = NSMakeRect(158, rowY, 504, 24);
        NSMutableDictionary *field = [@{@"key": key, @"type": type, @"kind": kind} mutableCopy];
        if ([kind isEqualToString:FieldKindBoard] ||
            [kind isEqualToString:FieldKindItem] ||
            [kind isEqualToString:FieldKindStatus] ||
            [kind isEqualToString:FieldKindTarget] ||
            [kind isEqualToString:FieldKindChoices]) {
            NSPopUpButton *popup = [self popupInContainer:_fieldsContainer frame:controlFrame];
            if ([kind isEqualToString:FieldKindBoard]) {
                [self populateBoardPopup:popup];
            } else if ([kind isEqualToString:FieldKindTarget]) {
                [self populateTargetPopup:popup];
            } else if ([kind isEqualToString:FieldKindChoices]) {
                for (NSString *choice in [type componentsSeparatedByString:@"|"]) {
                    NSString *trimmed = [choice stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    [popup addItemWithTitle:trimmed];
                    [[popup lastItem] setRepresentedObject:trimmed];
                }
            }
            field[@"control"] = popup;
        } else {
            NSTextField *textField = [[NSTextField alloc] initWithFrame:controlFrame];
            [textField setDelegate:self];
            if ([kind isEqualToString:FieldKindLiteral]) {
                [textField setStringValue:type];
            }
            if ([kind isEqualToString:FieldKindArray]) {
                [textField setPlaceholderString:@"comma-separated"];
            }
            if ([kind isEqualToString:FieldKindObject]) {
                [textField setPlaceholderString:@"JSON object, e.g. {}"];
            }
            [_fieldsContainer addSubview:textField];
            field[@"control"] = textField;
        }
        [fields addObject:field];
        rowIndex++;
    }
    [self populateBoardDependentPopups];
    [self updatePreview];
}

- (NSString *)preconditionTextForAction:(SFAction *)action {
    if ([action.kind isEqualToString:@"media_deploy"] ||
        [action.actionID isEqualToString:@"signal.publish.linkedin"]) {
        return @"Deploy precondition (standing): Henchman P1–P5 ALL PASS at execution. "
               @"Review verdict: not connected in this build — no verdict is read or claimed here; "
               @"the verdict source arrives with SF-T6 and the estate consumer enforces the precondition.";
    }
    if ([action.kind isEqualToString:@"media_convert"]) {
        return @"Conversion runs on the estate conversion pipeline (ffmpeg) when the estate consumer "
               @"executes the dispatch (SF-T6). Queueing starts nothing.";
    }
    return @"";
}

#pragma mark - Payload harvest + preview

- (id)harvestValueForField:(NSMutableDictionary *)field invalid:(NSString **)invalid {
    NSString *key = field[@"key"];
    NSString *kind = field[@"kind"];
    NSControl *control = field[@"control"];
    if ([control isKindOfClass:[NSPopUpButton class]]) {
        id value = [[(NSPopUpButton *)control selectedItem] representedObject];
        if (value == nil) {
            *invalid = [NSString stringWithFormat:@"%@: nothing selectable in this snapshot", key];
            return nil;
        }
        return value;
    }
    NSString *text = [[(NSTextField *)control stringValue]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([kind isEqualToString:FieldKindInteger]) {
        if ([text length] == 0) {
            *invalid = [NSString stringWithFormat:@"%@: an integer is required", key];
            return nil;
        }
        NSScanner *scanner = [NSScanner scannerWithString:text];
        long long number = 0;
        if (![scanner scanLongLong:&number] || ![scanner isAtEnd]) {
            *invalid = [NSString stringWithFormat:@"%@: “%@” is not an integer", key, text];
            return nil;
        }
        return @(number);
    }
    if ([kind isEqualToString:FieldKindArray]) {
        if ([text length] == 0) {
            *invalid = [NSString stringWithFormat:@"%@: at least one entry is required (comma-separated)", key];
            return nil;
        }
        NSMutableArray<NSString *> *entries = [NSMutableArray array];
        for (NSString *piece in [text componentsSeparatedByString:@","]) {
            NSString *trimmed = [piece stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([trimmed length] > 0) {
                [entries addObject:trimmed];
            }
        }
        if ([entries count] == 0) {
            *invalid = [NSString stringWithFormat:@"%@: at least one entry is required", key];
            return nil;
        }
        return entries;
    }
    if ([kind isEqualToString:FieldKindObject]) {
        if ([text length] == 0) {
            *invalid = [NSString stringWithFormat:@"%@: a JSON object is required ({} is a valid object)", key];
            return nil;
        }
        id parsed = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding]
                                                    options:0
                                                      error:NULL];
        if (![parsed isKindOfClass:[NSDictionary class]]) {
            *invalid = [NSString stringWithFormat:@"%@: not a JSON object", key];
            return nil;
        }
        return parsed;
    }
    // text / literal
    if ([text length] == 0) {
        *invalid = [NSString stringWithFormat:@"%@: a value is required — the manifest schema names no optional keys, so nothing is defaulted silently", key];
        return nil;
    }
    return text;
}

// The manifest-shaped payload (schema keys, harvested values), or nil
// with *invalidMessage set to the first problem.
- (NSDictionary *)buildManifestPayload:(NSString **)invalidMessage {
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    for (NSMutableDictionary *field in self.fields) {
        NSString *invalid = nil;
        id value = [self harvestValueForField:field invalid:&invalid];
        if (invalid != nil) {
            if (invalidMessage != NULL) {
                *invalidMessage = invalid;
            }
            return nil;
        }
        payload[field[@"key"]] = value;
    }
    return payload;
}

// For the one GitHub-lane action: translate the manifest payload into
// the SF-T4 write-back payload (GitHub field/option IDs via StatusField,
// display keys for the Queue panel — the same shape AppDelegate's Board
// flow enqueues). Returns nil + message when translation is impossible.
- (NSDictionary *)writeBackPayloadForManifestPayload:(NSDictionary *)manifestPayload
                                             message:(NSString **)message {
    NSString *boardID = manifestPayload[@"board"];
    NSString *itemID = manifestPayload[@"item"];
    NSString *statusName = manifestPayload[@"status"];
    NSError *error = nil;
    StatusField *statusField = [self.snapshotStore statusFieldForBoard:boardID error:&error];
    StatusOptionRef *option = [statusField optionWithName:statusName];
    if (statusField == nil || option == nil) {
        if (message != NULL) {
            *message = [NSString stringWithFormat:
                        @"The snapshot carries no Status field/option IDs for this board (%@); the move cannot be translated for the write-back queue.",
                        (error != nil) ? error.localizedDescription : @"option not found"];
        }
        return nil;
    }
    BoardItem *item = [self selectedItemForNodeID:itemID];
    return @{
        @"field_id": statusField.ghFieldID,
        @"option_id": option.ghOptionID,
        @"option_name": statusName,
        @"from_option_name": (item != nil && item.statusName != nil) ? item.statusName : [NSNull null],
        @"item_title": (item != nil) ? item.title : @"",
    };
}

- (BoardItem *)selectedItemForNodeID:(NSString *)nodeID {
    for (NSMutableDictionary *field in self.fields) {
        if ([field[@"kind"] isEqualToString:FieldKindItem]) {
            for (BoardItem *item in (NSArray<BoardItem *> *)field[@"items"]) {
                if ([item.nodeID isEqualToString:nodeID]) {
                    return item;
                }
            }
        }
    }
    return nil;
}

// The payload EXACTLY as it will be stored by the enqueue, in whichever
// store the action's lane uses — the preview and the confirm sheet both
// render this, so what is shown is what is queued (envelope≠payload).
- (NSDictionary *)buildStorablePayload:(NSString **)invalidMessage {
    NSDictionary *manifestPayload = [self buildManifestPayload:invalidMessage];
    if (manifestPayload == nil) {
        return nil;
    }
    if ([[self class] actionUsesGitHubLane:self.selectedAction]) {
        NSString *message = nil;
        NSDictionary *translated = [self writeBackPayloadForManifestPayload:manifestPayload message:&message];
        if (translated == nil) {
            if (invalidMessage != NULL) {
                *invalidMessage = message;
            }
            return nil;
        }
        return translated;
    }
    return manifestPayload;
}

- (NSString *)prettyJSONForObject:(id)object {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:NULL];
    return (data != nil) ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
}

- (void)updatePreview {
    if (self.selectedAction == nil || !self.selectedAction.enabled) {
        return;
    }
    NSString *invalid = nil;
    NSDictionary *payload = [self buildStorablePayload:&invalid];
    if (payload != nil) {
        [_validationField setStringValue:@""];
        [_previewLabel setStringValue:[[self class] actionUsesGitHubLane:self.selectedAction]
            ? @"Payload (live) — exactly what will be stored in the write-back queue"
            : @"Payload (live) — exactly what will be stored in local_dispatches"];
        [_previewView setString:[self prettyJSONForObject:payload]];
        [_enqueueButton setEnabled:YES];
    } else {
        [_validationField setStringValue:(invalid != nil) ? invalid : @""];
        [_previewLabel setStringValue:@"Payload (live) — incomplete"];
        [_previewView setString:@""];
        [_enqueueButton setEnabled:NO];
    }
}

- (void)fieldChanged:(id)sender {
    // A board change refills the item + status dropdowns (they are the
    // selected board's own rows/vocabulary), then everything re-previews.
    for (NSMutableDictionary *field in self.fields) {
        if (field[@"control"] == sender && [field[@"kind"] isEqualToString:FieldKindBoard]) {
            [self populateBoardDependentPopups];
            break;
        }
    }
    [self updatePreview];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    [self updatePreview];
}

#pragma mark - Confirm + enqueue

- (void)enqueueClicked:(id)sender {
    SFAction *action = self.selectedAction;
    if (action == nil || !action.enabled) {
        return;
    }
    NSString *invalid = nil;
    NSDictionary *storable = [self buildStorablePayload:&invalid];
    if (storable == nil) {
        [_validationField setStringValue:(invalid != nil) ? invalid : @""];
        return;
    }
    BOOL githubLane = [[self class] actionUsesGitHubLane:action];
    NSDictionary *manifestPayload = [self buildManifestPayload:NULL];
    NSString *payloadJSON = [self prettyJSONForObject:storable];
    NSString *precondition = [self preconditionTextForAction:action];

    __weak OrchestrationViewController *weakSelf = self;
    NSAlert *alert = [[NSAlert alloc] init];
    NSString *details = nil;
    if (githubLane) {
        BoardItem *item = [self selectedItemForNodeID:manifestPayload[@"item"]];
        NSString *itemTitle = (item != nil) ? item.title : @"(item)";
        NSString *fromStatus = (item != nil && item.statusName != nil) ? item.statusName : @"(no status)";
        [alert setMessageText:[NSString stringWithFormat:@"Move “%@” to %@?", itemTitle, manifestPayload[@"status"]]];
        [alert setInformativeText:[NSString stringWithFormat:
            @"Status changes from “%@” to “%@”. The change is staged in the same queue as the Board's status moves, on this Mac — nothing is sent until you choose Send Pending Changes.",
            fromStatus, manifestPayload[@"status"]]];
        details = [NSString stringWithFormat:
            @"Lane: GITHUB-DIRECT via the write-back queue.\n\n"
            @"Effect when sent: updateProjectV2ItemFieldValue will set the Status of “%@” from “%@” to “%@”.\n"
            @"Destination: %@ (operator: GitHub) over HTTPS.\n"
            @"Staging store: the local write-back queue at %@.\n"
            @"Arm state: write-back is compiled OFF in this build (SNOWFELL_WRITEBACK_ENABLED = 0); sending additionally requires a Keychain token and your explicit Send Pending Changes action in an armed build. Staging is not sending, and nothing leaves this Mac by staging.\n\n"
            @"Payload (exactly as it will be stored):\n%@",
            itemTitle, fromStatus, manifestPayload[@"status"],
            [GitHubProjectsClient graphQLEndpoint], [WriteBackQueue defaultStorePath], payloadJSON];
        [alert addButtonWithTitle:@"Stage Change"];
    } else {
        [alert setMessageText:[NSString stringWithFormat:@"Stage “%@”?", action.name]];
        NSMutableString *info = [NSMutableString stringWithFormat:@"For: %@\n\n", action.target];
        if ([precondition length] > 0) {
            [info appendFormat:@"%@\n\n", precondition];
        }
        if (action.requiresConfirm) {
            [info appendString:@"This action asks for a confirmation before it is staged — this sheet is that confirmation. "];
        }
        [info appendString:@"Staging runs nothing and sends nothing: the action waits in the queue on this Mac for Minion to carry out after approval."];
        [alert setInformativeText:info];
        details = [NSString stringWithFormat:
            @"Lane: ESTATE QUEUE.\n\n"
            @"Staging store: the local dispatch store at %@ (table local_dispatches), state “queued”. Minion/hooks — the estate consumer — execute approved rows; this app executes nothing from this queue.\n"
            @"Destination / operator (per the manifest): %@\n\n"
            @"Payload (exactly as it will be stored):\n%@",
            [DispatchStore defaultStorePath], action.target, payloadJSON];
        [alert addButtonWithTitle:@"Stage Action"];
    }
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:@"Details…"];

    NSWindow *window = self.view.window;
    if (window == nil) {
        return;
    }
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse result) {
        if (result == NSAlertFirstButtonReturn) {
            [weakSelf performEnqueueAction:action
                         manifestPayload:manifestPayload
                            storablePayload:storable
                               githubLane:githubLane];
            return;
        }
        if (result == NSAlertThirdButtonReturn) {
            NSAlert *detailsAlert = [[NSAlert alloc] init];
            [detailsAlert setMessageText:@"Details"];
            [detailsAlert setInformativeText:details];
            [detailsAlert addButtonWithTitle:@"Back"];
            [detailsAlert addButtonWithTitle:@"Cancel"];
            [detailsAlert beginSheetModalForWindow:window completionHandler:^(NSModalResponse back) {
                if (back == NSAlertFirstButtonReturn) {
                    [weakSelf enqueueClicked:nil];
                }
            }];
        }
    }];
}

- (void)performEnqueueAction:(SFAction *)action
           manifestPayload:(NSDictionary *)manifestPayload
          storablePayload:(NSDictionary *)storablePayload
                 githubLane:(BOOL)githubLane {
    NSError *error = nil;
    if (githubLane) {
        if (self.writeBackQueue == nil) {
            [self showEnqueueFailure:@"The staged-changes queue is unavailable in this session; nothing was staged."];
            return;
        }
        int64_t rowID = [self.writeBackQueue enqueueMutationWithKind:WriteBackKindStatusMove
                                                             boardID:manifestPayload[@"board"]
                                                              itemID:manifestPayload[@"item"]
                                                             payload:storablePayload
                                                               error:&error];
        if (rowID < 0) {
            [self showEnqueueFailure:[NSString stringWithFormat:@"%@\nNothing was staged and nothing was sent.",
                                      (error != nil) ? error.localizedDescription : @"unknown error"]];
            return;
        }
        [_validationField setStringValue:[NSString stringWithFormat:
                                          @"Staged as change #%lld — see View ▸ Staged Changes (⌘4).", rowID]];
        return;
    }
    if (self.dispatchStore == nil) {
        [self showEnqueueFailure:@"The action queue is unavailable in this session; nothing was staged."];
        return;
    }
    int64_t rowID = [self.dispatchStore enqueueDispatchWithActionID:action.actionID
                                                            payload:storablePayload
                                                              error:&error];
    if (rowID < 0) {
        [self showEnqueueFailure:[NSString stringWithFormat:@"%@\nNothing was staged and nothing was sent.",
                                  (error != nil) ? error.localizedDescription : @"unknown error"]];
        return;
    }
    [self reloadOrchestration];
    [_validationField setStringValue:[NSString stringWithFormat:
                                      @"Staged as action #%lld in the queue below.", rowID]];
}

- (void)showEnqueueFailure:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Action not staged"];
    [alert setInformativeText:message];
    NSWindow *window = self.view.window;
    if (window != nil) {
        [alert beginSheetModalForWindow:window completionHandler:nil];
    }
}

#pragma mark - Queue pane actions

- (void)stateFilterChanged:(id)sender {
    [self refreshQueuePane];
}

- (void)refreshClicked:(id)sender {
    [self reloadOrchestration];
}

- (void)cancelClicked:(id)sender {
    NSInteger row = [_queueTable selectedRow];
    NSArray<LocalDispatch *> *visible = [self visibleDispatches];
    if (row < 0 || row >= (NSInteger)[visible count]) {
        return;
    }
    LocalDispatch *dispatch = visible[(NSUInteger)row];
    if (![dispatch.state isEqualToString:DispatchStateQueued] || self.dispatchStore == nil) {
        return;
    }
    NSError *error = nil;
    if (![self.dispatchStore cancelDispatch:dispatch.dispatchID error:&error]) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Staged action not cancelled"];
        [alert setInformativeText:(error != nil) ? error.localizedDescription : @"unknown error"];
        NSWindow *window = self.view.window;
        if (window != nil) {
            [alert beginSheetModalForWindow:window completionHandler:nil];
        }
        return;
    }
    [self reloadOrchestration];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == _manifestTable) {
        return (NSInteger)[self.actions count];
    }
    if (tableView == _queueTable) {
        return (NSInteger)[[self visibleDispatches] count];
    }
    if (tableView == _auditTable) {
        return (NSInteger)[self.auditRows count];
    }
    return 0;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSString *identifier = [tableColumn identifier];
    if (tableView == _manifestTable) {
        SFAction *action = self.actions[(NSUInteger)row];
        if ([identifier isEqualToString:@"name"]) {
            if (!action.enabled) {
                // Struck + dimmed: disabled in the manifest, shown for
                // the record, never composable.
                NSDictionary *attributes = @{
                    NSStrikethroughStyleAttributeName: @(NSUnderlineStyleSingle),
                    NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
                };
                return [[NSAttributedString alloc] initWithString:action.name attributes:attributes];
            }
            return action.name;
        }
        if ([identifier isEqualToString:@"kind"]) {
            return action.kind;
        }
        if ([identifier isEqualToString:@"risk"]) {
            return action.riskClass;
        }
        if ([identifier isEqualToString:@"confirm"]) {
            return action.requiresConfirm ? @"required" : @"—";
        }
        if ([identifier isEqualToString:@"enabled"]) {
            return action.enabled ? @"yes" : @"NO";
        }
        return @"";
    }
    if (tableView == _queueTable) {
        LocalDispatch *dispatch = [self visibleDispatches][(NSUInteger)row];
        if ([identifier isEqualToString:@"id"]) {
            return [NSString stringWithFormat:@"%lld", dispatch.dispatchID];
        }
        if ([identifier isEqualToString:@"action"]) {
            return dispatch.actionID;
        }
        if ([identifier isEqualToString:@"state"]) {
            return dispatch.state;
        }
        if ([identifier isEqualToString:@"payload"]) {
            return dispatch.payloadSummary;
        }
        if ([identifier isEqualToString:@"queued"]) {
            return dispatch.createdAt;
        }
        return @"";
    }
    if (tableView == _auditTable) {
        LocalAuditEntry *entry = self.auditRows[(NSUInteger)row];
        if ([identifier isEqualToString:@"ts"]) {
            return entry.ts;
        }
        if ([identifier isEqualToString:@"action"]) {
            return entry.action;
        }
        if ([identifier isEqualToString:@"object"]) {
            return (entry.objectRef != nil) ? entry.objectRef : @"";
        }
        if ([identifier isEqualToString:@"after"]) {
            return (entry.afterJSON != nil) ? entry.afterJSON : @"";
        }
        return @"";
    }
    return @"";
}

#pragma mark - NSTableViewDelegate

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSTableView *tableView = [notification object];
    if (tableView == _manifestTable) {
        NSInteger row = [_manifestTable selectedRow];
        if (row >= 0 && row < (NSInteger)[self.actions count]) {
            [self selectAction:self.actions[(NSUInteger)row] syncManifest:NO];
        }
    } else if (tableView == _queueTable) {
        [self refreshQueuePane];
    }
}

- (NSString *)tableView:(NSTableView *)tableView toolTipForCell:(NSCell *)cell rect:(NSRectPointer)rect tableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row mouseLocation:(NSPoint)mouseLocation {
    if (tableView == _manifestTable) {
        SFAction *action = self.actions[(NSUInteger)row];
        return [NSString stringWithFormat:@"%@\n%@\n%@", action.actionID, action.target, action.payloadSchemaJSON];
    }
    if (tableView == _queueTable) {
        LocalDispatch *dispatch = [self visibleDispatches][(NSUInteger)row];
        NSMutableString *tip = [NSMutableString stringWithFormat:@"#%lld · %@ · %@\nupdated %@\n%@",
                                dispatch.dispatchID, dispatch.actionID, dispatch.state,
                                dispatch.updatedAt, dispatch.payloadJSON];
        if (dispatch.resultRef != nil) {
            [tip appendFormat:@"\nresult: %@", dispatch.resultRef];
        }
        if (dispatch.lastError != nil) {
            [tip appendFormat:@"\nerror: %@", dispatch.lastError];
        }
        return tip;
    }
    if (tableView == _auditTable) {
        LocalAuditEntry *entry = self.auditRows[(NSUInteger)row];
        return [NSString stringWithFormat:@"%@ · %@\nbefore: %@\nafter: %@",
                entry.actor, entry.action,
                (entry.beforeJSON != nil) ? entry.beforeJSON : @"—",
                (entry.afterJSON != nil) ? entry.afterJSON : @"—"];
    }
    return nil;
}

@end
