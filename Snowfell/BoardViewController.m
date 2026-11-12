#import "BoardViewController.h"
#import "SnapshotStore.h"
#import "BoardSummary.h"
#import "BoardItem.h"
#import "AcademyTheme.h"

// Flipped container so columns lay out from the top of the scroll view.
@interface BoardFlippedView : NSView
@end

@implementation BoardFlippedView
- (BOOL)isFlipped {
    return YES;
}
@end

// One item card: title, kind line, labels line, and (SF-T4) a Status
// popup. Click = selection. The popup is a request surface only: picking
// a different status calls onStatusChosen; the card itself mutates
// nothing and the popup is settled back to the item's snapshot status by
// the controller once the request resolves (queued or cancelled).
@interface BoardCardView : NSView
@property (nonatomic, strong) BoardItem *item;
@property (nonatomic, copy) void (^onSelect)(BoardCardView *card);
@property (nonatomic, copy) void (^onStatusChosen)(BoardCardView *card, NSString *optionName);
@property (nonatomic, assign) CGFloat cardHeight;
@property (nonatomic, assign) BOOL selected;
@property (nonatomic, strong) NSPopUpButton *statusPopup;
- (instancetype)initWithItem:(BoardItem *)item
                       width:(CGFloat)width
              statusOptions:(NSArray<NSString *> *)statusOptions;
@end

@implementation BoardCardView

- (instancetype)initWithItem:(BoardItem *)item
                       width:(CGFloat)width
              statusOptions:(NSArray<NSString *> *)statusOptions {
    self = [super initWithFrame:NSMakeRect(0, 0, width, 10)];
    if (self) {
        _item = item;
        [self setWantsLayer:YES];
        // Baseline .kcard: white panel, 1px --line border, radius 8,
        // soft 1px shadow (AcademyTheme styleCardLayer).
        [AcademyTheme styleCardLayer:[self layer]];

        CGFloat const padding = 11;
        CGFloat const bottomPadding = 10;
        CGFloat const innerWidth = width - (padding * 2);
        CGFloat y = 10;

        // Baseline card title: 13 semibold, line-height 1.35, wraps in
        // full — the test-1 card capped the title at 60px and truncated
        // the tail mid-word (owner screenshot, 2026-11-12). Cap is now
        // five full lines, far beyond any title in the snapshot.
        NSFont *titleFont = [AcademyTheme cardTitleFont];
        NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
        [paragraph setLineBreakMode:NSLineBreakByWordWrapping];
        [paragraph setLineHeightMultiple:1.35];
        NSRect titleRect = [item.title boundingRectWithSize:NSMakeSize(innerWidth, CGFLOAT_MAX)
                                                    options:NSStringDrawingUsesLineFragmentOrigin
                                                 attributes:@{NSFontAttributeName: titleFont,
                                                              NSParagraphStyleAttributeName: paragraph}];
        CGFloat titleHeight = MIN(ceil(titleRect.size.height), 92);
        NSTextField *titleField = [NSTextField labelWithString:item.title];
        [titleField setFont:titleFont];
        [titleField setTextColor:[AcademyTheme inkColor]];
        [[titleField cell] setWraps:YES];
        [[titleField cell] setLineBreakMode:NSLineBreakByWordWrapping];
        [titleField setFrame:NSMakeRect(padding, y, innerWidth, titleHeight)];
        [self addSubview:titleField];
        y += titleHeight + 5;

        NSString *meta = item.kindDisplay;
        if (item.state != nil) {
            meta = [meta stringByAppendingFormat:@" · %@", item.state];
        }
        NSTextField *metaField = [NSTextField labelWithString:meta];
        [metaField setFont:[AcademyTheme metaFont]];
        [metaField setTextColor:[AcademyTheme inkSecondaryColor]];
        [metaField setFrame:NSMakeRect(padding, y, innerWidth, 15)];
        [self addSubview:metaField];
        y += 15;

        if ([item.labels count] > 0) {
            // Baseline .kmeta: each label is its own chip pill (.lbl),
            // flowing left-to-right and wrapping inside the card.
            y += 6;
            CGFloat pillX = padding;
            CGFloat pillRowY = y;
            for (NSString *label in item.labels) {
                AcademyPillView *pill = [[AcademyPillView alloc] initWithText:label];
                CGFloat pillWidth = NSWidth([pill frame]);
                if (pillX > padding && pillX + pillWidth > padding + innerWidth) {
                    pillX = padding;
                    pillRowY += 16 + 4;
                }
                [pill setFrameOrigin:NSMakePoint(pillX, pillRowY)];
                [self addSubview:pill];
                pillX += pillWidth + 6;
            }
            y = pillRowY + 16;
        }

        if ([statusOptions count] > 0) {
            y += 6;
            _statusPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(padding, y, innerWidth, 20)
                                                      pullsDown:NO];
            [_statusPopup addItemsWithTitles:statusOptions];
            if (item.statusName != nil) {
                [_statusPopup selectItemWithTitle:item.statusName];
            }
            [_statusPopup setControlSize:NSSmallControlSize];
            [_statusPopup setFont:[AcademyTheme metaFont]];
            [_statusPopup setTarget:self];
            [_statusPopup setAction:@selector(statusPopupChanged:)];
            [self addSubview:_statusPopup];
            y += 20;
        }

        _cardHeight = y + bottomPadding;
        [self setFrameSize:NSMakeSize(width, _cardHeight)];
    }
    return self;
}

