#import "BoardSummary.h"

@implementation BoardSummary

- (NSString *)ownerDisplay {
    return [NSString stringWithFormat:@"%@ (%@)", self.ownerLogin, self.ownerType];
}

- (NSString *)stateDisplay {
    if (self.archivedHidden) {
        return @"Archived";
    }
    // Derived state is the presentation state (design note 04): a
    // board whose items all sit in its terminal Status option reads
    // Complete even though GitHub's manual flag still says open.
    if (self.hasDerivedState && [self.derivedState isEqualToString:@"COMPLETE"]) {
        return @"Complete";
    }
    return self.closed ? @"Closed" : @"Open";
}

- (NSString *)githubStateDisplay {
    return self.closed ? @"GitHub: Closed" : @"GitHub: Open";
}

- (NSString *)stateDetailDisplay {
    if (!self.hasDerivedState) {
        return self.githubStateDisplay;
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if ([self.derivedState isEqualToString:@"COMPLETE"]) {
        [parts addObject:@"Complete"];
    }
    [parts addObject:self.githubStateDisplay];
    if (self.terminalOptionName != nil) {
        [parts addObject:[NSString stringWithFormat:@"%ld of %ld in '%@'",
                          (long)self.derivedItemsTerminal,
                          (long)self.derivedItemsTotal,
                          self.terminalOptionName]];
    } else {
        [parts addObject:@"status vocabulary unresolved"];
    }
    return [parts componentsJoinedByString:@" · "];
}

@end
