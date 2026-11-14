// NavigationBar — the ONE builder of Snowfell's navigation bar
// (snowfell-test-4; owner's directive 2026-11-13: "Snowfell needs a
// navigation bar"). snowfell-test-6 (owner verdict 2026-11-14) put the
// bar on the ONE main window only: its NSToolbar (identifier
// SnowfellNavigationToolbar) hosts a single custom item with an
// NSSegmentedControl carrying the eight lenses in View-menu (⌘) order,
// and AppDelegate switches the window's content view controller in
// place per segment. Auxiliary surfaces (Item Detail, Preferences, the
// ⌘K palette panel) carry no bar. AppDelegate supplies the target +
// action once; the bar itself owns no navigation logic — a segment
// press is forwarded to AppDelegate's navigationSegmentChanged:.
// Monochrome/native styling only: no custom drawing, no images.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// The eight navigable sections, in segment order — the same order as
// the View menu's ⌘1–⌘9 lens items (Item Detail ⌘3 has no segment: it
// is the Board's drill-down, so the Detail window selects Board).
typedef NS_ENUM(NSInteger, SFNavigationSection) {
    SFNavigationSectionPortfolio = 0,
    SFNavigationSectionBoard,
    SFNavigationSectionStaged,
    SFNavigationSectionOrchestration,
    SFNavigationSectionRoadmap,
    SFNavigationSectionIncidents,
    SFNavigationSectionStorage,
    SFNavigationSectionUpdates,
};

extern NSToolbarIdentifier const SFNavigationToolbarIdentifier;
extern NSToolbarItemIdentifier const SFNavigationSegmentsItemIdentifier;

@interface NavigationBar : NSObject <NSToolbarDelegate>

// The segment labels, exactly as shown, in SFNavigationSection order.
+ (NSArray<NSString *> *)sectionLabels;

// Builds the navigation toolbar for a window and attaches it. The
// builder instance is retained by the window for the window's life.
// target/action receive the segment presses (the action's sender is
// the NSSegmentedControl; read selectedSegment). section is the
// segment shown selected for this window.
+ (void)attachToWindow:(NSWindow *)window
               section:(SFNavigationSection)section
                target:(id)target
                action:(SEL)action;

// Sets the selected segment on the navigation bar already attached to
// the window. No-op when the window carries no navigation bar.
+ (void)selectSection:(SFNavigationSection)section inWindow:(NSWindow *)window;

// Freshness badge (snowfell-test-5, freshness remainder, board #78):
// when the session's sync state names a gap (a served snapshot newer
// than the running one, or a verified update staged), the Updates
// segment's label gains a filled dot — "Updates ●" — on every window;
// when the state clears, the plain label returns. The badge is a
// label state, not a parallel control: the segment still fires the
// same action. No-op when the window carries no navigation bar.
+ (void)setUpdatesBadgeVisible:(BOOL)visible inWindow:(NSWindow *)window;

@end

NS_ASSUME_NONNULL_END
