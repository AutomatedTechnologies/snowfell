#import "PortfolioViewController.h"
#import "SnapshotStore.h"
#import "BoardSummary.h"
#import "AcademyTheme.h"

// PortfolioViewController (V2) — presentation uplifted at snowfell-test-2
// to the decision-gate HTML baseline (design record §4, V2): view-based
// rows, baseline table typography (11px letterspaced uppercase headers,
// 12.5px body, 1px --line row rules), a health dot per board, an
// Open / Done split, and the board's own Status vocabulary as bare option
// names. Selection follows the baseline: ink background, white text.
// READ-ONLY exactly as before: SELECTs through SnapshotStore, no writes.
//
// Health dot derivation (presentation-only): on schema v9 snapshots the
// registry's own sf_board_state derivation governs (design note 04);
// on earlier snapshots the lens reads the board's own Status vocabulary
// (terminal option = the LAST option in the board's own order): full =
// every item sits in the terminal status; half = at least one item does;
// hollow = none do, or the board is empty/closed/archived.
// Open / Done = open count / terminal count, same source discipline.

typedef NS_ENUM(NSInteger, PortfolioHealth) {
    PortfolioHealthHollow = 0,
    PortfolioHealthHalf = 1,
    PortfolioHealthFull = 2,
};

// Row view: white field, ink selection (baseline table.pf + .side a.on).
@interface PortfolioRowView : NSTableRowView
@end

@implementation PortfolioRowView
- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    [[AcademyTheme panelColor] setFill];
    NSRectFill(dirtyRect);
}
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    if (self.selectionHighlightStyle != NSTableViewSelectionHighlightStyleNone) {
        [[AcademyTheme inkColor] setFill];
        NSRectFill([self bounds]);
    }
}
- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    NSBackgroundStyle style = selected ? NSBackgroundStyleDark
                                       : NSBackgroundStyleLight;
    for (NSView *subview in [self subviews]) {
        if ([subview isKindOfClass:[NSTableCellView class]]) {
            [(NSTableCellView *)subview setBackgroundStyle:style];
        }
    }
}
@end

// Text cell that recolors on emphasized (selected) rows.
@interface PortfolioTextCellView : NSTableCellView
@property (nonatomic, strong) NSColor *normalColor;
@property (nonatomic, strong) NSColor *selectedColor;
@end

@implementation PortfolioTextCellView
- (void)setBackgroundStyle:(NSBackgroundStyle)backgroundStyle {
    [super setBackgroundStyle:backgroundStyle];
    if (backgroundStyle == NSBackgroundStyleDark) {
        [[self textField] setTextColor:(self.selectedColor ?: [AcademyTheme selectionTextColor])];
    } else {
        [[self textField] setTextColor:(self.normalColor ?: [AcademyTheme inkColor])];
    }
}
@end

// Board cell: "#3 Title" semibold line + optional description sub-line.
@interface PortfolioBoardCellView : NSTableCellView
@property (nonatomic, copy) NSString *titleLine;
@property (nonatomic, copy, nullable) NSString *subLine;
- (void)refreshText;
@end

@implementation PortfolioBoardCellView
- (void)refreshText {
    BOOL emphasized = ([self backgroundStyle] == NSBackgroundStyleDark);
    NSColor *titleColor = emphasized ? [AcademyTheme selectionTextColor]
                                     : [AcademyTheme inkColor];
    NSColor *subColor = emphasized ? [AcademyTheme selectionSubTextColor]
                                   : [AcademyTheme inkTertiaryColor];
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc]
        initWithString:self.titleLine
            attributes:@{NSFontAttributeName: [AcademyTheme bodySemiboldFont],
                         NSForegroundColorAttributeName: titleColor}];
    if ([self.subLine length] > 0) {
        [text appendAttributedString:[[NSAttributedString alloc]
            initWithString:[@"\n" stringByAppendingString:self.subLine]
                attributes:@{NSFontAttributeName: [AcademyTheme metaFont],
                             NSForegroundColorAttributeName: subColor}]];
    }
    [[self textField] setAttributedStringValue:text];
}
- (void)setBackgroundStyle:(NSBackgroundStyle)backgroundStyle {
    [super setBackgroundStyle:backgroundStyle];
    [self refreshText];
}
@end

