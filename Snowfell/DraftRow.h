// DraftRow — one row of the sf_upcoming_drafts view (SF-T7; design
// record §11.3): a composition in state draft | in_review | pass with
// its item, board, deploy target, and element count, exactly as the
// view projects them. SnapshotStore reads the rows from the verified
// snapshot; the V10 Drafts lens and the ⌘K palette (draft scope) render
// them. A snapshot with no compositions yields zero rows — stated, not
// papered over (the bundled v7-0026 snapshot carries zero).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DraftRow : NSObject

@property (nonatomic, assign) int64_t compositionID;          // sf_upcoming_drafts.composition_id
@property (nonatomic, copy) NSString *name;                   // composition name
@property (nonatomic, assign) NSInteger version;              // composition version
@property (nonatomic, copy) NSString *state;                  // draft | in_review | pass
@property (nonatomic, copy, nullable) NSString *publishAt;    // ISO text, as stored; nil = unscheduled
@property (nonatomic, copy, nullable) NSString *deployTargetID;  // sf_deploy_targets.id; nil = no target
@property (nonatomic, copy, nullable) NSString *platform;     // sf_deploy_targets.platform
@property (nonatomic, copy, nullable) NSString *accountLabel; // sf_deploy_targets.account_label
@property (nonatomic, copy, nullable) NSString *itemID;       // sf_items.gh_node_id
@property (nonatomic, copy, nullable) NSString *itemTitle;    // sf_items.title
@property (nonatomic, copy, nullable) NSString *boardID;      // sf_boards.gh_node_id
@property (nonatomic, copy, nullable) NSString *boardTitle;   // sf_boards.title
@property (nonatomic, assign) NSInteger elementCount;         // sf_composition_elements count
@property (nonatomic, strong, nullable) NSNumber *renderAssetID;

// "Name v2 · item title" / target summary for list rendering.
@property (nonatomic, readonly) NSString *displayName;
@property (nonatomic, readonly) NSString *targetDisplay;   // "instagram — @…" | "no deploy target"

@end

NS_ASSUME_NONNULL_END
