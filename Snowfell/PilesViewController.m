#import "PilesViewController.h"
#import "PileStore.h"
#import "SnapshotStore.h"
#import "BoardItem.h"

static NSString * const PilesDragType = @"com.detroitautomationacademy.snowfell.pile-item";

@interface PilesViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong, readwrite) PileStore *pileStore;
@property (nonatomic, strong, readwrite, nullable) SnapshotStore *snapshotStore;
@property (nonatomic, copy) NSArray<Pile *> *piles;
@property (nonatomic, copy) NSArray<PileItem *> *stackItems;
@property (nonatomic, strong, nullable) Pile *selectedPile;
@property (nonatomic, strong) NSTableView *pileTable;
@property (nonatomic, strong) NSTableView *stackTable;
@property (nonatomic, strong) NSTextField *headerField;
@property (nonatomic, strong) NSTextField *nextActionTitleField;
@property (nonatomic, strong) NSTextField *nextActionBoardField;
@property (nonatomic, strong) NSTextField *stackStateField;
@property (nonatomic, strong) NSPopUpButton *cardMovePopup;
@property (nonatomic, strong) NSView *nextActionCard;
@end

@implementation PilesViewController

- (instancetype)initWithPileStore:(PileStore *)pileStore
                  snapshotStore:(SnapshotStore *)snapshotStore {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _pileStore = pileStore;
        _snapshotStore = snapshotStore;
        _piles = @[];
        _stackItems = @[];
    }
    return self;
}

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1180, 720)];

    _headerField = [NSTextField labelWithString:@""];
    [_headerField setFont:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]];
    [_headerField setFrame:NSMakeRect(16, 720 - 34, 1148, 18)];
    [_headerField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:_headerField];

    // — Left: the pile list (name + count + top item) —
    NSScrollView *pileScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 52, 340, 720 - 110)];
    [pileScroll setHasVerticalScroller:YES];
    [pileScroll setBorderType:NSBezelBorder];
    [pileScroll setAutoresizingMask:NSViewHeightSizable];
    _pileTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 340, 600)];
    NSTableColumn *pileColumn = [[NSTableColumn alloc] initWithIdentifier:@"pile"];
    [pileColumn setTitle:@"Piles"];
    [pileColumn setWidth:324];
    [_pileTable addTableColumn:pileColumn];
    [_pileTable setDataSource:self];
    [_pileTable setDelegate:self];
    [_pileTable setHeaderView:nil];
    [_pileTable setRowHeight:36];
    [_pileTable setTarget:self];
    [_pileTable setAction:@selector(pileSelectionChanged:)];
    [pileScroll setDocumentView:_pileTable];
    [root addSubview:pileScroll];

    NSButton *newButton = [[NSButton alloc] initWithFrame:NSMakeRect(16, 16, 100, 28)];
    [newButton setTitle:@"New Pile…"];
    [newButton setBezelStyle:NSBezelStyleRounded];
    [newButton setTarget:self];
    [newButton setAction:@selector(newPileClicked:)];
    [root addSubview:newButton];

    NSButton *renameButton = [[NSButton alloc] initWithFrame:NSMakeRect(122, 16, 90, 28)];
    [renameButton setTitle:@"Rename…"];
    [renameButton setBezelStyle:NSBezelStyleRounded];
    [renameButton setTarget:self];
    [renameButton setAction:@selector(renamePileClicked:)];
    [root addSubview:renameButton];

    NSButton *deleteButton = [[NSButton alloc] initWithFrame:NSMakeRect(218, 16, 90, 28)];
    [deleteButton setTitle:@"Delete"];
    [deleteButton setBezelStyle:NSBezelStyleRounded];
    [deleteButton setTarget:self];
    [deleteButton setAction:@selector(deletePileClicked:)];
    [root addSubview:deleteButton];

    // — Right: NEXT ACTION card + the stack —
    _nextActionCard = [[NSView alloc] initWithFrame:NSMakeRect(372, 720 - 150, 792, 92)];
    [_nextActionCard setWantsLayer:YES];
    [[_nextActionCard layer] setBorderWidth:1.0];
    [[_nextActionCard layer] setBorderColor:[[NSColor colorWithWhite:0.80 alpha:1.0] CGColor]];
    [[_nextActionCard layer] setCornerRadius:8];
    [_nextActionCard setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    NSTextField *cardLabel = [NSTextField labelWithString:@"NEXT ACTION"];
    [cardLabel setFont:[NSFont boldSystemFontOfSize:11]];
    [cardLabel setFrame:NSMakeRect(12, 64, 200, 16)];
    [_nextActionCard addSubview:cardLabel];
    _nextActionTitleField = [NSTextField labelWithString:@""];
    [_nextActionTitleField setFont:[NSFont systemFontOfSize:14 weight:NSFontWeightSemibold]];
    [_nextActionTitleField setFrame:NSMakeRect(12, 38, 560, 20)];
    [_nextActionTitleField setAutoresizingMask:NSViewWidthSizable];
    [_nextActionCard addSubview:_nextActionTitleField];
    _nextActionBoardField = [NSTextField labelWithString:@""];
    [_nextActionBoardField setFont:[NSFont systemFontOfSize:12]];
    [_nextActionBoardField setTextColor:[NSColor secondaryLabelColor]];
    [_nextActionBoardField setFrame:NSMakeRect(12, 16, 560, 16)];
    [_nextActionCard addSubview:_nextActionBoardField];
    _cardMovePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(588, 48, 190, 26) pullsDown:NO];
    [_cardMovePopup setTitle:@"Move to Pile…"];
    [_cardMovePopup setTarget:self];
    [_cardMovePopup setAction:@selector(cardMovePopupChanged:)];
    [_cardMovePopup setAutoresizingMask:NSViewMinXMargin];
    [_nextActionCard addSubview:_cardMovePopup];
    NSButton *clearButton = [[NSButton alloc] initWithFrame:NSMakeRect(588, 12, 92, 28)];
    [clearButton setTitle:@"Clear Top"];
    [clearButton setBezelStyle:NSBezelStyleRounded];
    [clearButton setTarget:self];
    [clearButton setAction:@selector(clearTopClicked:)];
    [clearButton setAutoresizingMask:NSViewMinXMargin];
    [_nextActionCard addSubview:clearButton];
    NSButton *makeTopButton = [[NSButton alloc] initWithFrame:NSMakeRect(686, 12, 92, 28)];
    [makeTopButton setTitle:@"Make Top"];
    [makeTopButton setBezelStyle:NSBezelStyleRounded];
    [makeTopButton setTarget:self];
    [makeTopButton setAction:@selector(makeTopClicked:)];
    [makeTopButton setAutoresizingMask:NSViewMinXMargin];
    [_nextActionCard addSubview:makeTopButton];
    [root addSubview:_nextActionCard];

    _stackStateField = [NSTextField labelWithString:@""];
    [_stackStateField setFont:[NSFont systemFontOfSize:12]];
    [_stackStateField setTextColor:[NSColor secondaryLabelColor]];
    [_stackStateField setFrame:NSMakeRect(372, 720 - 176, 792, 16)];
    [_stackStateField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:_stackStateField];

    NSScrollView *stackScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(372, 16, 792, 720 - 196)];
    [stackScroll setHasVerticalScroller:YES];
    [stackScroll setBorderType:NSBezelBorder];
    [stackScroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    _stackTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 792, 500)];
    NSTableColumn *positionColumn = [[NSTableColumn alloc] initWithIdentifier:@"position"];
    [positionColumn setTitle:@"#"];
    [positionColumn setWidth:44];
    [_stackTable addTableColumn:positionColumn];
    NSTableColumn *titleColumn = [[NSTableColumn alloc] initWithIdentifier:@"title"];
    [titleColumn setTitle:@"Item"];
    [titleColumn setWidth:480];
    [_stackTable addTableColumn:titleColumn];
    NSTableColumn *boardColumn = [[NSTableColumn alloc] initWithIdentifier:@"board"];
    [boardColumn setTitle:@"Board"];
    [boardColumn setWidth:150];
    [_stackTable addTableColumn:boardColumn];
    NSTableColumn *moveColumn = [[NSTableColumn alloc] initWithIdentifier:@"move"];
    [moveColumn setTitle:@"Move to Pile…"];
    [moveColumn setWidth:100];
    [_stackTable addTableColumn:moveColumn];
    [_stackTable setDataSource:self];
    [_stackTable setDelegate:self];
    [_stackTable setTarget:self];
    [_stackTable setDoubleAction:@selector(stackDoubleClicked:)];
    [_stackTable registerForDraggedTypes:@[PilesDragType]];
    // Row popup: Move to Pile... / Make Top / Clear Top on every row.
    NSMenu *rowMenu = [[NSMenu alloc] initWithTitle:@"Pile Item"];
    NSMenuItem *rowMove = [[NSMenuItem alloc] initWithTitle:@"Move to Pile…"
                                                     action:@selector(stackRowMoveClicked:)
                                              keyEquivalent:@""];
    [rowMove setTarget:self];
    [rowMenu addItem:rowMove];
    NSMenuItem *rowTop = [[NSMenuItem alloc] initWithTitle:@"Make Top"
                                                    action:@selector(makeTopClicked:)
                                             keyEquivalent:@""];
    [rowTop setTarget:self];
    [rowMenu addItem:rowTop];
    NSMenuItem *rowClear = [[NSMenuItem alloc] initWithTitle:@"Clear Top"
                                                      action:@selector(clearTopClicked:)
                                               keyEquivalent:@""];
    [rowClear setTarget:self];
    [rowMenu addItem:rowClear];
    [_stackTable setMenu:rowMenu];
    [stackScroll setDocumentView:_stackTable];
    [root addSubview:stackScroll];

    self.view = root;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self reloadPiles];
}

