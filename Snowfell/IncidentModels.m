#import "IncidentModels.h"

@implementation IncidentSummary

- (NSString *)deadlineDisplay {
    if (self.nextDeadlineDue == nil) {
        return @"—";
    }
    if (self.nextDeadlineLabel != nil) {
        return [NSString stringWithFormat:@"%@ — %@", self.nextDeadlineDue, self.nextDeadlineLabel];
    }
    return self.nextDeadlineDue;
}

@end

@implementation IncidentDeadline
@end

@implementation IncidentAsset
@end

@implementation IncidentDetail

- (instancetype)init {
    self = [super init];
    if (self) {
        _deadlines = @[];
        _assets = @[];
        _timelineEntries = @[];
    }
    return self;
}

@end
