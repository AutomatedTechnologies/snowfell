// AcademyWelcomeController — the SDS-8 welcome sheet, shared-component style
// (the AcademyWelcomeController + AcademyAppIconView pattern carried by the
// SDS-10 builds: KisMac test-build-19, Workbench staged-v1-9).
//
// SDS-10 conformance surfaces, all in this one presentation:
//  - §10.1.2 logo: AcademyAppIconView draws the bundle AppIcon composition.
//  - §10.2 version at startup: the version line is READ FROM the bundle's
//    own Info.plist at runtime (CFBundleShortVersionString /
//    CFBundleVersion) — never hardcoded.
//  - §10.3 startup sound: Resources/startup-sound.wav, byte-identical to
//    the library master, played ONCE when the welcome presents, at system
//    volume, no loop.
#import <AppKit/AppKit.h>

@class SnapshotStore;

NS_ASSUME_NONNULL_BEGIN

@interface AcademyWelcomeController : NSWindowController

// The runtime-read version line, e.g. "Version 0.1.0 (1)". Also used by the
// About panel so welcome and About can never disagree (SDS-10 §10.2.3).
+ (NSString *)bundleVersionLine;

// store supplies the snapshot line ("Registry snapshot v7-0026 · 74 boards
// · 614 items") or, when the load failed, the failure fact. May be nil, in
// which case the snapshot line states that no snapshot is loaded.
- (instancetype)initWithSnapshotStore:(nullable SnapshotStore *)store;

// Presents the welcome as a sheet on the given window and plays the
// startup sound once. The sheet dismisses via its Begin button.
- (void)presentAsSheetOnWindow:(NSWindow *)parentWindow;

@end

NS_ASSUME_NONNULL_END
