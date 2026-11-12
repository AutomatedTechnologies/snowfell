// AcademyTheme — the shared SDS-9 monochrome presentation constants for
// Snowfell's native lenses (snowfell-test-2 UI uplift).
//
// The values are transcribed from the design baseline of record: the
// `snowfell-decision-gate` artifact's Mac-window renderings (design record
// files/01-SNOWFELL-DESIGN.md §4 — views rendered at real Mac-window scale,
// monochrome SDS-9). Baseline CSS variables, light scheme (the 10.13 floor
// has no dark appearance; the baseline's dark variant is a web media query
// and is not carried into the native app):
//
//   --win #f6f6f6 · --panel #ffffff · --panel2 #f0f0f0 · --panel3 #e2e2e2
//   --side #ececec · --ink #111111 · --ink2 #3d3d3d · --ink3 #6f6f6f
//   --line #c9c9c9 · --line2 #a8a8a8 · --chip #e4e4e4
//   selection: --sel #111111 background, --selink #ffffff text
//
// Presentation only: no lens logic, data, or schema lives here.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AcademyTheme : NSObject

// Palette (baseline CSS variables above).
+ (NSColor *)windowColor;        // --win
+ (NSColor *)panelColor;         // --panel
+ (NSColor *)panelSecondaryColor; // --panel2 (column wells, title bars)
+ (NSColor *)panelTertiaryColor; // --panel3
+ (NSColor *)sidebarColor;       // --side
+ (NSColor *)inkColor;           // --ink
+ (NSColor *)inkSecondaryColor;  // --ink2
+ (NSColor *)inkTertiaryColor;   // --ink3
+ (NSColor *)lineColor;          // --line
+ (NSColor *)lineStrongColor;    // --line2
+ (NSColor *)chipColor;          // --chip
+ (NSColor *)selectionTextColor; // --selink
+ (NSColor *)selectionSubTextColor; // --selink at 70% (selected-row sub-lines)

// Type (baseline: -apple-system; card title 13 semibold/1.35, table body
// 12.5, table header 11 uppercase letterspaced, column header 12 uppercase
// letterspaced, meta/chips 11 / 10.5 semibold).
+ (NSFont *)lensTitleFont;     // 13.5 semibold — lens header line
+ (NSFont *)cardTitleFont;     // 13 semibold — kanban card titles
+ (NSFont *)bodyFont;          // 12.5 — table body
+ (NSFont *)bodySemiboldFont;  // 12.5 semibold
+ (NSFont *)metaFont;          // 11 — card meta, secondary lines
+ (NSFont *)metaSemiboldFont;  // 11 semibold
+ (NSFont *)chipFont;          // 10.5 semibold — label pills
+ (NSFont *)capsHeaderFont;    // 11 semibold — table column headers
+ (NSFont *)columnHeaderFont;  // 12 semibold — kanban column headers

// An attributed string in the baseline's letterspaced uppercase header
// style (letter-spacing .06–.07em ≈ kern 0.8 at these sizes).
+ (NSAttributedString *)capsString:(NSString *)text font:(NSFont *)font color:(NSColor *)color;

// Layer styling: baseline .kcard (white panel, 1px --line border, radius 8,
// 0 1px 3px rgba(0,0,0,.18) shadow, inset top highlight not reproducible in
// CALayer — omitted, noted in the uplift record).
+ (void)styleCardLayer:(CALayer *)layer;
// Baseline .col (panel2 fill, 1px --line border, radius 9).
+ (void)styleWellLayer:(CALayer *)layer;

@end

// AcademyPillView — one baseline .lbl chip: chip fill, 1px --line2 border,
// fully rounded, 10.5 semibold text, sized to its text (width = text + 14,
// height 16). Used for card label pills and inline status pills.
@interface AcademyPillView : NSView
@property (nonatomic, copy) NSString *text;
- (instancetype)initWithText:(NSString *)text;
// Solid variant (baseline .pill.solid): ink fill, white text.
- (instancetype)initWithText:(NSString *)text solid:(BOOL)solid;
@end

NS_ASSUME_NONNULL_END