// Health dot (baseline .dot / .dot.half / .dot.full): 10px circle, 1.5px
// ink ring; full = ink fill, half = left-half ink fill, hollow = ring only.
@interface PortfolioHealthDotView : NSView
@property (nonatomic, assign) PortfolioHealth health;
@end

@implementation PortfolioHealthDotView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    NSRect dot = NSMakeRect(([self bounds].size.width - 10) / 2,
                            ([self bounds].size.height - 10) / 2, 10, 10);
    NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:dot];
    if (self.health == PortfolioHealthFull) {
        [[AcademyTheme inkColor] setFill];
        [circle fill];
    } else if (self.health == PortfolioHealthHalf) {
        [NSGraphicsContext saveGraphicsState];
        NSRectClip(NSMakeRect(dot.origin.x, dot.origin.y, NSWidth(dot) / 2, NSHeight(dot)));
        [[AcademyTheme inkColor] setFill];
        [circle fill];
        [NSGraphicsContext restoreGraphicsState];
    }
    [[AcademyTheme inkColor] setStroke];
    [circle setLineWidth:1.5];
    [circle stroke];
}
@end

@interface PortfolioViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong, readwrite) SnapshotStore *snapshotStore;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSTextField *titleField;
@property (nonatomic, strong) NSTextField *subField;
@property (nonatomic, copy) NSArray<BoardSummary *> *allBoards;
@property (nonatomic, copy) NSArray<BoardSummary *> *visibleBoards;
// Parallel to visibleBoards: @{health, openDone, vocabulary} per board.
@property (nonatomic, copy) NSArray<NSDictionary *> *rowModels;
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
        _rowModels = @[];
    }
    return self;
}

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1080, 620)];
    [root setWantsLayer:YES];
    [[root layer] setBackgroundColor:[[AcademyTheme windowColor] CGColor]];

    _titleField = [NSTextField labelWithString:@""];
    [_titleField setFont:[AcademyTheme lensTitleFont]];
    [_titleField setTextColor:[AcademyTheme inkColor]];
    [_titleField setFrame:NSMakeRect(14, 620 - 34, 1052, 20)];
    [_titleField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:_titleField];

    _subField = [NSTextField labelWithString:@""];
    [_subField setFont:[AcademyTheme metaFont]];
    [_subField setTextColor:[AcademyTheme inkTertiaryColor]];
    [_subField setFrame:NSMakeRect(14, 620 - 52, 1052, 15)];
    [_subField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:_subField];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 1080, 620 - 62)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setBorderType:NSNoBorder];
    [scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [scrollView setDrawsBackground:YES];
    [scrollView setBackgroundColor:[AcademyTheme panelColor]];

    _tableView = [[NSTableView alloc] initWithFrame:scrollView.bounds];
    [_tableView setDataSource:self];
    [_tableView setDelegate:self];
    [_tableView setUsesAlternatingRowBackgroundColors:NO];
    [_tableView setBackgroundColor:[AcademyTheme panelColor]];
    [_tableView setGridStyleMask:NSTableViewSolidHorizontalGridLineMask];
    [_tableView setGridColor:[AcademyTheme lineColor]];
    [_tableView setRowHeight:38];
    [_tableView setIntercellSpacing:NSMakeSize(8, 0)];
    [_tableView setAllowsMultipleSelection:NO];
    [_tableView setTarget:self];
    [_tableView setDoubleAction:@selector(tableViewDoubleClicked:)];

    // snowfell-test-5: the baseline's UPDATED column is restored —
    // its data source (sf_boards.gh_updated_at, schema v10) now
    // exists. Widths rebalance to the same 1026 total: board and
    // vocabulary yield the 92 the column takes.
    // snowfell-test-7: the GITHUB column takes 92 from VOCABULARY
    // (same 1026 total) and carries the per-board "Open in GitHub"
    // action — the URL itself has ridden in BoardSummary.url since
    // SF-T2 and showed only as tooltip text until now.
    NSArray *columns = @[
        @{@"id": @"health", @"title": @"",              @"width": @28},
        @{@"id": @"board",  @"title": @"BOARD",         @"width": @284},
        @{@"id": @"owner",  @"title": @"OWNER",         @"width": @132},
        @{@"id": @"state",  @"title": @"STATE",         @"width": @84},
        @{@"id": @"items",  @"title": @"ITEMS",         @"width": @56},
        @{@"id": @"split",  @"title": @"OPEN / DONE",   @"width": @88},
        @{@"id": @"updated", @"title": @"UPDATED",      @"width": @92},
        @{@"id": @"status", @"title": @"VOCABULARY",    @"width": @170},
        @{@"id": @"github", @"title": @"GITHUB",        @"width": @92},
    ];
    for (NSDictionary *columnSpec in columns) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:columnSpec[@"id"]];
        NSTableHeaderCell *header = [column headerCell];
        [header setStringValue:columnSpec[@"title"]];
        [header setFont:[AcademyTheme capsHeaderFont]];
        [header setTextColor:[AcademyTheme inkSecondaryColor]];
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

