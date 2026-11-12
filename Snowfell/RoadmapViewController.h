// RoadmapViewController — V5 Roadmap (SF-T7; design record §4 V5):
// a month-grid timeline over the items that carry Start/Target dates.
// The rows come from SnapshotStore.datedItems — items whose board
// carries a 'Start date' / 'Target date' field AND which hold a date
// value in sf_item_values. Only 19 of 74 boards have date fields at
// all, and undated items are excluded by definition: the view states
// its counts (boards with date fields, dated items, the date range)
// in its header, and when a snapshot holds ZERO dated items the view
// says exactly that — what the count is, and where dates would come
// from — instead of drawing fabricated bars. Rows group by board;
// a two-ended item draws a bar from Start to Target, a one-ended item
// draws a milestone diamond at its single date (never a fake span).
// Double-clicking a row activates the item (AppDelegate opens V3).
#import <AppKit/AppKit.h>

@class SnapshotStore;
@class DatedItem;

NS_ASSUME_NONNULL_BEGIN

@interface RoadmapViewController : NSViewController

@property (nonatomic, strong, readonly) SnapshotStore *snapshotStore;

// A row was double-clicked: AppDelegate resolves the DatedItem to its
// BoardItem (SnapshotStore.itemWithNodeID) and presents Item Detail.
@property (nonatomic, copy, nullable) void (^itemActivationHandler)(DatedItem *item);

- (instancetype)initWithSnapshotStore:(SnapshotStore *)store;

// Re-queries the snapshot and rebuilds the timeline. Safe with no
// snapshot loaded: the header states the failure fact instead.
- (void)reloadRoadmap;

@end

NS_ASSUME_NONNULL_END
