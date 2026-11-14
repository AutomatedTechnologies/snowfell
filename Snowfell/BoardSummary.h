// BoardSummary — one row of the V2 Portfolio: a single GitHub Projects board
// as imported into sf_boards, plus its per-board Status vocabulary summary
// (status is per-board data, never a hardcoded enum — design record §1).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BoardSummary : NSObject

@property (nonatomic, copy) NSString *nodeID;            // sf_boards.gh_node_id
@property (nonatomic, copy) NSString *title;             // sf_boards.title
@property (nonatomic, copy) NSString *ownerLogin;        // sf_boards.owner_login
@property (nonatomic, copy) NSString *ownerType;         // sf_boards.owner_type (user|org)
@property (nonatomic, assign) NSInteger number;          // sf_boards.number
@property (nonatomic, copy, nullable) NSString *shortDescription;
@property (nonatomic, assign) BOOL closed;               // sf_boards.closed
@property (nonatomic, assign) BOOL archivedHidden;       // sf_boards.archived_hidden (D5)
@property (nonatomic, copy) NSString *url;               // sf_boards.url
@property (nonatomic, assign) NSInteger itemCount;       // sf_boards.item_count
// e.g. "Todo 80 · In Progress 6 · Done 15" — composed in the board's own
// Status-option order from sf_item_values; falls back to the bare option
// list when the board carries no valued items yet.
@property (nonatomic, copy) NSString *statusSummary;
// Derived board state (schema v9, sf_board_state — design note 04): the
// backend pipeline derives COMPLETE when every non-archived item sits
// in the board's own terminal Status option. GitHub never auto-closes
// a project, so sf_boards.closed alone presents finished boards as
// Open forever; derivedState is the presentation state, `closed` the
// raw mirror. hasDerivedState is NO on pre-v9 snapshots (no
// sf_board_state table) and every derived display falls back to the
// raw state, unchanged from before.
@property (nonatomic, assign) BOOL hasDerivedState;
@property (nonatomic, copy, nullable) NSString *derivedState;   // ACTIVE | COMPLETE
@property (nonatomic, assign) NSInteger derivedItemsTotal;      // sf_board_state.items_total
@property (nonatomic, assign) NSInteger derivedItemsTerminal;   // sf_board_state.items_terminal
@property (nonatomic, copy, nullable) NSString *terminalOptionName;
// GitHub's own last-activity stamp for the project (sf_boards
// .gh_updated_at, schema v10 — the data source the decision-gate
// baseline's Portfolio "Updated" column was dropped for want of at
// snowfell-test-2). Raw ISO-8601 UTC as GitHub serves it; nil on
// pre-v10 snapshots (no column) and the column then stays hidden —
// never the registry row's bookkeeping stamp, which is uniform.
// Added snowfell-test-5 (UI-uplift remainder, board #78).
@property (nonatomic, copy, nullable) NSString *ghUpdatedAt;

@property (nonatomic, readonly) NSString *ownerDisplay;  // "smit4786 (user)"
// "Nov 13, 2026" rendered from ghUpdatedAt (its own calendar day,
// UTC); nil when ghUpdatedAt is nil.
@property (nonatomic, readonly, nullable) NSString *updatedDisplay;
@property (nonatomic, readonly) NSString *stateDisplay;  // Complete | Open | Closed | Archived
@property (nonatomic, readonly) NSString *githubStateDisplay;  // "GitHub: Open" | "GitHub: Closed"
// Secondary detail for headers/tooltips, e.g.
// "Complete · GitHub: Open · 8 of 8 in 'Done'" — derived state first,
// the honest raw mirror second.
@property (nonatomic, readonly) NSString *stateDetailDisplay;

@end

NS_ASSUME_NONNULL_END
