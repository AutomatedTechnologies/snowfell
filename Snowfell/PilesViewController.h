// PilesViewController — the Piles lens (design record 13 section 4;
// snowfell-test-8): the pile organizational method as a surface.
//
// Left — the pile list: every pile with its count and its top item's
// title (the method's whole state for a pile, nothing else). Right —
// the selected pile's stack, top first, with the top item presented
// in a NEXT ACTION card above the stack. Selecting a row never makes
// it actionable — only position does.
//
// Interactions: Move to Pile... (popup on every stack row and on the
// NEXT ACTION card, plus the Piles menu / Cmd-M for the selected
// row), Make Top, Clear Top (-> Done pile), New/Rename/Delete custom
// piles (delete rehomes to Inbox), within-stack drag reorder
// (NSTableView row dragging; cross-pile drag is NOT shipped — moves
// are menu/keyboard, per design record 13 section 4). Double-click a
// row -> Item Detail via itemActivationHandler (AppDelegate wires it
// to presentDetailForItem:, following the Roadmap pattern).
//
// All pile state lives in PileStore (the local store); this lens
// contains no network code and no snapshot writes.
#import <AppKit/AppKit.h>

@class PileStore;
@class SnapshotStore;
@class BoardItem;

NS_ASSUME_NONNULL_BEGIN

@interface PilesViewController : NSViewController

@property (nonatomic, strong, readonly) PileStore *pileStore;
@property (nonatomic, strong, readonly, nullable) SnapshotStore *snapshotStore;

// A stack row was double-clicked: AppDelegate resolves the item
// through SnapshotStore and presents Item Detail.
@property (nonatomic, copy, nullable) void (^itemActivationHandler)(BoardItem *item);

- (instancetype)initWithPileStore:(PileStore *)pileStore
                  snapshotStore:(nullable SnapshotStore *)snapshotStore;

// Re-materializes/reconciles against the snapshot, then re-reads the
// piles and re-renders. Safe with no snapshot loaded: the view
// states the failure fact instead.
- (void)reloadPiles;

// The Piles menu / Cmd-M entry: Move to Pile... for the selected
// stack row (AppDelegate's menu item targets this via first
// responder / the controller directly).
- (void)moveSelectedItemToPile:(id)sender;

@end

NS_ASSUME_NONNULL_END
