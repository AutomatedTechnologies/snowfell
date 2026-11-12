#import "RoadmapViewController.h"
#import "SnapshotStore.h"
#import "DatedItem.h"

// Layout constants for the timeline canvas (points).
static const CGFloat RoadmapTitleWidth = 300.0;
static const CGFloat RoadmapAxisHeight = 30.0;
static const CGFloat RoadmapBoardHeaderHeight = 26.0;
static const CGFloat RoadmapRowHeight = 22.0;
static const CGFloat RoadmapBottomPadding = 14.0;
static const CGFloat RoadmapRightPadding = 16.0;

#pragma mark - RoadmapRowEntry (one laid-out row: board header or item)

@interface RoadmapRowEntry : NSObject
@property (nonatomic, assign) NSRect rect;
@property (nonatomic, assign) BOOL isBoardHeader;
@property (nonatomic, copy, nullable) NSString *headerText;
@property (nonatomic, strong, nullable) DatedItem *item;
@end

@implementation RoadmapRowEntry
@end

#pragma mark - RoadmapTimelineView (the drawing canvas)

@interface RoadmapTimelineView : NSView
@property (nonatomic, copy) NSArray<NSArray<DatedItem *> *> *groups;
@property (nonatomic, copy) NSArray<NSString *> *groupTitles;
@property (nonatomic, strong, nullable) NSDate *rangeStart;
@property (nonatomic, strong, nullable) NSDate *rangeEnd;
@property (nonatomic, copy, nullable) NSString *selectedItemNodeID;
@property (nonatomic, copy, nullable) void (^activationHandler)(DatedItem *item);
- (void)relayout;
@end

@implementation RoadmapTimelineView

- (BOOL)isFlipped {
    return YES;  // top-down layout: y grows downward, like reading order
}

- (NSArray<RoadmapRowEntry *> *)rowEntries {
    NSMutableArray<RoadmapRowEntry *> *entries = [NSMutableArray array];
    CGFloat y = RoadmapAxisHeight;
    NSUInteger groupIndex = 0;
    for (NSArray<DatedItem *> *group in self.groups) {
        RoadmapRowEntry *header = [[RoadmapRowEntry alloc] init];
        header.isBoardHeader = YES;
        header.headerText = (groupIndex < [self.groupTitles count]) ? self.groupTitles[groupIndex] : @"";
        header.rect = NSMakeRect(0, y, NSWidth(self.bounds), RoadmapBoardHeaderHeight);
        [entries addObject:header];
        y += RoadmapBoardHeaderHeight;
        for (DatedItem *item in group) {
            RoadmapRowEntry *row = [[RoadmapRowEntry alloc] init];
            row.item = item;
            row.rect = NSMakeRect(0, y, NSWidth(self.bounds), RoadmapRowHeight);
            [entries addObject:row];
            y += RoadmapRowHeight;
        }
        groupIndex++;
    }
    return entries;
}

- (CGFloat)contentHeight {
    CGFloat height = RoadmapAxisHeight + RoadmapBottomPadding;
    for (NSArray<DatedItem *> *group in self.groups) {
        height += RoadmapBoardHeaderHeight + RoadmapRowHeight * (CGFloat)[group count];
    }
    return height;
}

- (void)relayout {
    NSRect frame = self.frame;
    frame.size.height = MAX([self contentHeight], NSHeight(self.superview.bounds));
    [self setFrame:frame];
    [self setNeedsDisplay:YES];
}

- (CGFloat)plotOriginX {
    return RoadmapTitleWidth + 8.0;
}

- (CGFloat)plotWidth {
    return MAX(NSWidth(self.bounds) - [self plotOriginX] - RoadmapRightPadding, 50.0);
}

- (CGFloat)xForDate:(NSDate *)date {
    NSTimeInterval span = [self.rangeEnd timeIntervalSinceDate:self.rangeStart];
    if (span <= 0) {
        return [self plotOriginX];
    }
    NSTimeInterval offset = [date timeIntervalSinceDate:self.rangeStart];
    return [self plotOriginX] + (CGFloat)(offset / span) * [self plotWidth];
}