- (void)statusPopupChanged:(id)sender {
    NSString *optionName = [_statusPopup titleOfSelectedItem];
    if (optionName == nil || [optionName isEqualToString:(self.item.statusName ?: @"")]) {
        return;
    }
    if (self.onStatusChosen != nil) {
        self.onStatusChosen(self, optionName);
    }
}

- (void)setSelected:(BOOL)selected {
    _selected = selected;
    [[self layer] setBorderColor:[(selected ? [AcademyTheme inkColor] : [AcademyTheme lineColor]) CGColor]];
    [[self layer] setBorderWidth:selected ? 1.5 : 1.0];
}

- (void)mouseDown:(NSEvent *)event {
    if (self.onSelect != nil) {
        self.onSelect(self);
    }
}

@end

@interface BoardViewController ()
@property (nonatomic, strong, readwrite) SnapshotStore *snapshotStore;
@property (nonatomic, strong, readwrite, nullable) BoardSummary *currentBoard;
@property (nonatomic, strong, readwrite, nullable) BoardItem *selectedItem;
@property (nonatomic, strong) NSPopUpButton *boardPopup;
@property (nonatomic, strong) NSTextField *summaryField;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) BoardFlippedView *columnsView;
@property (nonatomic, copy) NSArray<BoardSummary *> *allBoards;
@property (nonatomic, copy) NSArray<NSString *> *statusOptions;
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<BoardItem *> *> *itemsByStatus;
@property (nonatomic, strong) NSMutableArray<BoardCardView *> *cardViews;
@end

@implementation BoardViewController

