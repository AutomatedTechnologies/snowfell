// AcademyAppIconView — the shared Academy welcome/About icon surface.
//
// SDS-10 §10.1.2: the SAME AppIcon composition from the SAME master appears
// on the bundle AppIcon, the Dock, the SDS-8 welcome screen, and the About
// panel (the DistroLogoView pattern, distro-test-40). This view is that
// single surface: it draws the bundle's own AppIcon — it never carries a
// second, divergent mark. When the bundle gains its registered Snowfell
// .icns, every surface unifies automatically because all of them read the
// same asset through this view / the application icon.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AcademyAppIconView : NSView

// The image this view draws: the application icon (the bundle AppIcon
// composition). Exposed so callers/tests can confirm the source asset.
@property (nonatomic, strong, readonly) NSImage *iconImage;

@end

NS_ASSUME_NONNULL_END
