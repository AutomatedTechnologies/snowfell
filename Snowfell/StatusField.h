// StatusField — the write-back addressing data for one board's Status
// field (SF-T4): the field's GitHub node ID (sf_fields.gh_field_id) and
// its options with their GitHub option IDs (sf_field_options.gh_option_id),
// in the board's own position order. This is the ONLY place GitHub field /
// option IDs enter the app: SnapshotStore reads them from the verified
// snapshot, the Board UI names options by their display names, and
// WriteBackQueue payloads carry the IDs the GraphQL mutations require.
// The vocabulary is still per-board data — nothing here names a status.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface StatusOptionRef : NSObject

@property (nonatomic, copy) NSString *name;          // sf_field_options.name (display)
@property (nonatomic, copy) NSString *ghOptionID;    // sf_field_options.gh_option_id

@end

@interface StatusField : NSObject

@property (nonatomic, copy) NSString *ghFieldID;     // sf_fields.gh_field_id
@property (nonatomic, copy) NSArray<StatusOptionRef *> *options;  // position order

// The option ref for a display name, or nil when the board's Status field
// has no such option.
- (nullable StatusOptionRef *)optionWithName:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
