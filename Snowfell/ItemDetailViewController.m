#import "ItemDetailViewController.h"
#import "SnapshotStore.h"
#import "BoardItem.h"
#import "ItemFieldValue.h"
#import "ElementHandler.h"

@interface ItemDetailViewController () <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>
@property (nonatomic, strong, readwrite) SnapshotStore *snapshotStore;
@property (nonatomic, strong, readwrite, nullable) BoardItem *currentItem;
@property (nonatomic, strong) NSTextField *titleField;
@property (nonatomic, strong) NSTextField *kindField;
@property (nonatomic, strong) NSTextField *urlField;
@property (nonatomic, strong) NSTableView *fieldsTable;
@property (nonatomic, strong) NSView *chipsView;
@property (nonatomic, strong) NSTextField *commentField;
@property (nonatomic, strong) NSButton *commentButton;
@property (nonatomic, copy) NSArray<ItemFieldValue *> *fieldValues;
@end

@implementation ItemDetailViewController

- (instancetype)initWithSnapshotStore:(SnapshotStore *)store {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _snapshotStore = store;
        _fieldValues = @[];
    }
    return self;
}

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 760, 560)];

    _titleField = [NSTextField labelWithString:@"No item selected"];
    [_titleField setFont:[NSFont systemFontOfSize:15 weight:NSFontWeightSemibold]];
    [[_titleField cell] setWraps:YES];
    [_titleField setFrame:NSMakeRect(16, 560 - 56, 728, 40)];
    [_titleField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:_titleField];

    _kindField = [NSTextField labelWithString:@"Select an item on the Board to see its detail."];
    [_kindField setFont:[NSFont systemFontOfSize:12]];
    [_kindField setTextColor:[NSColor secondaryLabelColor]];
    [_kindField setFrame:NSMakeRect(16, 560 - 78, 728, 18)];
    [_kindField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:_kindField];

    _urlField = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 560 - 98, 728, 18)];
    [_urlField setFont:[NSFont systemFontOfSize:12]];
    [_urlField setTextColor:[NSColor secondaryLabelColor]];
    [_urlField setEditable:NO];
    [_urlField setSelectable:YES];
    [_urlField setBordered:NO];
    [_urlField setDrawsBackground:NO];
    [_urlField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:_urlField];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 196, 760, 560 - 314)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setBorderType:NSNoBorder];
    [scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    _fieldsTable = [[NSTableView alloc] initWithFrame:scrollView.bounds];
    [_fieldsTable setDataSource:self];
    [_fieldsTable setDelegate:self];
    [_fieldsTable setUsesAlternatingRowBackgroundColors:YES];
    [_fieldsTable setRowHeight:20];
    [_fieldsTable setAllowsMultipleSelection:NO];

    NSTableColumn *fieldColumn = [[NSTableColumn alloc] initWithIdentifier:@"field"];
    [[fieldColumn headerCell] setStringValue:@"Field"];
    [fieldColumn setWidth:170];
    [_fieldsTable addTableColumn:fieldColumn];
    NSTableColumn *valueColumn = [[NSTableColumn alloc] initWithIdentifier:@"value"];
    [[valueColumn headerCell] setStringValue:@"Value"];
    [valueColumn setWidth:560];
    [_fieldsTable addTableColumn:valueColumn];

    [scrollView setDocumentView:_fieldsTable];
    [root addSubview:scrollView];

    NSTextField *elementsLabel = [NSTextField labelWithString:
        @"Elements — handlers of record (display only; invocation arrives with SF-T5)"];
    [elementsLabel setFont:[NSFont boldSystemFontOfSize:12]];
    [elementsLabel setFrame:NSMakeRect(16, 168, 728, 18)];
    [elementsLabel setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:elementsLabel];

    _chipsView = [[NSView alloc] initWithFrame:NSMakeRect(16, 76, 728, 88)];
    [_chipsView setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:_chipsView];

    // SF-T4: Add comment — enqueues a comment mutation into the LOCAL
    // WriteBackQueue (after the AppDelegate confirm sheet). It posts
    // nothing; sending is a separate, armed action (see the Queue panel).
    NSTextField *commentLabel = [NSTextField labelWithString:
        @"Add a comment — staged on this Mac; posted only when you send staged changes"];
    [commentLabel setFont:[NSFont boldSystemFontOfSize:12]];
    [commentLabel setFrame:NSMakeRect(16, 48, 728, 18)];
    [commentLabel setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:commentLabel];

    _commentField = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 12, 540, 26)];
    [_commentField setPlaceholderString:@"Comment text"];
    [_commentField setDelegate:self];
    [_commentField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:_commentField];

    _commentButton = [[NSButton alloc] initWithFrame:NSMakeRect(568, 10, 176, 30)];
    [_commentButton setTitle:@"Stage Comment"];
    [_commentButton setBezelStyle:NSBezelStyleRounded];
    [_commentButton setTarget:self];
    [_commentButton setAction:@selector(enqueueCommentClicked:)];
    [_commentButton setEnabled:NO];
    [_commentButton setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
    [root addSubview:_commentButton];

    self.view = root;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self rebuildChips];
}