// The UPDATED column exists only when the loaded snapshot carries
// the data (schema v10+): on older snapshots it is removed outright —
// a column of dashes would read as data, and it would not be.
- (void)refreshUpdatedColumnVisibility {
    NSTableColumn *column = [_tableView tableColumnWithIdentifier:@"updated"];
    BOOL anyStamped = NO;
    for (BoardSummary *board in self.allBoards) {
        if ([board.ghUpdatedAt length] > 0) {
            anyStamped = YES;
            break;
        }
    }
    if (anyStamped && column == nil) {
        NSTableColumn *restored = [[NSTableColumn alloc] initWithIdentifier:@"updated"];
        NSTableHeaderCell *header = [restored headerCell];
        [header setStringValue:@"UPDATED"];
        [header setFont:[AcademyTheme capsHeaderFont]];
        [header setTextColor:[AcademyTheme inkSecondaryColor]];
        [restored setWidth:92];
        [_tableView addTableColumn:restored];
        // Keep the baseline order: UPDATED sits before VOCABULARY.
        NSInteger updatedIndex = [[_tableView tableColumns] indexOfObject:restored];
        NSInteger statusIndex = [[_tableView tableColumns] indexOfObject:
            [_tableView tableColumnWithIdentifier:@"status"]];
        if (statusIndex != NSNotFound && updatedIndex > statusIndex) {
            [_tableView moveColumn:updatedIndex toColumn:statusIndex];
        }
    } else if (!anyStamped && column != nil) {
        [_tableView removeTableColumn:column];
    }
}

- (void)applyFilters {
    [self refreshUpdatedColumnVisibility];
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
    [self rebuildRowModels];
    [self.tableView reloadData];
    [self updateSummary];
}

