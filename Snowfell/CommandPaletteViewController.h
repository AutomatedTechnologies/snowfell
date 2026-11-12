// CommandPaletteViewController — V6 Command Palette (SF-T7; design
// record §4 V6 + §11.3): the ⌘K overlay's content. One search field,
// one results table, five scopes — boards (title), items (title),
// manifest actions (id/name), deploy targets (id/platform/account),
// and upcoming drafts (the sf_upcoming_drafts projection; §11.3 puts
// drafts in ⌘K scope by name/item/board/account). All searching runs
// through SnapshotStore.paletteResultsForQuery — this controller holds
// no SQL and no snapshot handle of its own beyond the store.
//
// Routing (Enter, or double-click): the palette first RESOLVES the hit
// to its full object through SnapshotStore (board → BoardSummary via
// the portfolio query, item → BoardItem via itemWithNodeID, draft →
// DraftRow via the drafts query), then fires the matching handler:
//   board  → boardActivationHandler  (AppDelegate opens V1 on it)
//   item   → itemActivationHandler   (AppDelegate presents V3)
//   action → actionActivationHandler (AppDelegate opens V4 with the
//            action preselected in the composer)
//   target → targetActivationHandler (AppDelegate opens V4 — targets
//            are chosen inside the composer; the palette names the
//            target it routed from)
//   draft  → draftActivationHandler  (AppDelegate opens V4's deploy
//            lane, preselecting the draft's deploy action where its
//            target names one)
// Escape closes the palette window (cancelOperation:). No global
// hotkey exists: the only ⌘K registration is the app menu item
// AppDelegate installs (View ▸ Command Palette…).
#import <AppKit/AppKit.h>

@class SnapshotStore;
@class BoardSummary;
@class BoardItem;
@class DraftRow;

NS_ASSUME_NONNULL_BEGIN

@interface CommandPaletteViewController : NSViewController

@property (nonatomic, strong, readonly) SnapshotStore *snapshotStore;

@property (nonatomic, copy, nullable) void (^boardActivationHandler)(BoardSummary *board);
@property (nonatomic, copy, nullable) void (^itemActivationHandler)(BoardItem *item);
@property (nonatomic, copy, nullable) void (^actionActivationHandler)(NSString *actionID);
@property (nonatomic, copy, nullable) void (^targetActivationHandler)(NSString *targetID);
@property (nonatomic, copy, nullable) void (^draftActivationHandler)(DraftRow *draft);

- (instancetype)initWithSnapshotStore:(SnapshotStore *)store;

// Clears the query, reloads the browse scopes, and puts the caret in
// the search field. AppDelegate calls this on every palette open, so
// the palette never presents a previous session's search.
- (void)resetPalette;

// Re-runs the search for the current field text.
- (void)reloadPalette;

@end

NS_ASSUME_NONNULL_END