#pragma mark - Rendering

- (void)showItem:(BoardItem *)item {
    self.currentItem = item;
    [_titleField setStringValue:(item.title != nil) ? item.title : @""];

    NSMutableArray<NSString *> *kindParts = [NSMutableArray arrayWithObject:item.kindDisplay];
    if (item.state != nil) {
        [kindParts addObject:item.state];
    }
    if (item.statusName != nil) {
        [kindParts addObject:[NSString stringWithFormat:@"Status: %@", item.statusName]];
    }
    [_kindField setStringValue:[kindParts componentsJoinedByString:@" · "]];
    [_urlField setStringValue:(item.url != nil) ? item.url : @""];

    NSError *error = nil;
    NSArray<ItemFieldValue *> *values = [self.snapshotStore fieldValuesForItem:item.nodeID error:&error];
    if (values == nil) {
        self.fieldValues = @[];
        [_kindField setStringValue:[NSString stringWithFormat:@"Fields unavailable — %@",
                                    (error != nil) ? error.localizedDescription : @"unknown error"]];
    } else {
        self.fieldValues = values;
    }
    [_fieldsTable reloadData];
    [self rebuildChips];
    [self updateCommentButtonState];
}

#pragma mark - SF-T4 comment request

- (void)updateCommentButtonState {
    NSString *body = [[_commentField stringValue] stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [_commentButton setEnabled:(self.currentItem != nil && [body length] > 0)];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    [self updateCommentButtonState];
}

- (void)enqueueCommentClicked:(id)sender {
    BoardItem *item = self.currentItem;
    NSString *body = [[_commentField stringValue] stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (item == nil || [body length] == 0 || self.commentRequestHandler == nil) {
        NSBeep();
        return;
    }
    __weak ItemDetailViewController *weakSelf = self;
    self.commentRequestHandler(item, body, ^(BOOL enqueued) {
        if (enqueued) {
            [weakSelf.commentField setStringValue:@""];
            [weakSelf updateCommentButtonState];
        }
    });
}

- (void)rebuildChips {
    for (NSView *subview in [[self.chipsView subviews] copy]) {
        [subview removeFromSuperview];
    }
    NSError *error = nil;
    NSArray<ElementHandler *> *handlers = [self.snapshotStore elementHandlersWithError:&error];
    if (handlers == nil) {
        NSTextField *note = [NSTextField labelWithString:
            [NSString stringWithFormat:@"Handlers unavailable — %@",
             (error != nil) ? error.localizedDescription : @"unknown error"]];
        [note setFont:[NSFont systemFontOfSize:12]];
        [note setTextColor:[NSColor secondaryLabelColor]];
        [note setFrame:NSMakeRect(0, 64, 728, 18)];
        [self.chipsView addSubview:note];
        return;
    }

    // Manual flow: chips wrap left-to-right inside the section's width.
    NSFont *chipFont = [NSFont systemFontOfSize:12];
    CGFloat const chipHeight = 24;
    CGFloat const gap = 8;
    CGFloat maxX = NSWidth([self.chipsView bounds]);
    CGFloat x = 0;
    CGFloat y = NSHeight([self.chipsView bounds]) - chipHeight;
    for (ElementHandler *handler in handlers) {
        NSString *text = handler.chipDisplay;
        CGFloat textWidth = ceil([text sizeWithAttributes:@{NSFontAttributeName: chipFont}].width);
        CGFloat chipWidth = textWidth + 24;
        if (x + chipWidth > maxX && x > 0) {
            x = 0;
            y -= chipHeight + gap;
        }
        NSView *chip = [[NSView alloc] initWithFrame:NSMakeRect(x, y, chipWidth, chipHeight)];
        [chip setWantsLayer:YES];
        [[chip layer] setCornerRadius:chipHeight / 2];
        [[chip layer] setBorderWidth:0.75];
        [[chip layer] setBorderColor:[[NSColor colorWithWhite:0.80 alpha:1] CGColor]];
        [[chip layer] setBackgroundColor:[[NSColor colorWithWhite:0.93 alpha:1] CGColor]];
        NSTextField *label = [NSTextField labelWithString:text];
        [label setFont:chipFont];
        [label setAlignment:NSTextAlignmentCenter];
        [label setFrame:NSMakeRect(0, 4, chipWidth, 16)];
        [chip addSubview:label];
        [self.chipsView addSubview:chip];
        x += chipWidth + gap;
    }
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)[self.fieldValues count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    ItemFieldValue *value = self.fieldValues[(NSUInteger)row];
    if ([[tableColumn identifier] isEqualToString:@"field"]) {
        return value.fieldName;
    }
    return value.displayValue;
}

#pragma mark - NSTableViewDelegate

- (NSString *)tableView:(NSTableView *)tableView toolTipForCell:(NSCell *)cell rect:(NSRectPointer)rect tableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row mouseLocation:(NSPoint)mouseLocation {
    if ([[tableColumn identifier] isEqualToString:@"value"]) {
        return self.fieldValues[(NSUInteger)row].displayValue;
    }
    return nil;
}

@end
