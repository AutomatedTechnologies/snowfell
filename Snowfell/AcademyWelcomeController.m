#import "AcademyWelcomeController.h"
#import "AcademyAppIconView.h"
#import "SnapshotStore.h"

@interface AcademyWelcomeController ()
@property (nonatomic, strong, nullable) SnapshotStore *snapshotStore;
@property (nonatomic, strong, nullable) NSSound *startupSound;
@property (nonatomic, weak, nullable) NSWindow *sheetParent;
@end

@implementation AcademyWelcomeController

+ (NSString *)bundleVersionLine {
    // SDS-10 §10.2.2: read from the bundle's own Info.plist at runtime.
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *shortVersion = info[@"CFBundleShortVersionString"];
    NSString *buildVersion = info[@"CFBundleVersion"];
    if (shortVersion != nil && buildVersion != nil) {
        return [NSString stringWithFormat:@"Version %@ (%@)", shortVersion, buildVersion];
    }
    if (buildVersion != nil) {
        return [NSString stringWithFormat:@"Version %@", buildVersion];
    }
    return @"Version unknown";
}

- (instancetype)initWithSnapshotStore:(SnapshotStore *)store {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 460, 300)
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    self = [super initWithWindow:window];
    if (self) {
        _snapshotStore = store;
        [self buildContent];
    }
    return self;
}

- (NSString *)snapshotLine {
    SnapshotStore *store = self.snapshotStore;
    if (store == nil || store.snapshotPath == nil) {
        NSString *reason = (store.loadError != nil) ? store.loadError.localizedDescription
                                                    : @"No snapshot is loaded.";
        return [NSString stringWithFormat:@"Registry snapshot unavailable — %@", reason];
    }
    NSError *error = nil;
    NSArray *boards = [store portfolioBoardsWithError:&error];
    if (boards == nil) {
        return [NSString stringWithFormat:@"Registry snapshot %@ — portfolio unavailable: %@",
                store.snapshotVersion, error.localizedDescription];
    }
    NSInteger itemTotal = 0;
    for (id board in boards) {
        itemTotal += [[board valueForKey:@"itemCount"] integerValue];
    }
    return [NSString stringWithFormat:@"Registry snapshot %@ · %lu boards · %ld items",
            store.snapshotVersion, (unsigned long)[boards count], (long)itemTotal];
}

- (void)buildContent {
    NSWindow *window = [self window];
    [window setTitle:@"Welcome"];
    NSView *content = [window contentView];

    AcademyAppIconView *iconView = [[AcademyAppIconView alloc] initWithFrame:NSMakeRect(166, 168, 128, 128)];
    [content addSubview:iconView];

    NSTextField *titleField = [NSTextField labelWithString:@"Snowfell"];
    [titleField setFont:[NSFont systemFontOfSize:28 weight:NSFontWeightSemibold]];
    [titleField setAlignment:NSTextAlignmentCenter];
    [titleField setFrame:NSMakeRect(30, 128, 400, 34)];
    [content addSubview:titleField];

    NSTextField *versionField = [NSTextField labelWithString:[[self class] bundleVersionLine]];
    [versionField setFont:[NSFont systemFontOfSize:12]];
    [versionField setTextColor:[NSColor secondaryLabelColor]];
    [versionField setAlignment:NSTextAlignmentCenter];
    [versionField setFrame:NSMakeRect(30, 104, 400, 18)];
    [content addSubview:versionField];

    NSTextField *snapshotField = [NSTextField labelWithString:[self snapshotLine]];
    [snapshotField setFont:[NSFont systemFontOfSize:12]];
    [snapshotField setTextColor:[NSColor secondaryLabelColor]];
    [snapshotField setAlignment:NSTextAlignmentCenter];
    [snapshotField setFrame:NSMakeRect(30, 82, 400, 18)];
    [content addSubview:snapshotField];

    NSButton *beginButton = [[NSButton alloc] initWithFrame:NSMakeRect(180, 28, 100, 28)];
    [beginButton setTitle:@"Begin"];
    [beginButton setBezelStyle:NSBezelStyleRounded];
    [beginButton setKeyEquivalent:@"\r"];
    [beginButton setTarget:self];
    [beginButton setAction:@selector(dismissWelcome:)];
    [content addSubview:beginButton];
}

- (void)playStartupSoundOnce {
    // SDS-10 §10.3: byte-identical startup-sound.wav from Resources, once,
    // at system volume, no loop (NSSound does not loop unless asked).
    NSString *soundPath = [[NSBundle mainBundle] pathForResource:@"startup-sound" ofType:@"wav"];
    if (soundPath == nil) {
        return;
    }
    self.startupSound = [[NSSound alloc] initWithContentsOfFile:soundPath byReference:YES];
    [self.startupSound play];
}

- (void)presentAsSheetOnWindow:(NSWindow *)parentWindow {
    NSWindow *sheet = [self window];
    self.sheetParent = parentWindow;
    [parentWindow beginSheet:sheet completionHandler:nil];
    [self playStartupSoundOnce];
}

- (IBAction)dismissWelcome:(id)sender {
    NSWindow *sheet = [self window];
    if (self.sheetParent != nil) {
        [self.sheetParent endSheet:sheet];
    }
    [sheet orderOut:sender];
    self.sheetParent = nil;
}

@end
