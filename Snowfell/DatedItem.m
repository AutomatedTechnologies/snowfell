#import "DatedItem.h"

@implementation DatedItem

+ (NSDateFormatter *)isoDateFormatter {
    // One shared formatter for the stored shape: yyyy-MM-dd, POSIX locale
    // so parsing never shifts with the user's calendar/locale settings.
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        [formatter setLocale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
        [formatter setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
        [formatter setDateFormat:@"yyyy-MM-dd"];
    });
    return formatter;
}

- (NSDate *)dateValueForISOText:(NSString *)text {
    if (text == nil || [text length] == 0) {
        return nil;
    }
    return [[[self class] isoDateFormatter] dateFromString:text];
}

- (NSDate *)startDateValue {
    return [self dateValueForISOText:self.startDate];
}

- (NSDate *)targetDateValue {
    return [self dateValueForISOText:self.targetDate];
}

- (NSDate *)effectiveDateValue {
    NSDate *start = [self startDateValue];
    return (start != nil) ? start : [self targetDateValue];
}

- (NSString *)boardDisplay {
    return [NSString stringWithFormat:@"%@ #%ld — %@", self.boardOwnerType, (long)self.boardNumber, self.boardTitle];
}

@end
