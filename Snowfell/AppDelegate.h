// AppDelegate — Snowfell's shell: code-constructed menu bar (SDS-10 §10.4,
// every item wired), the main Portfolio window, the startup sequence
// (verified snapshot load → V2 Portfolio → SDS-8 welcome sheet with the
// SDS-10 version line and startup sound).
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Menu-item validation rides the 10.13 informal protocol (NSMenu.h's
// validateMenuItem: on NSObject); the formal NSMenuItemValidation protocol
// name does not exist in the 10.13 SDK headers, so it is not listed here.
@interface AppDelegate : NSObject <NSApplicationDelegate>

@end

NS_ASSUME_NONNULL_END
