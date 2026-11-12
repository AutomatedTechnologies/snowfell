// PaletteResult — one row of the V6 Command Palette (SF-T7; design
// record §4 V6 + §11.3 "⌘K scope includes drafts"): a unified search
// hit over the five scopes the palette searches — boards, items,
// manifest actions, deploy targets, and upcoming drafts. SnapshotStore
// builds the rows from the verified snapshot; the palette renders them
// and routes on activation (board → V1, item → V3, action → V4
// composer preselected, draft → V4 deploy lane). referenceID is the
// scope's own key (board/item node ID, action id, target id, or the
// composition id as text) — resolution to the full object happens in
// the palette through SnapshotStore, never from display text.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PaletteResultKind) {
    PaletteResultKindBoard = 0,
    PaletteResultKindItem = 1,
    PaletteResultKindAction = 2,
    PaletteResultKindDeployTarget = 3,
    PaletteResultKindDraft = 4,
};

@interface PaletteResult : NSObject

@property (nonatomic, assign) PaletteResultKind kind;
@property (nonatomic, copy) NSString *title;              // board/item title, action id, target id, draft name
@property (nonatomic, copy) NSString *subtitle;           // scope context (owner/board, kind, platform…)
@property (nonatomic, copy) NSString *referenceID;        // the scope's own key (see header)
@property (nonatomic, copy, nullable) NSString *boardID;  // owning board for items/drafts; the board itself for boards
@property (nonatomic, copy, nullable) NSString *deployTargetID;  // drafts only: routing context for the deploy lane

@property (nonatomic, readonly) NSString *kindDisplay;    // Board | Item | Action | Target | Draft

@end

NS_ASSUME_NONNULL_END
