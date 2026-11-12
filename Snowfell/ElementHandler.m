#import "ElementHandler.h"

@implementation ElementHandler

- (NSString *)chipDisplay {
    return [NSString stringWithFormat:@"%@ → %@", self.elementKind, self.handlerApp];
}

@end
