#import "SFAction.h"

@implementation SFAction

- (NSDictionary *)payloadSchema {
    id parsed = [NSJSONSerialization JSONObjectWithData:[self.payloadSchemaJSON dataUsingEncoding:NSUTF8StringEncoding]
                                                options:0
                                                  error:NULL];
    return [parsed isKindOfClass:[NSDictionary class]] ? parsed : @{};
}

- (NSArray<NSString *> *)schemaKeysInOrder {
    // Scan the verbatim schema text for depth-1 "key" : pairs, in order.
    // The schemas are flat ({"key":"type", ...}); nested values (none in
    // the v7 manifest) would still scan correctly for the top level
    // because string literals and brace depth are tracked.
    NSString *text = (self.payloadSchemaJSON != nil) ? self.payloadSchemaJSON : @"";
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    NSInteger depth = 0;
    BOOL inString = NO;
    BOOL escaped = NO;
    NSUInteger i = 0;
    NSUInteger length = [text length];
    while (i < length) {
        unichar ch = [text characterAtIndex:i];
        if (inString) {
            if (escaped) {
                escaped = NO;
            } else if (ch == '\\') {
                escaped = YES;
            } else if (ch == '"') {
                inString = NO;
            }
            i++;
            continue;
        }
        if (ch == '"') {
            // A string at depth 1 followed (after whitespace) by ':' is a key.
            NSUInteger start = i + 1;
            NSUInteger end = start;
            BOOL stringEscaped = NO;
            while (end < length) {
                unichar c = [text characterAtIndex:end];
                if (stringEscaped) {
                    stringEscaped = NO;
                } else if (c == '\\') {
                    stringEscaped = YES;
                } else if (c == '"') {
                    break;
                }
                end++;
            }
            NSUInteger probe = end + 1;
            while (probe < length && [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[text characterAtIndex:probe]]) {
                probe++;
            }
            if (depth == 1 && probe < length && [text characterAtIndex:probe] == ':') {
                [keys addObject:[text substringWithRange:NSMakeRange(start, end - start)]];
            }
            inString = YES;
            i++;
            continue;
        }
        if (ch == '{' || ch == '[') {
            depth++;
        } else if (ch == '}' || ch == ']') {
            depth--;
        }
        i++;
    }
    return keys;
}

@end
