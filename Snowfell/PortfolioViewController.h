// PortfolioViewController — V2 Portfolio (design record §4): every board in
// the verified snapshot, with owner, open/closed state, item count, and the
// board's own Status-vocabulary summary. READ-ONLY: this controller issues
// SELECTs through SnapshotStore and nothing else — no network, no writes
// (write-back is SF-T4).
#import <AppKit/AppKit.h>

@class SnapshotStore;
@class BoardSummary;

NS_ASSUME_NONNULL_BEGIN

@interface PortfolioViewController : NSViewController

@property (nonatomic, strong, readonly) SnapshotStore *snapshotStore;

// View-menu filters (D5: archived boards are hidden by default).
@property (nonatomic, assign) BOOL showClosedBoards;    // default YES
@property (nonatomic, assign) BOOL showArchivedBoards;  // default NO

// SF-T3 wiring: a row double-click (or View ▸ Board on the selection)
// fires this with the chosen board — AppDelegate opens V1 for it.
@property (nonatomic, copy, nullable) void (^boardActivationHandler)(BoardSummary *board);

// Snapshot-freshness line (snowfell-test-5, freshness remainder,
// board #78): AppDelegate pushes the gap text here on every sync step
// — e.g. "Served v10-0059 — an update is published" or "Update staged
// — Apply Update in the Updates lens". nil/empty = no gap to name;
// the header's sub-line then carries the snapshot line alone. This is
// the Portfolio half of the freshness surfacing; the Updates lens
// keeps the full state.
@property (nonatomic, copy, nullable) NSString *freshnessText;

- (instancetype)initWithSnapshotStore:(SnapshotStore *)store;

// The board under the current table selection, or nil when none.
- (nullable BoardSummary *)selectedBoard;

// Re-queries the snapshot and rebuilds the table. Safe to call when no
// snapshot is loaded: the view states the failure fact instead of rows.
- (void)reloadPortfolio;

@end

NS_ASSUME_NONNULL_END
