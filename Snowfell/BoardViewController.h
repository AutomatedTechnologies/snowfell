// BoardViewController — V1 Board (design record §4): a Kanban whose columns
// are generated from the SELECTED BOARD'S OWN Status single-select options
// (sf_field_options, in position order). Status vocabulary is per-board
// data — this controller never names a status; KisMac Uplift renders its
// 7-stage pipeline for the same reason user board #3 renders
// Todo / In Progress / Done.
// SF-T4: each card carries a Status popup and the header a "New Item…"
// button. Both are REQUESTS only: they call the request handlers below;
// the delegate side (AppDelegate) shows the confirm sheet and enqueues
// into the local WriteBackQueue. Nothing here mutates the snapshot or
// GitHub. Dragging stays disabled — with write-back compiled OFF in this
// build there is no drag at all; when an armed build enables it, drag
// becomes visual intent over the same popup's enqueue path.
#import <AppKit/AppKit.h>

@class SnapshotStore;
@class BoardSummary;
@class BoardItem;
@class BoardViewController;

NS_ASSUME_NONNULL_BEGIN

@protocol BoardViewControllerDelegate <NSObject>
// A card was clicked: the delegate (AppDelegate) presents V3 for the item.
- (void)boardViewController:(BoardViewController *)controller
            didSelectItem:(BoardItem *)item;
@end

@interface BoardViewController : NSViewController

@property (nonatomic, strong, readonly) SnapshotStore *snapshotStore;
@property (nonatomic, weak, nullable) id<BoardViewControllerDelegate> delegate;
@property (nonatomic, strong, readonly, nullable) BoardSummary *currentBoard;
@property (nonatomic, strong, readonly, nullable) BoardItem *selectedItem;

// SF-T4 request handlers (wired by AppDelegate; nil-safe — with no
// handler set, the popup and the New Item button are inert). The
// completion tells the board whether the mutation was actually queued,
// so the card popup can settle back to the item's snapshot status either
// way (a queued move changes nothing on screen until a send + resync).
@property (nonatomic, copy, nullable) void (^statusMoveRequestHandler)(BoardItem *item,
                                                                       BoardSummary *board,
                                                                       NSString *optionName,
                                                                       void (^completion)(BOOL enqueued));
@property (nonatomic, copy, nullable) void (^createItemRequestHandler)(BoardSummary *board,
                                                                       NSString *title,
                                                                       NSString * _Nullable optionName);

- (instancetype)initWithSnapshotStore:(SnapshotStore *)store;

// (Re)loads the board list into the switcher and shows the default board
// (user board #3 — the largest — unless a board is already current).
- (void)reloadBoards;

// Shows one board: derives its columns from its own Status options and
// places its items by their Status values.
- (void)showBoard:(BoardSummary *)board;

@end

NS_ASSUME_NONNULL_END