#pragma mark - Loading / rendering

- (void)reloadPiles {
    if (self.pileStore == nil) {
        [_headerField setStringValue:@"Piles unavailable — the local pile store could not be opened."];
        return;
    }
    NSError *error = nil;
    [self.pileStore materializeAndReconcileWithError:&error];
    NSArray<Pile *> *piles = [self.pileStore pilesWithError:&error];
    if (piles == nil) {
        [_headerField setStringValue:[NSString stringWithFormat:
                                      @"Piles unavailable — %@",
                                      (error != nil) ? error.localizedDescription : @"unknown error"]];
        return;
    }
    int64_t selectedID = (self.selectedPile != nil) ? self.selectedPile.pileID : -1;
    self.piles = piles;
    Pile *selection = nil;
    for (Pile *pile in piles) {
        if (pile.pileID == selectedID) {
            selection = pile;
            break;
        }
    }
    if (selection == nil) {
        selection = [piles firstObject];
    }
    self.selectedPile = selection;
    NSInteger total = 0;
    for (Pile *pile in piles) {
        total += pile.itemCount;
    }
    [_headerField setStringValue:[NSString stringWithFormat:
                                  @"Piles — %lu pile(s) · %ld item(s) · every item in exactly one pile",
                                  (unsigned long)[piles count], (long)total]];
    [_pileTable reloadData];
    if (selection != nil) {
        NSInteger row = (NSInteger)[piles indexOfObject:selection];
        [_pileTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]
                byExtendingSelection:NO];
    }
    [self reloadStack];
}

