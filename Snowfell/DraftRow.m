#import "DraftRow.h"

@implementation DraftRow

- (NSString *)displayName {
    return [NSString stringWithFormat:@"%@ v%ld", self.name, (long)self.version];
}

- (NSString *)targetDisplay {
    if (self.deployTargetID == nil) {
        return @"no deploy target";
    }
    if (self.platform != nil && self.accountLabel != nil) {
        return [NSString stringWithFormat:@"%@ — %@", self.platform, self.accountLabel];
    }
    return self.deployTargetID;
}

@end
