// Snowfell — main entry point.
// Programmatic UI (Distro pattern): no nib, no storyboard. The AppDelegate
// builds the menu bar, the main window, and the welcome sheet in code.
#import <AppKit/AppKit.h>
#import "AppDelegate.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [application setDelegate:delegate];
        [application run];
    }
    return 0;
}