- (void)reloadStack {
    NSError *error = nil;
    if (self.selectedPile == nil) {
        self.stackItems = @[];
    } else {
        NSArray<PileItem *> *items = [self.pileStore itemsForPile:self.selectedPile.pileID error:&error];
        self.stackItems = (items != nil) ? items : @[];
    }
    [_stackTable reloadData];
    [self renderNextActionCard];
}

- (void)renderNextActionCard {
    // Card move popup: every pile, rebuilt on each render.
    [_cardMovePopup removeAllItems];
    [_cardMovePopup addItemWithTitle:@"Move to Pile…"];
    [[_cardMovePopup lastItem] setEnabled:NO];
    for (Pile *pile in self.piles) {
        [_cardMovePopup addItemWithTitle:pile.name];
        [[_cardMovePopup lastItem] setRepresentedObject:@(pile.pileID)];
    }
    [_cardMovePopup selectItemAtIndex:0];
    PileItem *top = [self.stackItems firstObject];
    if (self.selectedPile == nil) {
        [_nextActionTitleField setStringValue:@""];
        [_nextActionBoardField setStringValue:@""];
        [_stackStateField setStringValue:@""];
        return;
    }
    if (top == nil) {
        [_nextActionTitleField setStringValue:@"Empty — this pile is done."];
        [_nextActionBoardField setStringValue:@""];
        if ([self.selectedPile.kind isEqualToString:PileKindSystemInbox]) {
            [_stackStateField setStringValue:@"Inbox empty — triage complete. Empty — this pile is done."];
        } else {
            [_stackStateField setStringValue:@"Empty — this pile is done."];
        }
        return;
    }
    [_nextActionTitleField setStringValue:top.title];
    [_nextActionBoardField setStringValue:top.boardTitle];
    [_stackStateField setStringValue:[NSString stringWithFormat:
                                      @"%@ — %lu item(s); the top is the next action",
                                      self.selectedPile.name, (unsigned long)[self.stackItems count]]];
}

#pragma mark - Table data source / delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == _pileTable) {
        return (NSInteger)[self.piles count];
    }
    return (NSInteger)[self.stackItems count];
}

