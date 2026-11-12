#import "BoardItem.h"

@implementation BoardItem

- (instancetype)init {
    self = [super init];
    if (self) {
        _labels = @[];
    }
    return self;
}

- (NSString *)kindDisplay {
    if ([self.contentKind isEqualToString:@"Issue"]) {
        if (self.contentRepo != nil && self.contentNumber != nil) {
            return [NSString stringWithFormat:@"Issue · %@ #%@", self.contentRepo, self.contentNumber];
        }
        return @"Issue";
    }
    if ([self.contentKind isEqualToString:@"DraftIssue"]) {
        return @"Draft issue";
    }
    return (self.contentKind != nil) ? self.contentKind : @"Item";
}

- (NSString *)labelsDisplay {
    return [self.labels componentsJoinedByString:@", "];
}

@end
