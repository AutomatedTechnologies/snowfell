// DatedItem — one row of the V5 Roadmap (SF-T7; design record §4 V5):
// a single sf_items row that carries at least one date value in the EAV
// layer — its board's 'Start date' and/or 'Target date' field value from
// sf_item_values (value_kind 'date', stored as ISO yyyy-MM-dd text).
// Dates are read, never invented: an item with only a Start carries a nil
// targetDate and renders as a milestone, not a fabricated bar (and the
// reverse). Items with NO date value are not DatedItems at all — the
// Roadmap excludes them by definition.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DatedItem : NSObject

@property (nonatomic, copy) NSString *nodeID;            // sf_items.gh_node_id
@property (nonatomic, copy) NSString *boardID;           // sf_items.board_id
@property (nonatomic, copy) NSString *boardTitle;        // sf_boards.title
@property (nonatomic, copy) NSString *boardOwnerType;    // sf_boards.owner_type
@property (nonatomic, assign) NSInteger boardNumber;     // sf_boards.number
@property (nonatomic, copy) NSString *title;             // sf_items.title
@property (nonatomic, copy, nullable) NSString *statusName;   // Status option_name, board vocabulary
@property (nonatomic, copy, nullable) NSString *startDate;    // ISO yyyy-MM-dd, as stored
@property (nonatomic, copy, nullable) NSString *targetDate;   // ISO yyyy-MM-dd, as stored

// Parsed forms (nil when the stored text is absent or unparseable).
@property (nonatomic, strong, readonly, nullable) NSDate *startDateValue;
@property (nonatomic, strong, readonly, nullable) NSDate *targetDateValue;

// The date the timeline sorts/places by when only one end exists.
@property (nonatomic, strong, readonly, nullable) NSDate *effectiveDateValue;

// "user #3 — DetroitAutomationAcademy"
@property (nonatomic, readonly) NSString *boardDisplay;

@end

NS_ASSUME_NONNULL_END
