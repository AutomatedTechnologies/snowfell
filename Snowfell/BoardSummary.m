#import "BoardSummary.h"

@implementation BoardSummary

- (NSString *)ownerDisplay {
    return [NSString stringWithFormat:@"%@ (%@)", self.ownerLogin, self.ownerType];
}

- (NSString *)stateDisplay {
    if (self.archivedHidden) {
        return @"Archived";
    }
    return self.closed ? @"Closed" : @"Open";
}

@end
