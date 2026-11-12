#import "ItemFieldValue.h"

@implementation ItemFieldValue

- (NSString *)displayValue {
    // Single-select renders its option name — for Status that is the
    // board's own vocabulary, straight from the data (§1).
    if ([self.valueKind isEqualToString:@"single_select"] && self.optionName != nil) {
        return self.optionName;
    }
    if (self.dateValue != nil) {
        return self.dateValue;
    }
    if ([self.valueKind isEqualToString:@"labels"] && self.jsonValue != nil) {
        id parsed = [NSJSONSerialization JSONObjectWithData:[self.jsonValue dataUsingEncoding:NSUTF8StringEncoding]
                                                    options:0
                                                      error:NULL];
        if ([parsed isKindOfClass:[NSArray class]]) {
            return [(NSArray *)parsed componentsJoinedByString:@", "];
        }
        return self.jsonValue;
    }
    if (self.textValue != nil) {
        return self.textValue;
    }
    if (self.numberValue != nil) {
        return [self.numberValue stringValue];
    }
    if (self.optionName != nil) {
        return self.optionName;
    }
    if (self.jsonValue != nil) {
        return self.jsonValue;
    }
    return @"";
}

@end