// Computes the presentation-only row models (health, Open / Done,
// vocabulary) from the store's per-board Status data. Read-only SELECTs;
// no lens logic changes — the same boards, in the same order, with the
// same filters as before the uplift.
- (void)rebuildRowModels {
    NSMutableArray<NSDictionary *> *models = [NSMutableArray array];
    NSRegularExpression *countSuffix =
        [NSRegularExpression regularExpressionWithPattern:@"^(.*) (\\d+)$"
                                                  options:0 error:nil];
    for (BoardSummary *board in self.visibleBoards) {
        NSArray<NSString *> *options =
            [self.snapshotStore statusOptionsForBoard:board.nodeID error:nil] ?: @[];

        // Counts per option, parsed from the store-composed summary
        // ("Todo 80 · In Progress 6 · Done 15"; bare names when unvalued).
        NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
        for (NSString *segment in [board.statusSummary componentsSeparatedByString:@" · "]) {
            NSTextCheckingResult *match =
                [countSuffix firstMatchInString:segment options:0
                                          range:NSMakeRange(0, [segment length])];
            if (match != nil && [match numberOfRanges] == 3) {
                NSString *name = [segment substringWithRange:[match rangeAtIndex:1]];
                NSInteger value = [[segment substringWithRange:[match rangeAtIndex:2]] integerValue];
                counts[name] = @(value);
            }
        }

        NSInteger doneCount = 0;
        if ([options count] > 0) {
            doneCount = [counts[[options lastObject]] integerValue];
        }
        NSInteger openCount = MAX(board.itemCount - doneCount, 0);

        PortfolioHealth health = PortfolioHealthHollow;
        if (!board.closed && !board.archivedHidden && board.itemCount > 0) {
            if (doneCount >= board.itemCount) {
                health = PortfolioHealthFull;
            } else if (doneCount > 0) {
                health = PortfolioHealthHalf;
            }
        }

        // Schema v9 snapshots carry the registry's own derivation
        // (sf_board_state, design note 04): when present it governs the
        // dot and the split — its terminal resolution is stricter than
        // this lens's last-option reading of the summary string, which
        // remains the fallback for pre-v9 snapshots.
        if (board.hasDerivedState) {
            doneCount = board.derivedItemsTerminal;
            openCount = MAX(board.derivedItemsTotal - board.derivedItemsTerminal, 0);
            if (board.closed || board.archivedHidden || board.derivedItemsTotal == 0) {
                health = PortfolioHealthHollow;
            } else if ([board.derivedState isEqualToString:@"COMPLETE"]) {
                health = PortfolioHealthFull;
            } else if (board.derivedItemsTerminal > 0) {
                health = PortfolioHealthHalf;
            } else {
                health = PortfolioHealthHollow;
            }
        }

        NSString *vocabulary = ([options count] > 0)
            ? [options componentsJoinedByString:@" · "]
            : board.statusSummary;
        NSString *split = ((board.hasDerivedState ? board.derivedItemsTotal : board.itemCount) > 0)
            ? [NSString stringWithFormat:@"%ld / %ld", (long)openCount, (long)doneCount]
            : @"—";

        [models addObject:@{@"health": @(health),
                            @"split": split,
                            @"vocabulary": vocabulary ?: @""}];
    }
    self.rowModels = models;
}

- (void)setFreshnessText:(NSString *)freshnessText {
    _freshnessText = [freshnessText copy];
    [self updateSummary];
}

- (void)updateSummary {
    SnapshotStore *store = self.snapshotStore;
    if (store.snapshotPath == nil) {
        NSString *reason = (store.loadError != nil) ? store.loadError.localizedDescription
                                                    : @"No snapshot is loaded.";
        [_titleField setStringValue:[NSString stringWithFormat:@"Portfolio unavailable — %@", reason]];
        [_subField setStringValue:@""];
        return;
    }
    NSInteger itemTotal = 0;
    for (BoardSummary *board in self.allBoards) {
        itemTotal += board.itemCount;
    }
    [_titleField setStringValue:[NSString stringWithFormat:
                                  @"Portfolio — %lu boards · %ld items",
                                  (unsigned long)[self.allBoards count], (long)itemTotal]];
    NSString *subLine = [NSString stringWithFormat:
                               @"%lu shown · snapshot %@ · SHA-256 %@…",
                               (unsigned long)[self.visibleBoards count],
                               store.snapshotVersion,
                               [store.snapshotSHA256 substringToIndex:MIN((NSUInteger)12, [store.snapshotSHA256 length])]];
    // Freshness remainder (snowfell-test-5): when the session's sync
    // state names a gap, the header names it too — the owner should
    // not have to open the Updates lens to learn an update exists.
    if ([self.freshnessText length] > 0) {
        subLine = [subLine stringByAppendingFormat:@" · %@", self.freshnessText];
    }
    [_subField setStringValue:subLine];
}

