#import "StatusField.h"

@implementation StatusOptionRef
@end

@implementation StatusField

- (instancetype)init {
    self = [super init];
    if (self) {
        _options = @[];
    }
    return self;
}

- (StatusOptionRef *)optionWithName:(NSString *)name {
    for (StatusOptionRef *option in self.options) {
        if ([option.name isEqualToString:name]) {
            return option;
        }
    }
    return nil;
}

@end
