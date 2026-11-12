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

@property (nonatomic, readonly) NSString *ownerDisplay;  // "smit4786 (user)"
@property (nonatomic, readonly) NSString *stateDisplay;  // Open | Closed | Archived

@end

NS_ASSUME_NONNULL_END
