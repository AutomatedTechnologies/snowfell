#import "AcademyTheme.h"
#import <QuartzCore/QuartzCore.h>

@implementation AcademyTheme

+ (NSColor *)colorWithHex:(uint32_t)hex {
    return [NSColor colorWithSRGBRed:((hex >> 16) & 0xFF) / 255.0
                               green:((hex >> 8) & 0xFF) / 255.0
                                blue:(hex & 0xFF) / 255.0
                               alpha:1.0];
}

+ (NSColor *)windowColor         { return [self colorWithHex:0xF6F6F6]; }
+ (NSColor *)panelColor          { return [self colorWithHex:0xFFFFFF]; }
+ (NSColor *)panelSecondaryColor { return [self colorWithHex:0xF0F0F0]; }
+ (NSColor *)panelTertiaryColor  { return [self colorWithHex:0xE2E2E2]; }
+ (NSColor *)sidebarColor        { return [self colorWithHex:0xECECEC]; }
+ (NSColor *)inkColor            { return [self colorWithHex:0x111111]; }
+ (NSColor *)inkSecondaryColor   { return [self colorWithHex:0x3D3D3D]; }
+ (NSColor *)inkTertiaryColor    { return [self colorWithHex:0x6F6F6F]; }
+ (NSColor *)lineColor           { return [self colorWithHex:0xC9C9C9]; }
+ (NSColor *)lineStrongColor     { return [self colorWithHex:0xA8A8A8]; }
+ (NSColor *)chipColor           { return [self colorWithHex:0xE4E4E4]; }
+ (NSColor *)selectionTextColor  { return [self colorWithHex:0xFFFFFF]; }
+ (NSColor *)selectionSubTextColor {
    return [[self colorWithHex:0xFFFFFF] colorWithAlphaComponent:0.7];
}

+ (NSFont *)lensTitleFont    { return [NSFont systemFontOfSize:13.5 weight:NSFontWeightSemibold]; }
+ (NSFont *)cardTitleFont    { return [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]; }
+ (NSFont *)bodyFont         { return [NSFont systemFontOfSize:12.5]; }
+ (NSFont *)bodySemiboldFont { return [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold]; }
+ (NSFont *)metaFont         { return [NSFont systemFontOfSize:11]; }
+ (NSFont *)metaSemiboldFont { return [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]; }
+ (NSFont *)chipFont         { return [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold]; }
+ (NSFont *)capsHeaderFont   { return [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]; }
+ (NSFont *)columnHeaderFont { return [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]; }

+ (NSAttributedString *)capsString:(NSString *)text font:(NSFont *)font color:(NSColor *)color {
    return [[NSAttributedString alloc] initWithString:[text uppercaseString]
                                           attributes:@{NSFontAttributeName: font,
                                                        NSForegroundColorAttributeName: color,
                                                        NSKernAttributeName: @0.8}];
}

+ (void)styleCardLayer:(CALayer *)layer {
    [layer setBackgroundColor:[[self panelColor] CGColor]];
    [layer setBorderColor:[[self lineColor] CGColor]];
    [layer setBorderWidth:1.0];
    [layer setCornerRadius:8.0];
    [layer setShadowColor:[[NSColor blackColor] CGColor]];
    [layer setShadowOpacity:0.18f];
    [layer setShadowRadius:3.0];
    [layer setShadowOffset:CGSizeMake(0, -1)];
}

+ (void)styleWellLayer:(CALayer *)layer {
    [layer setBackgroundColor:[[self panelSecondaryColor] CGColor]];
    [layer setBorderColor:[[self lineColor] CGColor]];
    [layer setBorderWidth:1.0];
    [layer setCornerRadius:9.0];
}

@end

@implementation AcademyPillView {
    BOOL _solid;
}

- (instancetype)initWithText:(NSString *)text {
    return [self initWithText:text solid:NO];
}

- (instancetype)initWithText:(NSString *)text solid:(BOOL)solid {
    NSFont *font = [AcademyTheme chipFont];
    CGFloat textWidth = ceil([text sizeWithAttributes:@{NSFontAttributeName: font}].width);
    self = [super initWithFrame:NSMakeRect(0, 0, textWidth + 14, 16)];
    if (self) {
        _text = [text copy];
        _solid = solid;
    }
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = [self bounds];
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:bounds
                                                         xRadius:NSHeight(bounds) / 2
                                                         yRadius:NSHeight(bounds) / 2];
    if (_solid) {
        [[AcademyTheme inkColor] setFill];
        [path fill];
    } else {
        [[AcademyTheme chipColor] setFill];
        [path fill];
        [[AcademyTheme lineStrongColor] setStroke];
        [path setLineWidth:1.0];
        [path stroke];
    }
    NSColor *textColor = _solid ? [AcademyTheme selectionTextColor]
                                : [AcademyTheme inkSecondaryColor];
    NSDictionary *attrs = @{NSFontAttributeName: [AcademyTheme chipFont],
                            NSForegroundColorAttributeName: textColor};
    NSSize textSize = [self.text sizeWithAttributes:attrs];
    NSPoint origin = NSMakePoint((NSWidth(bounds) - textSize.width) / 2,
                                 (NSHeight(bounds) - textSize.height) / 2);
    [self.text drawAtPoint:origin withAttributes:attrs];
}

@end
