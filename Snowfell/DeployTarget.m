#import "DeployTarget.h"

@implementation DeployTarget

- (NSString *)displayName {
    return [NSString stringWithFormat:@"%@ — %@", self.platform, self.accountLabel];
}

@end