- (instancetype)initWithSnapshotStore:(SnapshotStore *)store {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _snapshotStore = store;
        _allBoards = @[];
        _statusOptions = @[];
        _itemsByStatus = @{};
        _cardViews = [NSMutableArray array];
    }
    return self;
}

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1080, 620)];
    [root setWantsLayer:YES];
    [[root layer] setBackgroundColor:[[AcademyTheme windowColor] CGColor]];

    _boardPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(12, 620 - 36, 400, 24) pullsDown:NO];
    [_boardPopup setFont:[AcademyTheme bodyFont]];
    [_boardPopup setTarget:self];
    [_boardPopup setAction:@selector(boardPopupChanged:)];
    [_boardPopup setAutoresizingMask:NSViewMinYMargin];
    [root addSubview:_boardPopup];

    _summaryField = [NSTextField labelWithString:@""];
    [_summaryField setFont:[AcademyTheme bodyFont]];
    [_summaryField setTextColor:[AcademyTheme inkSecondaryColor]];
    [_summaryField setFrame:NSMakeRect(424, 620 - 33, 536, 20)];
    [_summaryField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:_summaryField];

    // SF-T4: create request. Enqueues a create_item mutation locally
    // (via createItemRequestHandler + the AppDelegate confirm sheet);
    // creates nothing on GitHub.
    NSButton *newItemButton = [[NSButton alloc] initWithFrame:NSMakeRect(972, 620 - 38, 96, 28)];
    [newItemButton setTitle:@"New Item…"];
    [newItemButton setBezelStyle:NSBezelStyleRounded];
    [newItemButton setTarget:self];
    [newItemButton setAction:@selector(newItemClicked:)];
    [newItemButton setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
    [root addSubview:newItemButton];

    _scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 1080, 620 - 44)];
    [_scrollView setHasVerticalScroller:YES];
    [_scrollView setHasHorizontalScroller:YES];
    [_scrollView setBorderType:NSNoBorder];
    [_scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    _columnsView = [[BoardFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 1080, 620 - 44)];
    [_columnsView setWantsLayer:YES];
    [[_columnsView layer] setBackgroundColor:[[AcademyTheme windowColor] CGColor]];
    [_scrollView setDrawsBackground:YES];
    [_scrollView setBackgroundColor:[AcademyTheme windowColor]];
    [_scrollView setDocumentView:_columnsView];
    [root addSubview:_scrollView];

    self.view = root;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self reloadBoards];
}

#pragma mark - Board list + switcher

- (void)reloadBoards {
    NSError *error = nil;
    NSArray<BoardSummary *> *boards = [self.snapshotStore portfolioBoardsWithError:&error];
    if (boards == nil) {
        self.allBoards = @[];
        [_boardPopup removeAllItems];
        [_summaryField setStringValue:[NSString stringWithFormat:
                                       @"Board unavailable — %@",
                                       (error != nil) ? error.localizedDescription : @"unknown error"]];
        return;
    }
    self.allBoards = boards;

    [_boardPopup removeAllItems];
    for (BoardSummary *board in boards) {
        NSString *title = [NSString stringWithFormat:@"%@ #%ld — %@",
                           board.ownerLogin, (long)board.number, board.title];
        [_boardPopup addItemWithTitle:title];
        NSMenu *menu = [_boardPopup menu];
        [[menu itemAtIndex:[menu numberOfItems] - 1] setRepresentedObject:board];
    }

    BoardSummary *target = nil;
    if (self.currentBoard != nil) {
        for (BoardSummary *board in boards) {
            if ([board.nodeID isEqualToString:self.currentBoard.nodeID]) {
                target = board;
                break;
            }
        }
    }
    if (target == nil) {
        target = [self defaultBoard];
    }
    if (target != nil) {
        [_boardPopup selectItemWithTitle:[NSString stringWithFormat:@"%@ #%ld — %@",
                                          target.ownerLogin, (long)target.number, target.title]];
        [self showBoard:target];
    }
}

- (BoardSummary *)defaultBoard {
    // Default: user board #3 — the largest board in the snapshot.
    for (BoardSummary *board in self.allBoards) {
        if ([board.ownerType isEqualToString:@"user"] && board.number == 3) {
            return board;
        }
    }
    return [self.allBoards firstObject];
}

- (void)boardPopupChanged:(id)sender {
    BoardSummary *board = [[_boardPopup selectedItem] representedObject];
    if (board != nil) {
        [self showBoard:board];
    }
}

#pragma mark - Board rendering