- (NSDictionary *)textAttributesForSize:(CGFloat)size bold:(BOOL)bold secondary:(BOOL)secondary {
    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    attributes[NSFontAttributeName] = bold
        ? [NSFont boldSystemFontOfSize:size]
        : [NSFont systemFontOfSize:size];
    attributes[NSForegroundColorAttributeName] = secondary
        ? [NSColor secondaryLabelColor] : [NSColor labelColor];
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setLineBreakMode:NSLineBreakByTruncatingTail];
    attributes[NSParagraphStyleAttributeName] = style;
    return attributes;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    [[NSColor controlBackgroundColor] setFill];
    NSRectFill(dirtyRect);

    if ([self.groups count] == 0 || self.rangeStart == nil || self.rangeEnd == nil) {
        // The honest empty state, drawn where bars would have been.
        NSString *text = @"No dated items to place on the timeline.";
        [text drawInRect:NSMakeRect(16, 16, NSWidth(self.bounds) - 32, 20)
          withAttributes:[self textAttributesForSize:13 bold:NO secondary:YES]];
        return;
    }

    // — Month axis + gridlines —
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *month = [[NSDateComponents alloc] init];
    [month setMonth:1];
    NSDateFormatter *monthFormatter = [[NSDateFormatter alloc] init];
    [monthFormatter setLocale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
    [monthFormatter setDateFormat:@"MMM yyyy"];
    NSDate *cursor = self.rangeStart;
    while ([cursor compare:self.rangeEnd] == NSOrderedAscending) {
        CGFloat x = [self xForDate:cursor];
        [[NSColor colorWithWhite:0.85 alpha:1.0] setStroke];
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(x, RoadmapAxisHeight - 8)];
        [line lineToPoint:NSMakePoint(x, NSHeight(self.bounds))];
        [line setLineWidth:1.0];
        [line stroke];
        NSString *label = [monthFormatter stringFromDate:cursor];
        [label drawInRect:NSMakeRect(x + 4, 8, 90, 16)
           withAttributes:[self textAttributesForSize:11 bold:YES secondary:YES]];
        NSDate *next = [calendar dateByAddingComponents:month toDate:cursor options:0];
        if (next == nil || [next compare:cursor] != NSOrderedDescending) {
            break;
        }
        cursor = next;
    }

    // — Rows —
    for (RoadmapRowEntry *entry in [self rowEntries]) {
        NSRect rect = entry.rect;
        if (!NSIntersectsRect(rect, dirtyRect)) {
            continue;
        }
        if (entry.isBoardHeader) {
            [[NSColor colorWithWhite:0.93 alpha:1.0] setFill];
            NSRectFill(NSMakeRect(0, rect.origin.y, NSWidth(self.bounds), rect.size.height));
            [entry.headerText drawInRect:NSMakeRect(10, rect.origin.y + 5, NSWidth(self.bounds) - 20, 16)
                          withAttributes:[self textAttributesForSize:12 bold:YES secondary:NO]];
            continue;
        }
        DatedItem *item = entry.item;
        if (item == nil) {
            continue;
        }
        if (self.selectedItemNodeID != nil && [item.nodeID isEqualToString:self.selectedItemNodeID]) {
            [[NSColor colorWithWhite:0.88 alpha:1.0] setFill];
            NSRectFill(rect);
        }
        [item.title drawInRect:NSMakeRect(18, rect.origin.y + 4, RoadmapTitleWidth - 26, 15)
                withAttributes:[self textAttributesForSize:12 bold:NO secondary:NO]];

        NSDate *start = item.startDateValue;
        NSDate *target = item.targetDateValue;
        CGFloat midY = rect.origin.y + rect.size.height / 2.0;
        [[NSColor colorWithWhite:0.25 alpha:1.0] setFill];
        [[NSColor colorWithWhite:0.25 alpha:1.0] setStroke];
        NSString *dateLabel = nil;
        if (start != nil && target != nil) {
            CGFloat x1 = [self xForDate:start];
            CGFloat x2 = [self xForDate:target];
            if (x2 < x1) {  // stored dates out of order: draw the span as stored, label as stored
                CGFloat swap = x1; x1 = x2; x2 = swap;
            }
            NSRect barRect = NSMakeRect(x1, midY - 5, MAX(x2 - x1, 4.0), 10);
            [[NSBezierPath bezierPathWithRoundedRect:barRect xRadius:3 yRadius:3] fill];
            dateLabel = [NSString stringWithFormat:@"%@ → %@", item.startDate, item.targetDate];
            [dateLabel drawInRect:NSMakeRect(x2 + 8, rect.origin.y + 4, 190, 15)
                   withAttributes:[self textAttributesForSize:10 bold:NO secondary:YES]];
        } else if (start != nil || target != nil) {
            // One-ended: a milestone diamond at the single real date.
            NSDate *only = (start != nil) ? start : target;
            CGFloat x = [self xForDate:only];
            NSBezierPath *diamond = [NSBezierPath bezierPath];
            [diamond moveToPoint:NSMakePoint(x, midY - 6)];
            [diamond lineToPoint:NSMakePoint(x + 6, midY)];
            [diamond lineToPoint:NSMakePoint(x, midY + 6)];
            [diamond lineToPoint:NSMakePoint(x - 6, midY)];
            [diamond closePath];
            [diamond fill];
            dateLabel = (start != nil)
                ? [NSString stringWithFormat:@"start %@", item.startDate]
                : [NSString stringWithFormat:@"target %@", item.targetDate];
            [dateLabel drawInRect:NSMakeRect(x + 10, rect.origin.y + 4, 140, 15)
                   withAttributes:[self textAttributesForSize:10 bold:NO secondary:YES]];
        }
        if (item.statusName != nil) {
            CGFloat labelX = NSWidth(self.bounds) - 150;
            [item.statusName drawInRect:NSMakeRect(labelX, rect.origin.y + 4, 134, 15)
                         withAttributes:[self textAttributesForSize:10 bold:NO secondary:YES]];
        }
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    for (RoadmapRowEntry *entry in [self rowEntries]) {
        if (entry.item != nil && NSPointInRect(point, entry.rect)) {
            self.selectedItemNodeID = entry.item.nodeID;
            [self setNeedsDisplay:YES];
            if ([event clickCount] == 2 && self.activationHandler != nil) {
                self.activationHandler(entry.item);
            }
            return;
        }
    }
    [super mouseDown:event];
}

