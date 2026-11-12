#import "CommandPaletteViewController.h"
#import "SnapshotStore.h"
#import "PaletteResult.h"
#import "BoardSummary.h"
#import "BoardItem.h"
#import "SFAction.h"
#import "DeployTarget.h"
#import "DraftRow.h"

@interface CommandPaletteViewController () <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate>
@property (nonatomic, strong, readwrite) SnapshotStore *snapshotStore;
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSTextField *statusField;
@property (nonatomic, strong) NSTableView *resultsTable;
@property (nonatomic, copy) NSArray<PaletteResult *> *results;
@end

@implementation CommandPaletteViewController

- (instancetype)initWithSnapshotStore:(SnapshotStore *)store {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _snapshotStore = store;
        _results = @[];
    }
    return self;
}

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 420)];

    _searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(12, 380, 616, 28)];
    [_searchField setPlaceholderString:@"Search boards, items, actions, deploy targets, drafts…"];
    [_searchField setDelegate:self];
    [_searchField setTarget:self];
    [_searchField setAction:@selector(searchFieldCommitted:)];
    [_searchField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [[_searchField cell] setSendsSearchStringImmediately:NO];
    [root addSubview:_searchField];

    _statusField = [NSTextField labelWithString:@""];
    [_statusField setFont:[NSFont systemFontOfSize:11]];
    [_statusField setTextColor:[NSColor secondaryLabelColor]];
    [_statusField setFrame:NSMakeRect(14, 354, 612, 16)];
    [_statusField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:_statusField];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 640, 346)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setBorderType:NSNoBorder];
    [scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    _resultsTable = [[NSTableView alloc] initWithFrame:scrollView.bounds];
    [_resultsTable setDataSource:self];
    [_resultsTable setDelegate:self];
    [_resultsTable setUsesAlternatingRowBackgroundColors:YES];
    [_resultsTable setRowHeight:22];
    [_resultsTable setAllowsMultipleSelection:NO];
    [_resultsTable setTarget:self];
    [_resultsTable setDoubleAction:@selector(resultsDoubleClicked:)];

    NSArray *columns = @[
        @{@"id": @"kind",  @"title": @"Kind",  @"width": @70},
        @{@"id": @"title", @"title": @"Title", @"width": @330},
        @{@"id": @"detail", @"title": @"Detail", @"width": @220},
    ];
    for (NSDictionary *spec in columns) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:spec[@"id"]];
        [[column headerCell] setStringValue:spec[@"title"]];
        [column setWidth:[spec[@"width"] doubleValue]];
        [_resultsTable addTableColumn:column];
    }

    [scrollView setDocumentView:_resultsTable];
    [root addSubview:scrollView];
    self.view = root;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self reloadPalette];
}

#pragma mark - Search

- (void)resetPalette {
    // Load the view first if AppDelegate opens the palette before any
    // other path has (view access triggers loadView/viewDidLoad).
    (void)self.view;
    [_searchField setStringValue:@""];
    [self reloadPalette];
    [self.view.window makeFirstResponder:_searchField];
}

