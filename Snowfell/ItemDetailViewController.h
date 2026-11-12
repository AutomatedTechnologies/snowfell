// ItemDetailViewController — V3 Item Detail (design record §4): the
// item's title and content identity, EVERY field value stored for it in
// the EAV layer (sf_item_values, in the board's field order — Status
// renders in the board's own vocabulary because the value IS the board's
// option name), and the Elements section: the sf_element_handlers routing
// table as display chips (kind → handler app; display only — invocation
// is SF-T5).
// SF-T4: an Add-comment field joins the view. It is a REQUEST surface:
// the text goes to commentRequestHandler; the delegate side shows the
// confirm sheet and enqueues a comment mutation into the local
// WriteBackQueue. Nothing is posted from here. (GitHub cannot comment on
// draft issues at all — the confirm sheet for a draft says so; see the
// GitHubProjectsClient header.)
#import <AppKit/AppKit.h>

@class SnapshotStore;
@class BoardItem;

NS_ASSUME_NONNULL_BEGIN

@interface ItemDetailViewController : NSViewController

@property (nonatomic, strong, readonly) SnapshotStore *snapshotStore;
@property (nonatomic, strong, readonly, nullable) BoardItem *currentItem;

// SF-T4 request handler (wired by AppDelegate; nil-safe). The completion
// reports whether the comment was actually queued, so the field clears
// only on a real enqueue.
@property (nonatomic, copy, nullable) void (^commentRequestHandler)(BoardItem *item,
                                                                    NSString *body,
                                                                    void (^completion)(BOOL enqueued));

- (instancetype)initWithSnapshotStore:(SnapshotStore *)store;

// Renders one item: header, full EAV field list, handler chips.
- (void)showItem:(BoardItem *)item;

@end

NS_ASSUME_NONNULL_END
