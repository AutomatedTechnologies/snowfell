#import "PortfolioViewController.h"
#import "SnapshotStore.h"
#import "BoardSummary.h"

@interface PortfolioViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong, readwrite) SnapshotStore *snapshotStore;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSTextField *summaryField;
@property (nonatomic, copy) NSArray<BoardSummary *> *allBoards;
@property (nonatomic, copy) NSArray<BoardSummary *> *visibleBoards;
@end

@implementation PortfolioViewController

- (instancetype)initWithSnapshotStore:(SnapshotStore *)store {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _snapshotStore = store;
        _showClosedBoards = YES;
        _showArchivedBoards = NO;
        _allBoards = @[];
        _visibleBoards = @[];
    }
    return self;
}

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 900, 560)];

    _summaryField = [NSTextField labelWithString:@""];
    [_summaryField setFont:[NSFont systemFontOfSize:12]];
    [_summaryField setTextColor:[NSColor secondaryLabelColor]];
    [_summaryField setFrame:NSMakeRect(12, 528, 876, 18)];
    [_summaryField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:_summaryField];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 900, 518)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setBorderType:NSNoBorder];
    [scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    _tableView = [[NSTableView alloc] initWithFrame:scrollView.bounds];
    [_tableView setDataSource:self];
    [_tableView setDelegate:self];
    [_tableView setUsesAlternatingRowBackgroundColors:YES];
    [_tableView setRowHeight:22];
    [_tableView setAllowsMultipleSelection:NO];
    [_tableView setTarget:self];
    [_tableView setDoubleAction:@selector(tableViewDoubleClicked:)];

    NSArray *columns = @[
        @{@"id": @"board",  @"title": @"Board",  @"width": @260},
        @{@"id": @"owner",  @"title": @"Owner",  @"width": @170},
        @{@"id": @"state",  @"title": @"State",  @"width": @80},
        @{@"id": @"items",  @"title": @"Items",  @"width": @60},
        @{@"id": @"status", @"title": @"Status vocabulary", @"width": @320},
    ];
    for (NSDictionary *columnSpec in columns) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:columnSpec[@"id"]];
        [[column headerCell] setStringValue:columnSpec[@"title"]];
        [column setWidth:[columnSpec[@"width"] doubleValue]];
        [_tableView addTableColumn:column];
    }

    [scrollView setDocumentView:_tableView];
    [root addSubview:scrollView];
    self.view = root;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self reloadPortfolio];
}

- (void)setShowClosedBoards:(BOOL)showClosedBoards {
    _showClosedBoards = showClosedBoards;
    [self applyFilters];
}

- (void)setShowArchivedBoards:(BOOL)showArchivedBoards {
    _showArchivedBoards = showArchivedBoards;
    [self applyFilters];
}

- (void)applyFilters {
    NSMutableArray<BoardSummary *> *visible = [NSMutableArray array];
    for (BoardSummary *board in self.allBoards) {
        if (board.archivedHidden && !self.showArchivedBoards) {
            continue;
        }
        if (board.closed && !board.archivedHidden && !self.showClosedBoards) {
            continue;
        }
        [visible addObject:board];
    }
    self.visibleBoards = visible;
    [self.tableView reloadData];
    [self updateSummary];
}

- (void)updateSummary {
    SnapshotStore *store = self.snapshotStore;
    if (store.snapshotPath == nil) {
        NSString *reason = (store.loadError != nil) ? store.loadError.localizedDescription
                                                    : @"No snapshot is loaded.";
        [_summaryField setStringValue:[NSString stringWithFormat:@"Portfolio unavailable — %@", reason]];
        return;
    }
    NSInteger itemTotal = 0;
    for (BoardSummary *board in self.allBoards) {
        itemTotal += board.itemCount;
    }
    [_summaryField setStringValue:[NSString stringWithFormat:
                                    @"%@ · %lu boards (%lu shown) · %ld items · snapshot SHA-256 %@…",
                                    store.snapshotVersion,
                                    (unsigned long)[self.allBoards count],
                                    (unsigned long)[self.visibleBoards count],
                                    (long)itemTotal,
                                    [store.snapshotSHA256 substringToIndex:MIN((NSUInteger)12, [store.snapshotSHA256 length])]]];
}

- (void)reloadPortfolio {
    NSError *error = nil;
    NSArray<BoardSummary *> *boards = [self.snapshotStore portfolioBoardsWithError:&error];
    if (boards == nil) {
        self.allBoards = @[];
        self.visibleBoards = @[];
        [_summaryField setStringValue:[NSString stringWithFormat:
                                       @"Portfolio unavailable — %@",
                                       (error != nil) ? error.localizedDescription : @"unknown error"]];
        [self.tableView reloadData];
        return;
    }
    self.allBoards = boards;
    [self applyFilters];
}

#pragma mark - Selection / activation (SF-T3)

- (BoardSummary *)selectedBoard {
    NSInteger row = [_tableView selectedRow];
    if (row < 0 || row >= (NSInteger)[self.visibleBoards count]) {
        return nil;
    }
    return self.visibleBoards[(NSUInteger)row];
}

- (void)tableViewDoubleClicked:(id)sender {
    BoardSummary *board = [self selectedBoard];
    if (board != nil && self.boardActivationHandler != nil) {
        self.boardActivationHandler(board);
    }
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)[self.visibleBoards count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    BoardSummary *board = self.visibleBoards[(NSUInteger)row];
    NSString *identifier = [tableColumn identifier];
    if ([identifier isEqualToString:@"board"]) {
        return [NSString stringWithFormat:@"%@  (#%ld)", board.title, (long)board.number];
    }
    if ([identifier isEqualToString:@"owner"]) {
        return board.ownerDisplay;
    }
    if ([identifier isEqualToString:@"state"]) {
        return board.stateDisplay;
    }
    if ([identifier isEqualToString:@"items"]) {
        return [NSString stringWithFormat:@"%ld", (long)board.itemCount];
    }
    if ([identifier isEqualToString:@"status"]) {
        return board.statusSummary;
    }
    return nil;
}

#pragma mark - NSTableViewDelegate

- (NSString *)tableView:(NSTableView *)tableView toolTipForCell:(NSCell *)cell rect:(NSRectPointer)rect tableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row mouseLocation:(NSPoint)mouseLocation {
    if ([[tableColumn identifier] isEqualToString:@"board"]) {
        BoardSummary *board = self.visibleBoards[(NSUInteger)row];
        if ([board.shortDescription length] > 0) {
            return [NSString stringWithFormat:@"%@\n%@", board.shortDescription, board.url];
        }
        return board.url;
    }
    return nil;
}

@end
