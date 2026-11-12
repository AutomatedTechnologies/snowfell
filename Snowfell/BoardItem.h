// BoardItem — one card of the V1 Board: a single sf_items row plus the two
// EAV values the card face renders — its Status (the board's own vocabulary,
// from sf_item_values joined through the board's 'Status' field) and its
// Labels (JSON array in sf_item_values.json_value). Everything else about
// the item lives in ItemFieldValue rows (V3).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BoardItem : NSObject

@property (nonatomic, copy) NSString *nodeID;            // sf_items.gh_node_id
@property (nonatomic, copy) NSString *boardID;           // sf_items.board_id
@property (nonatomic, copy) NSString *contentKind;       // sf_items.content_kind (DraftIssue | Issue)
@property (nonatomic, copy, nullable) NSString *contentRepo;    // sf_items.content_repo
@property (nonatomic, strong, nullable) NSNumber *contentNumber; // sf_items.content_number
@property (nonatomic, copy) NSString *title;             // sf_items.title
@property (nonatomic, copy, nullable) NSString *state;   // sf_items.state (OPEN | …; nil for drafts)
@property (nonatomic, copy, nullable) NSString *url;     // sf_items.url

// From the EAV layer (never hardcoded — design record §1):
@property (nonatomic, copy, nullable) NSString *statusName;  // Status value's option_name
@property (nonatomic, copy) NSArray<NSString *> *labels;     // Labels value, parsed

@property (nonatomic, readonly) NSString *kindDisplay;   // "Issue · repo #1" | "Draft issue"
@property (nonatomic, readonly) NSString *labelsDisplay; // "ci-cd, deploy" | ""

@end

NS_ASSUME_NONNULL_END