- (id)tableView:(NSTableView *)tableView
objectValueForTableColumn:(NSTableColumn *)tableColumn
            row:(NSInteger)row {
    if (tableView == _pileTable) {
        Pile *pile = self.piles[(NSUInteger)row];
        NSString *top = (pile.topItemTitle != nil) ? pile.topItemTitle : @"—";
        return [NSString stringWithFormat:@"%@ (%ld) — %@", pile.name, (long)pile.itemCount, top];
    }
    PileItem *item = self.stackItems[(NSUInteger)row];
    NSString *identifier = [tableColumn identifier];
    if ([identifier isEqualToString:@"position"]) {
        return [NSString stringWithFormat:@"%ld", (long)(item.position + 1)];
    }
    if ([identifier isEqualToString:@"board"]) {
        return item.boardTitle;
    }
    if ([identifier isEqualToString:@"move"]) {
        return @"Move to Pile…";
    }
    return (row == 0) ? [NSString stringWithFormat:@"%@  ★ top", item.title] : item.title;
}

- (void)pileSelectionChanged:(id)sender {
    NSInteger row = [_pileTable selectedRow];
    if (row < 0 || row >= (NSInteger)[self.piles count]) {
        return;
    }
    self.selectedPile = self.piles[(NSUInteger)row];
    [self reloadStack];
}

#pragma mark - Within-stack drag reorder (cross-pile drag NOT shipped)

- (BOOL)tableView:(NSTableView *)tableView
writeRowsWithIndexes:(NSIndexSet *)rowIndexes
     toPasteboard:(NSPasteboard *)pasteboard {
    if (tableView != _stackTable) {
        return NO;
    }
    NSInteger row = (NSInteger)[rowIndexes firstIndex];
    if (row < 0 || row >= (NSInteger)[self.stackItems count]) {
        return NO;
    }
    PileItem *item = self.stackItems[(NSUInteger)row];
    [pasteboard setString:item.itemNodeID forType:PilesDragType];
    return YES;
}

- (NSDragOperation)tableView:(NSTableView *)tableView
                validateDrop:(id<NSDraggingInfo>)info
                 proposedRow:(NSInteger)row
       proposedDropOperation:(NSTableViewDropOperation)dropOperation {
    if (tableView != _stackTable || dropOperation != NSTableViewDropAbove) {
        return NSDragOperationNone;
    }
    return NSDragOperationMove;
}

- (BOOL)tableView:(NSTableView *)tableView
       acceptDrop:(id<NSDraggingInfo>)info
              row:(NSInteger)row
    dropOperation:(NSTableViewDropOperation)dropOperation {
    NSString *itemNodeID = [[info draggingPasteboard] stringForType:PilesDragType];
    if (itemNodeID == nil) {
        return NO;
    }
    NSInteger target = row;
    // Dropping below the dragged row shifts the destination by one.
    for (PileItem *item in self.stackItems) {
        if ([item.itemNodeID isEqualToString:itemNodeID] && item.position < row) {
            target = row - 1;
            break;
        }
    }
    NSError *error = nil;
    BOOL ok = [self.pileStore moveItem:itemNodeID toPosition:target error:&error];
    if (ok) {
        [self reloadPilesKeepingSelection];
    }
    return ok;
}

#pragma mark - Actions

- (void)reloadPilesKeepingSelection {
    int64_t selectedID = (self.selectedPile != nil) ? self.selectedPile.pileID : -1;
    [self reloadPiles];
    (void)selectedID;
}

- (PileItem *)selectedStackItem {
    NSInteger row = [_stackTable selectedRow];
    if (row < 0 || row >= (NSInteger)[self.stackItems count]) {
        return nil;
    }
    return self.stackItems[(NSUInteger)row];
}

- (void)presentError:(NSError *)error title:(NSString *)title {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:title];
    [alert setInformativeText:(error != nil) ? error.localizedDescription : @"unknown error"];
    [alert beginSheetModalForWindow:[self.view window] completionHandler:nil];
}

- (void)moveItem:(PileItem *)item toPile:(Pile *)pile {
    if (item == nil || pile == nil) {
        return;
    }
    NSError *error = nil;
    if (![self.pileStore moveItem:item.itemNodeID toPile:pile.pileID error:&error]) {
        [self presentError:error title:@"Item not moved"];
        return;
    }
    [self reloadPiles];
}

- (void)showMoveMenuForItem:(PileItem *)item fromView:(NSView *)view {
    if (item == nil) {
        NSBeep();
        return;
    }
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Move to Pile…"];
    for (Pile *pile in self.piles) {
        NSMenuItem *entry = [[NSMenuItem alloc] initWithTitle:pile.name
                                                       action:@selector(moveMenuItemChosen:)
                                                keyEquivalent:@""];
        [entry setTarget:self];
        [entry setRepresentedObject:@{@"item": item.itemNodeID, @"pile": @(pile.pileID)}];
        [menu addItem:entry];
    }
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, 0) inView:view];
}