@end

#pragma mark - RoadmapViewController

@interface RoadmapViewController ()
@property (nonatomic, strong, readwrite) SnapshotStore *snapshotStore;
@property (nonatomic, strong) NSTextField *headerField;
@property (nonatomic, strong) NSTextField *subheaderField;
@property (nonatomic, strong) RoadmapTimelineView *timelineView;
@property (nonatomic, strong) NSScrollView *scrollView;
@end

@implementation RoadmapViewController

- (instancetype)initWithSnapshotStore:(SnapshotStore *)store {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _snapshotStore = store;
    }
    return self;
}

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1120, 660)];

    _headerField = [NSTextField labelWithString:@""];
    [_headerField setFont:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]];
    [_headerField setFrame:NSMakeRect(16, 632, 1088, 18)];
    [_headerField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:_headerField];

    _subheaderField = [NSTextField labelWithString:@""];
    [_subheaderField setFont:[NSFont systemFontOfSize:12]];
    [_subheaderField setTextColor:[NSColor secondaryLabelColor]];
    [[_subheaderField cell] setWraps:YES];
    [_subheaderField setFrame:NSMakeRect(16, 590, 1088, 36)];
    [_subheaderField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:_subheaderField];

    _scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 1120, 582)];
    [_scrollView setHasVerticalScroller:YES];
    [_scrollView setHasHorizontalScroller:NO];
    [_scrollView setBorderType:NSNoBorder];
    [_scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    _timelineView = [[RoadmapTimelineView alloc] initWithFrame:NSMakeRect(0, 0, 1120, 582)];
    [_timelineView setAutoresizingMask:NSViewWidthSizable];
    __weak RoadmapViewController *weakSelf = self;
    _timelineView.activationHandler = ^(DatedItem *item) {
        if (weakSelf.itemActivationHandler != nil) {
            weakSelf.itemActivationHandler(item);
        }
    };
    [_scrollView setDocumentView:_timelineView];
    [root addSubview:_scrollView];

    self.view = root;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self reloadRoadmap];
}

