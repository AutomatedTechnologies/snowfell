#import "PaletteResult.h"

@implementation PaletteResult

- (NSString *)kindDisplay {
    switch (self.kind) {
        case PaletteResultKindBoard:        return @"Board";
        case PaletteResultKindItem:         return @"Item";
        case PaletteResultKindAction:       return @"Action";
        case PaletteResultKindDeployTarget: return @"Target";
        case PaletteResultKindDraft:        return @"Draft";
    }
    return @"Result";
}

@end
