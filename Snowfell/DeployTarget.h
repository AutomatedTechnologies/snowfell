// DeployTarget — one row of sf_deploy_targets (design record §11.1:
// deploy targets are data at ACCOUNT granularity — a deploy names a
// target row: platform + account). SnapshotStore reads the rows from the
// verified snapshot; the Dispatch Composer feeds its target_id dropdowns
// from them. The value a payload carries is targetID (sf_deploy_targets.id,
// e.g. "instagram:justinspencersmith"); the label is display only.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DeployTarget : NSObject

@property (nonatomic, copy) NSString *targetID;      // sf_deploy_targets.id
@property (nonatomic, copy) NSString *platform;      // sf_deploy_targets.platform
@property (nonatomic, copy) NSString *accountRef;    // sf_deploy_targets.account_ref
@property (nonatomic, copy) NSString *accountLabel;  // sf_deploy_targets.account_label

// "instagram — @justinspencersmith (master brand)"
@property (nonatomic, readonly) NSString *displayName;

@end

NS_ASSUME_NONNULL_END