- (void)reloadPalette {
    if (self.snapshotStore.snapshotPath == nil) {
        NSString *reason = (self.snapshotStore.loadError != nil)
            ? self.snapshotStore.loadError.localizedDescription : @"No snapshot is loaded.";
        self.results = @[];
        [_statusField setStringValue:[NSString stringWithFormat:@"Palette unavailable — %@", reason]];
        [_resultsTable reloadData];
        return;
    }
    NSString *query = [_searchField stringValue];
    NSError *error = nil;
    NSArray<PaletteResult *> *results = [self.snapshotStore paletteResultsForQuery:(query != nil) ? query : @"" error:&error];
    if (results == nil) {
        self.results = @[];
        [_statusField setStringValue:[NSString stringWithFormat:
                                      @"Search failed: %@", (error != nil) ? error.localizedDescription : @"unknown error"]];
    } else {
        self.results = results;
        NSString *trimmed = [(query != nil) ? query : @"" stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([trimmed length] == 0) {
            [_statusField setStringValue:[NSString stringWithFormat:
                                          @"%lu result(s) — boards, actions, targets, drafts. Type to search items too; Enter opens the selection.",
                                          (unsigned long)[results count]]];
        } else {
            [_statusField setStringValue:[NSString stringWithFormat:
                                          @"%lu result(s) for “%@” — Enter opens the selection, Esc closes.",
                                          (unsigned long)[results count], trimmed]];
        }
    }
    [_resultsTable reloadData];
    if ([self.results count] > 0) {
        [_resultsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    }
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if ([notification object] == _searchField) {
        [self reloadPalette];
    }
}

- (void)searchFieldCommitted:(id)sender {
    // Enter in the search field activates the selected (or first) row.
    [self activateSelectedResult];
}

- (void)resultsDoubleClicked:(id)sender {
    [self activateSelectedResult];
}

- (void)cancelOperation:(id)sender {
    // Escape: the palette is an overlay — close its window, change nothing.
    [self.view.window close];
}

#pragma mark - Routing

- (void)closePalette {
    [self.view.window close];
}

- (void)activateSelectedResult {
    NSInteger row = [_resultsTable selectedRow];
    if (row < 0 && [self.results count] > 0) {
        row = 0;
    }
    if (row < 0 || row >= (NSInteger)[self.results count]) {
        return;
    }
    PaletteResult *result = self.results[(NSUInteger)row];
    NSError *error = nil;
    switch (result.kind) {
        case PaletteResultKindBoard: {
            NSArray<BoardSummary *> *boards = [self.snapshotStore portfolioBoardsWithError:&error];
            for (BoardSummary *board in boards) {
                if ([board.nodeID isEqualToString:result.referenceID]) {
                    [self closePalette];
                    if (self.boardActivationHandler != nil) {
                        self.boardActivationHandler(board);
                    }
                    return;
                }
            }
            break;
        }
        case PaletteResultKindItem: {
            BoardItem *item = [self.snapshotStore itemWithNodeID:result.referenceID error:&error];
            if (item != nil) {
                [self closePalette];
                if (self.itemActivationHandler != nil) {
                    self.itemActivationHandler(item);
                }
                return;
            }
            break;
        }
        case PaletteResultKindAction: {
            [self closePalette];
            if (self.actionActivationHandler != nil) {
                self.actionActivationHandler(result.referenceID);
            }
            return;
        }
        case PaletteResultKindDeployTarget: {
            [self closePalette];
            if (self.targetActivationHandler != nil) {
                self.targetActivationHandler(result.referenceID);
            }
            return;
        }
        case PaletteResultKindDraft: {
            NSArray<DraftRow *> *drafts = [self.snapshotStore draftRowsWithError:&error];
            for (DraftRow *draft in drafts) {
                if (draft.compositionID == [result.referenceID integerValue]) {
                    [self closePalette];
                    if (self.draftActivationHandler != nil) {
                        self.draftActivationHandler(draft);
                    }
                    return;
                }
            }
            break;
        }
    }
    // Resolution failed (the row's object is not in the snapshot): state
    // it in place rather than closing on a dead route.
    [_statusField setStringValue:[NSString stringWithFormat:
                                  @"Could not resolve that result in the snapshot (%@). Nothing was opened.",
                                  (error != nil) ? error.localizedDescription : @"not found"]];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)[self.results count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    PaletteResult *result = self.results[(NSUInteger)row];
    NSString *identifier = [tableColumn identifier];
    if ([identifier isEqualToString:@"kind"]) {
        return result.kindDisplay;
    }
    if ([identifier isEqualToString:@"title"]) {
        return result.title;
    }
    if ([identifier isEqualToString:@"detail"]) {
        return result.subtitle;
    }
    return @"";
}

@end
