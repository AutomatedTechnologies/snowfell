#import "NavigationBar.h"
#import <objc/runtime.h>

NSToolbarIdentifier const SFNavigationToolbarIdentifier = @"SnowfellNavigationToolbar";
NSToolbarItemIdentifier const SFNavigationSegmentsItemIdentifier = @"SnowfellNavigationSegments";

// The builder lives as long as its window: it is the toolbar's delegate
// and the segmented control's owner, so the window retains it through
// an associated object (the toolbar itself does not retain its delegate).
static const void *SFNavigationBarBuilderKey = &SFNavigationBarBuilderKey;

@interface NavigationBar ()
@property (nonatomic, strong) NSSegmentedControl *segmentedControl;
@property (nonatomic, strong) NSToolbarItem *segmentsItem;
@property (nonatomic, weak) id segmentTarget;
@property (nonatomic, assign) SEL segmentAction;
@end

@implementation NavigationBar

+ (NSArray<NSString *> *)sectionLabels {
    return @[@"Portfolio", @"Board", @"Staged", @"Orchestration",
             @"Roadmap", @"Incidents", @"Storage", @"Updates"];
}

+ (void)attachToWindow:(NSWindow *)window
               section:(SFNavigationSection)section
                target:(id)target
                action:(SEL)action {
    NavigationBar *bar = [[NavigationBar alloc] init];
    bar.segmentTarget = target;
    bar.segmentAction = action;

    NSSegmentedControl *control = [NSSegmentedControl
        segmentedControlWithLabels:[self sectionLabels]
                      trackingMode:NSSegmentSwitchTrackingSelectOne
                            target:target
                            action:action];
    [control setSelectedSegment:section];
    [control sizeToFit];
    bar.segmentedControl = control;

    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:SFNavigationToolbarIdentifier];
    [toolbar setDelegate:bar];
    [toolbar setAllowsUserCustomization:NO];
    [toolbar setAutosavesConfiguration:NO];
    [window setToolbar:toolbar];

    objc_setAssociatedObject(window, SFNavigationBarBuilderKey, bar,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (void)selectSection:(SFNavigationSection)section inWindow:(NSWindow *)window {
    NavigationBar *bar = objc_getAssociatedObject(window, SFNavigationBarBuilderKey);
    [bar.segmentedControl setSelectedSegment:section];
}

+ (void)setUpdatesBadgeVisible:(BOOL)visible inWindow:(NSWindow *)window {
    NavigationBar *bar = objc_getAssociatedObject(window, SFNavigationBarBuilderKey);
    if (bar == nil) {
        return;
    }
    NSString *label = visible ? @"Updates ●" : @"Updates";
    if ([[bar.segmentedControl labelForSegment:SFNavigationSectionUpdates] isEqualToString:label]) {
        return;
    }
    [bar.segmentedControl setLabel:label forSegment:SFNavigationSectionUpdates];
    [bar.segmentedControl sizeToFit];
    for (NSToolbarItem *item in [[window toolbar] items]) {
        if ([[item itemIdentifier] isEqualToString:SFNavigationSegmentsItemIdentifier]) {
            NSSize size = bar.segmentedControl.frame.size;
            [item setMinSize:size];
            [item setMaxSize:size];
        }
    }
}

#pragma mark - NSToolbarDelegate

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
     itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
 willBeInsertedIntoToolbar:(BOOL)flag {
    if (![itemIdentifier isEqualToString:SFNavigationSegmentsItemIdentifier]) {
        return nil;
    }
    // snowfell-test-6 (defect record files/11, suspect S2): the item is
    // built ONCE and the SAME instance is returned on every call. The
    // pre-test-6 delegate returned a NEW item per call while installing
    // the SAME segmented control view in each — a view may live in only
    // one toolbar item, so a second request (toolbar rebuild, window
    // becoming key, validation) stole the control from the first item.
    if (self.segmentsItem == nil) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        [item setLabel:@"Navigate"];
        [item setPaletteLabel:@"Navigate"];
        [item setView:self.segmentedControl];
        NSSize size = self.segmentedControl.frame.size;
        [item setMinSize:size];
        [item setMaxSize:size];
        self.segmentsItem = item;
    }
    return self.segmentsItem;
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[SFNavigationSegmentsItemIdentifier];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return @[SFNavigationSegmentsItemIdentifier];
}

@end
