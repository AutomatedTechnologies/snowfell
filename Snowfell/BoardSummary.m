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

- (NSString *)updatedDisplay {
    if ([self.ghUpdatedAt length] == 0) {
        return nil;
    }
    static NSDateFormatter *parser = nil;
    static NSDateFormatter *renderer = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        parser = [[NSDateFormatter alloc] init];
        [parser setLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"]];
        [parser setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
        [parser setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss'Z'"];
        renderer = [[NSDateFormatter alloc] init];
        [renderer setLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"]];
        [renderer setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
        [renderer setDateFormat:@"MMM d, yyyy"];
    });
    NSDate *date = [parser dateFromString:self.ghUpdatedAt];
    return (date != nil) ? [renderer stringFromDate:date] : nil;
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