- (void)showBoard:(BoardSummary *)board {
    self.currentBoard = board;
    self.selectedItem = nil;
    [self.cardViews removeAllObjects];

    NSError *error = nil;
    NSArray<NSString *> *options = [self.snapshotStore statusOptionsForBoard:board.nodeID error:&error];
    NSArray<BoardItem *> *items = [self.snapshotStore itemsForBoard:board.nodeID error:&error];
    if (options == nil || items == nil) {
        [_summaryField setStringValue:[NSString stringWithFormat:
                                       @"Board unavailable — %@",
                                       (error != nil) ? error.localizedDescription : @"unknown error"]];
        [self rebuildColumns];
        return;
    }
    self.statusOptions = options;

    NSMutableDictionary<NSString *, NSMutableArray<BoardItem *> *> *grouped = [NSMutableDictionary dictionary];
    for (NSString *option in options) {
        grouped[option] = [NSMutableArray array];
    }
    NSMutableArray<BoardItem *> *noStatus = [NSMutableArray array];
    for (BoardItem *item in items) {
        if (item.statusName != nil && grouped[item.statusName] != nil) {
            [grouped[item.statusName] addObject:item];
        } else {
            [noStatus addObject:item];
        }
    }
    NSMutableDictionary<NSString *, NSArray<BoardItem *> *> *frozen = [NSMutableDictionary dictionary];
    for (NSString *option in options) {
        frozen[option] = grouped[option];
    }
    if ([noStatus count] > 0) {
        frozen[@""] = noStatus;
    }
    self.itemsByStatus = frozen;

    // Baseline titlebar composition: the board's name leads in semibold
    // ink; the facts follow in regular secondary ink.
    NSMutableAttributedString *summary = [[NSMutableAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"Board #%ld · %@", (long)board.number, board.title]
            attributes:@{NSFontAttributeName: [AcademyTheme bodySemiboldFont],
                         NSForegroundColorAttributeName: [AcademyTheme inkColor]}];
    [summary appendAttributedString:[[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:
                        @" · %@ · %lu items · %lu status columns (the board's own vocabulary)",
                        board.ownerDisplay,
                        (unsigned long)[items count], (unsigned long)[options count]]
            attributes:@{NSFontAttributeName: [AcademyTheme bodyFont],
                         NSForegroundColorAttributeName: [AcademyTheme inkSecondaryColor]}]];
    [_summaryField setAttributedStringValue:summary];
    [self rebuildColumns];
}

- (void)rebuildColumns {
    for (NSView *subview in [[self.columnsView subviews] copy]) {
        [subview removeFromSuperview];
    }
    [self.cardViews removeAllObjects];

    // Baseline .col geometry: the column is a tinted well (panel2 fill,
    // 1px --line border, radius 9, 9px inner padding); its header is the
    // letterspaced uppercase status name at left with the bare item count
    // at right, on one line; cards stack inside at 9px gaps.
    CGFloat const columnWidth = 264;
    CGFloat const columnGap = 12;
    CGFloat const cardGap = 9;
    CGFloat const wellTop = 12;
    CGFloat const wellPadding = 9;
    CGFloat x = columnGap;

    NSMutableArray<NSString *> *columns = [self.statusOptions mutableCopy];
    if ([self.itemsByStatus[@""] count] > 0) {
        // Defensive only — the v7-0026 import values every item's Status.
        [columns addObject:@""];
    }

    CGFloat tallest = 0;
    for (NSString *option in columns) {
        NSArray<BoardItem *> *items = self.itemsByStatus[option];
        NSString *headerText = ([option length] > 0) ? option : @"No status value";

        // Cards first: the well's height is their stacked height.
        NSMutableArray<BoardCardView *> *cards = [NSMutableArray array];
        CGFloat cardsHeight = 0;
        for (BoardItem *item in items) {
            BoardCardView *card = [[BoardCardView alloc] initWithItem:item
                                                                width:columnWidth - (wellPadding * 2)
                                                       statusOptions:self.statusOptions];
            [cards addObject:card];
            cardsHeight += card.cardHeight + cardGap;
        }
        if ([cards count] > 0) {
            cardsHeight -= cardGap;
        }
        CGFloat wellHeight = 10 + 18 + 10 + cardsHeight + wellPadding;

        NSView *well = [[NSView alloc] initWithFrame:NSMakeRect(x, wellTop, columnWidth, wellHeight)];
        [well setWantsLayer:YES];
        [AcademyTheme styleWellLayer:[well layer]];
        [self.columnsView addSubview:well];

        NSTextField *header = [NSTextField labelWithString:@""];
        [header setAttributedStringValue:[AcademyTheme capsString:headerText
                                                              font:[AcademyTheme columnHeaderFont]
                                                             color:[AcademyTheme inkColor]]];
        [header setFrame:NSMakeRect(x + wellPadding + 4, wellTop + 10, columnWidth - 60, 18)];
        [self.columnsView addSubview:header];

        NSTextField *count = [NSTextField labelWithString:[NSString stringWithFormat:@"%lu",
                                                           (unsigned long)[items count]]];
        [count setFont:[AcademyTheme metaFont]];
        [count setTextColor:[AcademyTheme inkTertiaryColor]];
        [count setAlignment:NSTextAlignmentRight];
        [count setFrame:NSMakeRect(x + columnWidth - wellPadding - 44, wellTop + 11, 40, 15)];
        [self.columnsView addSubview:count];

        CGFloat y = wellTop + 38;
        for (BoardCardView *card in cards) {
            [card setFrameOrigin:NSMakePoint(x + wellPadding, y)];
            __weak BoardViewController *weakSelf = self;
            card.onSelect = ^(BoardCardView *selectedCard) {
                [weakSelf selectCard:selectedCard];
            };
            card.onStatusChosen = ^(BoardCardView *chosenCard, NSString *optionName) {
                [weakSelf requestStatusMoveForItem:chosenCard.item toStatus:optionName];
            };
            [self.columnsView addSubview:card];
            [self.cardViews addObject:card];
            y += card.cardHeight + cardGap;
        }
        tallest = MAX(tallest, wellTop + wellHeight);
        x += columnWidth + columnGap;
    }

    CGFloat contentWidth = MAX(x, NSWidth([self.scrollView frame]));
    CGFloat contentHeight = MAX(tallest + 12, NSHeight([self.scrollView frame]));
    [self.columnsView setFrameSize:NSMakeSize(contentWidth, contentHeight)];
}