- (void)reloadPortfolio {
    NSError *error = nil;
    NSArray<BoardSummary *> *boards = [self.snapshotStore portfolioBoardsWithError:&error];
    if (boards == nil) {
        self.allBoards = @[];
        self.visibleBoards = @[];
        self.rowModels = @[];
        [_titleField setStringValue:[NSString stringWithFormat:
                                     @"Portfolio unavailable — %@",
                                     (error != nil) ? error.localizedDescription : @"unknown error"]];
        [_subField setStringValue:@""];
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

// snowfell-test-7: the GITHUB column's per-row action. The row is
// resolved from the clicked button's position in the table (never a
// stored row index — reuse and filtering cannot stale it), and the
// stored sf_boards.url opens verbatim in the owner's default
// browser via NSWorkspace.
- (void)openBoardInGitHubClicked:(id)sender {
    NSInteger row = [_tableView rowForView:(NSView *)sender];
    if (row < 0 || row >= (NSInteger)[self.visibleBoards count]) {
        return;
    }
    BoardSummary *board = self.visibleBoards[(NSUInteger)row];
    if ([board.url length] == 0) {
        return;
    }
    NSURL *url = [NSURL URLWithString:board.url];
    if (url != nil) {
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)[self.visibleBoards count];
}

#pragma mark - NSTableViewDelegate

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    PortfolioRowView *rowView = [tableView makeViewWithIdentifier:@"PortfolioRow" owner:self];
    if (rowView == nil) {
        rowView = [[PortfolioRowView alloc] initWithFrame:NSZeroRect];
        [rowView setIdentifier:@"PortfolioRow"];
    }
    return rowView;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    BoardSummary *board = self.visibleBoards[(NSUInteger)row];
    NSDictionary *model = self.rowModels[(NSUInteger)row];
    NSString *identifier = [tableColumn identifier];

    if ([identifier isEqualToString:@"health"]) {
        PortfolioHealthDotView *dot = [tableView makeViewWithIdentifier:@"HealthCell" owner:self];
        if (dot == nil) {
            dot = [[PortfolioHealthDotView alloc] initWithFrame:NSMakeRect(0, 0, 28, 38)];
            [dot setIdentifier:@"HealthCell"];
        }
        [dot setHealth:(PortfolioHealth)[model[@"health"] integerValue]];
        [dot setNeedsDisplay:YES];
        return dot;
    }

    if ([identifier isEqualToString:@"github"]) {
        // snowfell-test-7: the row's own GitHub Projects page, opened
        // in the owner's browser session via NSWorkspace (a private
        // board 404s outside that session; the app hands the browser
        // the stored sf_boards.url verbatim — no URL is constructed).
        // Presence-guarded at the value level: a board whose snapshot
        // row carries no URL gets no button.
        PortfolioTextCellView *cell = [tableView makeViewWithIdentifier:@"GitHubCell" owner:self];
        NSButton *button = nil;
        if (cell == nil) {
            CGFloat width = [tableColumn width];
            cell = [[PortfolioTextCellView alloc] initWithFrame:NSMakeRect(0, 0, width, 38)];
            [cell setIdentifier:@"GitHubCell"];
            button = [[NSButton alloc] initWithFrame:NSMakeRect(0, 9, width, 20)];
            [button setBordered:NO];
            [button setFont:[AcademyTheme metaFont]];
            [button setAttributedTitle:[[NSAttributedString alloc]
                initWithString:@"Open in GitHub"
                    attributes:@{NSFontAttributeName: [AcademyTheme metaFont],
                                 NSForegroundColorAttributeName: [AcademyTheme inkSecondaryColor]}]];
            [button setAlignment:NSTextAlignmentLeft];
            [button setTarget:self];
            [button setAction:@selector(openBoardInGitHubClicked:)];
            [button setAutoresizingMask:NSViewWidthSizable];
            [cell addSubview:button];
        } else {
            button = (NSButton *)[[cell subviews] lastObject];
        }
        BOOL hasURL = ([board.url length] > 0);
        [button setHidden:!hasURL];
        [button setEnabled:hasURL];
        [button setToolTip:hasURL
            ? [NSString stringWithFormat:@"Open in GitHub — %@", board.url] : nil];
        return cell;
    }

    if ([identifier isEqualToString:@"board"]) {
        PortfolioBoardCellView *cell = [tableView makeViewWithIdentifier:@"BoardCell" owner:self];
        if (cell == nil) {
            CGFloat width = [tableColumn width];
            cell = [[PortfolioBoardCellView alloc] initWithFrame:NSMakeRect(0, 0, width, 38)];
            [cell setIdentifier:@"BoardCell"];
            NSTextField *field = [NSTextField labelWithString:@""];
            [[field cell] setWraps:YES];
            [[field cell] setLineBreakMode:NSLineBreakByTruncatingTail];
            [field setFrame:NSMakeRect(0, 3, width, 32)];
            [field setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
            [cell setTextField:field];
            [cell addSubview:field];
        }
        [cell setTitleLine:[NSString stringWithFormat:@"#%ld  %@", (long)board.number, board.title]];
        [cell setSubLine:([board.shortDescription length] > 0) ? board.shortDescription : nil];
        [cell refreshText];
        return cell;
    }

    NSString *text = nil;
    NSFont *font = [AcademyTheme bodyFont];
    NSColor *color = [AcademyTheme inkColor];
    NSTextAlignment alignment = NSTextAlignmentLeft;
    BOOL wraps = NO;
    if ([identifier isEqualToString:@"owner"]) {
        text = board.ownerDisplay;
        color = [AcademyTheme inkSecondaryColor];
    } else if ([identifier isEqualToString:@"state"]) {
        text = board.stateDisplay;
    } else if ([identifier isEqualToString:@"items"]) {
        text = [NSString stringWithFormat:@"%ld", (long)board.itemCount];
        font = [AcademyTheme bodySemiboldFont];
        alignment = NSTextAlignmentRight;
    } else if ([identifier isEqualToString:@"split"]) {
        text = model[@"split"];
        color = [AcademyTheme inkSecondaryColor];
    } else if ([identifier isEqualToString:@"updated"]) {
        // GitHub's own last-activity day for the project (schema v10
        // data); "—" for any board the crawl has not stamped.
        text = board.updatedDisplay ?: @"—";
        font = [AcademyTheme metaFont];
        color = [AcademyTheme inkTertiaryColor];
    } else if ([identifier isEqualToString:@"status"]) {
        text = model[@"vocabulary"];
        font = [AcademyTheme metaFont];
        color = [AcademyTheme inkTertiaryColor];
        wraps = YES;
    } else {
        return nil;
    }

    NSString *cellID = [@"TextCell-" stringByAppendingString:identifier];
    PortfolioTextCellView *cell = [tableView makeViewWithIdentifier:cellID owner:self];
    if (cell == nil) {
        CGFloat width = [tableColumn width];
        cell = [[PortfolioTextCellView alloc] initWithFrame:NSMakeRect(0, 0, width, 38)];
        [cell setIdentifier:cellID];
        NSTextField *field = [NSTextField labelWithString:@""];
        [field setFrame:NSMakeRect(0, 10, width, 18)];
        [field setAutoresizingMask:NSViewWidthSizable];
        [cell setTextField:field];
        [cell addSubview:field];
    }
    NSTextField *field = [cell textField];
    [field setFont:font];
    [field setAlignment:alignment];
    [[field cell] setWraps:wraps];
    [[field cell] setLineBreakMode:wraps ? NSLineBreakByWordWrapping
                                         : NSLineBreakByTruncatingTail];
    [cell setNormalColor:color];
    [cell setSelectedColor:[AcademyTheme selectionTextColor]];
    [field setStringValue:text ?: @""];
    [field setTextColor:([cell backgroundStyle] == NSBackgroundStyleDark)
                             ? [AcademyTheme selectionTextColor] : color];
    return cell;
}

- (NSString *)tableView:(NSTableView *)tableView toolTipForCell:(NSCell *)cell rect:(NSRectPointer)rect tableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row mouseLocation:(NSPoint)mouseLocation {
    if ([[tableColumn identifier] isEqualToString:@"state"]) {
        // The cell shows the derived state (design note 04); the
        // tooltip carries the full detail incl. the raw GitHub mirror.
        BoardSummary *board = self.visibleBoards[(NSUInteger)row];
        return board.stateDetailDisplay;
    }
    if ([[tableColumn identifier] isEqualToString:@"board"]) {
        BoardSummary *board = self.visibleBoards[(NSUInteger)row];
        if ([board.shortDescription length] > 0) {
            return [NSString stringWithFormat:@"%@\n%@", board.shortDescription, board.url];
        }
        return board.url;
    }
    if ([[tableColumn identifier] isEqualToString:@"updated"]) {
        // The cell shows the day; the tooltip carries GitHub's full
        // stamp, labeled as what it is.
        BoardSummary *board = self.visibleBoards[(NSUInteger)row];
        if ([board.ghUpdatedAt length] > 0) {
            return [NSString stringWithFormat:@"GitHub project updated: %@", board.ghUpdatedAt];
        }
        return nil;
    }
    return nil;
}

@end