- (void)moveMenuItemChosen:(id)sender {
    NSDictionary *payload = [(NSMenuItem *)sender representedObject];
    NSString *itemNodeID = payload[@"item"];
    int64_t pileID = [payload[@"pile"] longLongValue];
    NSError *error = nil;
    Pile *pile = [self.pileStore pileWithID:pileID error:&error];
    PileItem *item = nil;
    for (PileItem *candidate in self.stackItems) {
        if ([candidate.itemNodeID isEqualToString:itemNodeID]) {
            item = candidate;
            break;
        }
    }
    if (item == nil) {
        // The item may live in another pile (card moves the top item).
        item = [[PileItem alloc] init];
        item.itemNodeID = itemNodeID;
    }
    [self moveItem:item toPile:pile];
}

- (void)moveSelectedItemToPile:(id)sender {
    [self showMoveMenuForItem:[self selectedStackItem] fromView:_stackTable];
}

// Row-level Move to Pile... — invoked from the stack table's menu.
- (void)stackRowMoveClicked:(id)sender {
    [self showMoveMenuForItem:[self selectedStackItem] fromView:_stackTable];
}

- (void)cardMovePopupChanged:(id)sender {
    NSMenuItem *chosen = [_cardMovePopup selectedItem];
    NSNumber *pileID = [chosen representedObject];
    PileItem *top = [self.stackItems firstObject];
    if (pileID == nil || top == nil) {
        return;
    }
    NSError *error = nil;
    Pile *pile = [self.pileStore pileWithID:[pileID longLongValue] error:&error];
    [self moveItem:top toPile:pile];
}

- (void)makeTopClicked:(id)sender {
    PileItem *item = [self selectedStackItem];
    if (item == nil) {
        item = [self.stackItems firstObject];
    }
    if (item == nil) {
        NSBeep();
        return;
    }
    NSError *error = nil;
    if (![self.pileStore makeTopItem:item.itemNodeID error:&error]) {
        [self presentError:error title:@"Item not promoted"];
        return;
    }
    [self reloadPiles];
}

- (void)clearTopClicked:(id)sender {
    if (self.selectedPile == nil) {
        return;
    }
    NSError *error = nil;
    if (![self.pileStore clearTopOfPile:self.selectedPile.pileID error:&error]) {
        if (error != nil) {
            [self presentError:error title:@"Top not cleared"];
        }
        return;
    }
    [self reloadPiles];
}

- (void)stackDoubleClicked:(id)sender {
    PileItem *item = [self selectedStackItem];
    if (item == nil || self.itemActivationHandler == nil || self.snapshotStore == nil) {
        return;
    }
    NSError *error = nil;
    BoardItem *boardItem = [self.snapshotStore itemWithNodeID:item.itemNodeID error:&error];
    if (boardItem != nil) {
        self.itemActivationHandler(boardItem);
    }
}

#pragma mark - Custom piles

- (NSString *)promptForNameWithTitle:(NSString *)title initial:(NSString *)initial {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:title];
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    [field setStringValue:(initial != nil) ? initial : @""];
    [alert setAccessoryView:field];
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return nil;
    }
    NSString *name = [[field stringValue] stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return ([name length] > 0) ? name : nil;
}

- (void)newPileClicked:(id)sender {
    NSString *name = [self promptForNameWithTitle:@"New Pile" initial:nil];
    if (name == nil) {
        return;
    }
    NSError *error = nil;
    if ([self.pileStore createPileWithName:name error:&error] < 0) {
        [self presentError:error title:@"Pile not created"];
        return;
    }
    [self reloadPiles];
}

- (void)renamePileClicked:(id)sender {
    if (self.selectedPile == nil) {
        NSBeep();
        return;
    }
    NSString *name = [self promptForNameWithTitle:@"Rename Pile" initial:self.selectedPile.name];
    if (name == nil) {
        return;
    }
    NSError *error = nil;
    if (![self.pileStore renamePile:self.selectedPile.pileID name:name error:&error]) {
        [self presentError:error title:@"Pile not renamed"];
        return;
    }
    [self reloadPiles];
}

- (void)deletePileClicked:(id)sender {
    if (self.selectedPile == nil) {
        NSBeep();
        return;
    }
    NSError *error = nil;
    if (![self.pileStore deletePile:self.selectedPile.pileID error:&error]) {
        [self presentError:error title:@"Pile not deleted"];
        return;
    }
    self.selectedPile = nil;
    [self reloadPiles];
}

@end