#pragma mark - SF-T4 write-back requests (queue-only)

- (void)requestStatusMoveForItem:(BoardItem *)item toStatus:(NSString *)optionName {
    BoardSummary *board = self.currentBoard;
    if (board == nil || self.statusMoveRequestHandler == nil) {
        [self rebuildColumns];  // settle the popup back to the snapshot status
        return;
    }
    __weak BoardViewController *weakSelf = self;
    self.statusMoveRequestHandler(item, board, optionName, ^(BOOL enqueued) {
        // Queued or cancelled: the on-screen status is the SNAPSHOT's
        // until a send lands and a resync replaces it, so the columns
        // (and the popup) are rebuilt from the snapshot either way.
        [weakSelf rebuildColumns];
    });
}

- (void)newItemClicked:(id)sender {
    BoardSummary *board = self.currentBoard;
    if (board == nil || self.createItemRequestHandler == nil) {
        NSBeep();
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:[NSString stringWithFormat:@"New item on %@", board.title]];
    [alert setInformativeText:@"The item is created as a GitHub draft issue when the queued mutation is eventually sent. Nothing is created now."];
    [alert addButtonWithTitle:@"Continue…"];
    [alert addButtonWithTitle:@"Cancel"];

    NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 54)];
    NSTextField *titleField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 30, 300, 24)];
    [titleField setPlaceholderString:@"Item title"];
    [accessory addSubview:titleField];
    NSPopUpButton *statusPopup = nil;
    if ([self.statusOptions count] > 0) {
        statusPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 300, 24) pullsDown:NO];
        [statusPopup addItemsWithTitles:self.statusOptions];
        [accessory addSubview:statusPopup];
    }
    [alert setAccessoryView:accessory];

    NSWindow *window = [self.view window];
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse result) {
        if (result != NSAlertFirstButtonReturn) {
            return;
        }
        NSString *title = [[titleField stringValue] stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([title length] == 0) {
            NSBeep();
            return;
        }
        NSString *optionName = (statusPopup != nil) ? [statusPopup titleOfSelectedItem] : nil;
        if (self.createItemRequestHandler != nil) {
            self.createItemRequestHandler(board, title, optionName);
        }
    }];
}

#pragma mark - Selection

- (void)selectCard:(BoardCardView *)card {
    for (BoardCardView *other in self.cardViews) {
        [other setSelected:(other == card)];
    }
    self.selectedItem = card.item;
    [self.delegate boardViewController:self didSelectItem:card.item];
}

@end
