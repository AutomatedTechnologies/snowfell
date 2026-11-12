#import "BoardViewController.h"
#import "SnapshotStore.h"
#import "BoardSummary.h"
#import "BoardItem.h"

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
        [[self layer] setCornerRadius:6];
        [[self layer] setBorderWidth:0.75];
        [[self layer] setBorderColor:[[NSColor colorWithWhite:0.80 alpha:1] CGColor]];
        [[self layer] setBackgroundColor:[[NSColor whiteColor] CGColor]];

        CGFloat const padding = 8;
        CGFloat const innerWidth = width - (padding * 2);
        CGFloat y = padding;

        NSFont *titleFont = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
        [paragraph setLineBreakMode:NSLineBreakByWordWrapping];
        NSRect titleRect = [item.title boundingRectWithSize:NSMakeSize(innerWidth, CGFLOAT_MAX)
                                                    options:NSStringDrawingUsesLineFragmentOrigin
                                                 attributes:@{NSFontAttributeName: titleFont,
                                                              NSParagraphStyleAttributeName: paragraph}];
        CGFloat titleHeight = MIN(ceil(titleRect.size.height), 60);
        NSTextField *titleField = [NSTextField labelWithString:item.title];
        [titleField setFont:titleFont];
        [[titleField cell] setWraps:YES];
        [[titleField cell] setLineBreakMode:NSLineBreakByTruncatingTail];
        [titleField setFrame:NSMakeRect(padding, y, innerWidth, titleHeight)];
        [self addSubview:titleField];
        y += titleHeight + 4;

        NSString *meta = item.kindDisplay;
        if (item.state != nil) {
            meta = [meta stringByAppendingFormat:@" · %@", item.state];
        }
        NSTextField *metaField = [NSTextField labelWithString:meta];
        [metaField setFont:[NSFont systemFontOfSize:11]];
        [metaField setTextColor:[NSColor secondaryLabelColor]];
        [metaField setFrame:NSMakeRect(padding, y, innerWidth, 15)];
        [self addSubview:metaField];
        y += 15;

        if ([item.labels count] > 0) {
            y += 4;
            NSTextField *labelsField = [NSTextField labelWithString:item.labelsDisplay];
            [labelsField setFont:[NSFont systemFontOfSize:11]];
            [labelsField setTextColor:[NSColor secondaryLabelColor]];
            [[labelsField cell] setLineBreakMode:NSLineBreakByTruncatingTail];
            [labelsField setFrame:NSMakeRect(padding, y, innerWidth, 15)];
            [self addSubview:labelsField];
            y += 15;
        }

        if ([statusOptions count] > 0) {
            y += 6;
            _statusPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(padding, y, innerWidth, 22)
                                                      pullsDown:NO];
            [_statusPopup addItemsWithTitles:statusOptions];
            if (item.statusName != nil) {
                [_statusPopup selectItemWithTitle:item.statusName];
            }
            [_statusPopup setFont:[NSFont systemFontOfSize:11]];
            [_statusPopup setTarget:self];
            [_statusPopup setAction:@selector(statusPopupChanged:)];
            [self addSubview:_statusPopup];
            y += 22;
        }

        _cardHeight = y + padding;
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
    [[self layer] setBorderColor:[(selected ? [NSColor blackColor] : [NSColor colorWithWhite:0.80 alpha:1]) CGColor]];
    [[self layer] setBorderWidth:selected ? 1.5 : 0.75];
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

    _boardPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(12, 620 - 36, 400, 24) pullsDown:NO];
    [_boardPopup setTarget:self];
    [_boardPopup setAction:@selector(boardPopupChanged:)];
    [_boardPopup setAutoresizingMask:NSViewMinYMargin];
    [root addSubview:_boardPopup];

    _summaryField = [NSTextField labelWithString:@""];
    [_summaryField setFont:[NSFont systemFontOfSize:12]];
    [_summaryField setTextColor:[NSColor secondaryLabelColor]];
    [_summaryField setFrame:NSMakeRect(424, 620 - 32, 536, 18)];
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

    [_summaryField setStringValue:[NSString stringWithFormat:
                                   @"Board #%ld · %@ · %@ · %lu items · %lu status columns (the board's own vocabulary)",
                                   (long)board.number, board.title, board.ownerDisplay,
                                   (unsigned long)[items count], (unsigned long)[options count]]];
    [self rebuildColumns];
}

- (void)rebuildColumns {
    for (NSView *subview in [[self.columnsView subviews] copy]) {
        [subview removeFromSuperview];
    }
    [self.cardViews removeAllObjects];

    CGFloat const columnWidth = 248;
    CGFloat const columnGap = 16;
    CGFloat const cardGap = 8;
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

        NSTextField *header = [NSTextField labelWithString:headerText];
        [header setFont:[NSFont boldSystemFontOfSize:13]];
        [header setFrame:NSMakeRect(x, 12, columnWidth, 18)];
        [self.columnsView addSubview:header];

        NSTextField *count = [NSTextField labelWithString:[NSString stringWithFormat:@"%lu items",
                                                           (unsigned long)[items count]]];
        [count setFont:[NSFont systemFontOfSize:11]];
        [count setTextColor:[NSColor secondaryLabelColor]];
        [count setFrame:NSMakeRect(x, 32, columnWidth, 15)];
        [self.columnsView addSubview:count];

        CGFloat y = 56;
        for (BoardItem *item in items) {
            BoardCardView *card = [[BoardCardView alloc] initWithItem:item
                                                                width:columnWidth - 8
                                                       statusOptions:self.statusOptions];
            [card setFrameOrigin:NSMakePoint(x, y)];
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
        tallest = MAX(tallest, y);
        x += columnWidth + columnGap;
    }

    CGFloat contentWidth = MAX(x, NSWidth([self.scrollView frame]));
    CGFloat contentHeight = MAX(tallest + 16, NSHeight([self.scrollView frame]));
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