- (void)reloadRoadmap {
    if (self.snapshotStore.snapshotPath == nil) {
        NSString *reason = (self.snapshotStore.loadError != nil)
            ? self.snapshotStore.loadError.localizedDescription : @"No snapshot is loaded.";
        [_headerField setStringValue:@"Roadmap unavailable"];
        [_subheaderField setStringValue:[NSString stringWithFormat:
                                         @"No verified snapshot is loaded (%@). The Roadmap reads only the verified snapshot; nothing is drawn from anywhere else.", reason]];
        _timelineView.groups = @[];
        _timelineView.groupTitles = @[];
        _timelineView.rangeStart = nil;
        _timelineView.rangeEnd = nil;
        [_timelineView relayout];
        return;
    }

    NSError *error = nil;
    NSArray<DatedItem *> *dated = [self.snapshotStore datedItemsWithError:&error];
    NSInteger boardsWithFields = [self.snapshotStore boardsWithDateFieldsCountWithError:&error];
    if (dated == nil) {
        [_headerField setStringValue:@"Roadmap unavailable"];
        [_subheaderField setStringValue:[NSString stringWithFormat:
                                         @"The dated-items query failed: %@",
                                         (error != nil) ? error.localizedDescription : @"unknown error"]];
        _timelineView.groups = @[];
        _timelineView.groupTitles = @[];
        [_timelineView relayout];
        return;
    }

    // Group by board (query order = the boards' order), sort each board's
    // items by effective date (Start, else Target), undated-within-row
    // impossible here by the query's definition.
    NSMutableArray<NSArray<DatedItem *> *> *groups = [NSMutableArray array];
    NSMutableArray<DatedItem *> *current = nil;
    NSString *currentBoardID = nil;
    for (DatedItem *item in dated) {
        if (current == nil || ![item.boardID isEqualToString:currentBoardID]) {
            current = [NSMutableArray array];
            [groups addObject:current];
            currentBoardID = item.boardID;
        }
        [current addObject:item];
    }
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (NSUInteger index = 0; index < [groups count]; index++) {
        NSArray<DatedItem *> *group = groups[index];
        DatedItem *first = [group firstObject];
        [titles addObject:[NSString stringWithFormat:@"%@  ·  %lu dated item(s)",
                           first.boardDisplay, (unsigned long)[group count]]];
        groups[index] = [group sortedArrayUsingComparator:^NSComparisonResult(DatedItem *a, DatedItem *b) {
            NSDate *da = a.effectiveDateValue;
            NSDate *db = b.effectiveDateValue;
            if (da == nil && db == nil) {
                return [a.title compare:b.title];
            }
            if (da == nil) {
                return NSOrderedDescending;
            }
            if (db == nil) {
                return NSOrderedAscending;
            }
            NSComparisonResult byDate = [da compare:db];
            return (byDate != NSOrderedSame) ? byDate : [a.title compare:b.title];
        }];
    }

    // Range: pad the true min/max to whole months.
    NSDate *minDate = nil;
    NSDate *maxDate = nil;
    for (DatedItem *item in dated) {
        NSDate *start = item.startDateValue;
        NSDate *target = item.targetDateValue;
        if (start != nil) {
            if (minDate == nil || [start compare:minDate] == NSOrderedAscending) {
                minDate = start;
            }
            if (maxDate == nil || [start compare:maxDate] == NSOrderedDescending) {
                maxDate = start;
            }
        }
        if (target != nil) {
            if (minDate == nil || [target compare:minDate] == NSOrderedAscending) {
                minDate = target;
            }
            if (maxDate == nil || [target compare:maxDate] == NSOrderedDescending) {
                maxDate = target;
            }
        }
    }
    NSDate *rangeStart = nil;
    NSDate *rangeEnd = nil;
    if (minDate != nil && maxDate != nil) {
        NSCalendar *calendar = [NSCalendar currentCalendar];
        NSDateComponents *parts = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth)
                                              fromDate:minDate];
        [parts setDay:1];
        rangeStart = [calendar dateFromComponents:parts];
        parts = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth) fromDate:maxDate];
        [parts setDay:1];
        NSDate *maxMonthStart = [calendar dateFromComponents:parts];
        NSDateComponents *oneMonth = [[NSDateComponents alloc] init];
        [oneMonth setMonth:1];
        rangeEnd = [calendar dateByAddingComponents:oneMonth toDate:maxMonthStart options:0];
    }

    if ([dated count] == 0) {
        // The honest empty state: the count, and where dates WOULD come
        // from — the GitHub Projects Start/Target date fields on the
        // boards that carry them, imported as sf_item_values date rows.
        [_headerField setStringValue:[NSString stringWithFormat:
                                      @"Roadmap — 0 dated items in snapshot %@",
                                      self.snapshotStore.snapshotVersion]];
        [_subheaderField setStringValue:[NSString stringWithFormat:
                                         @"Boards carrying Start/Target date fields: %ld. Dated items: 0. "
                                         @"Dates would come from GitHub Projects' Start date / Target date fields, imported into "
                                         @"sf_item_values (value_kind 'date') by the registry import; in this snapshot no item holds "
                                         @"such a value, so there is nothing to place on a timeline — and nothing is invented to fill it.",
                                         (long)boardsWithFields]];
    } else {
        NSDateFormatter *dayFormatter = [[NSDateFormatter alloc] init];
        [dayFormatter setLocale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
        [dayFormatter setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
        [dayFormatter setDateFormat:@"yyyy-MM-dd"];
        [_headerField setStringValue:[NSString stringWithFormat:
                                      @"Roadmap — %lu dated item(s) on %lu board(s) · %@ → %@ · snapshot %@",
                                      (unsigned long)[dated count], (unsigned long)[groups count],
                                      [dayFormatter stringFromDate:minDate],
                                      [dayFormatter stringFromDate:maxDate],
                                      self.snapshotStore.snapshotVersion]];
        [_subheaderField setStringValue:[NSString stringWithFormat:
                                         @"%ld board(s) carry Start/Target date fields; only items holding a date value in the snapshot "
                                         @"appear here (bars = Start → Target; diamonds = the single date an item carries). "
                                         @"Undated items, and boards without date fields, are excluded — never back-filled.",
                                         (long)boardsWithFields]];
    }

    _timelineView.groups = groups;
    _timelineView.groupTitles = titles;
    _timelineView.rangeStart = rangeStart;
    _timelineView.rangeEnd = rangeEnd;
    [_timelineView relayout];
}

@end
