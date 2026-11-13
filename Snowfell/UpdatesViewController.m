#import "UpdatesViewController.h"
#import "SnapshotStore.h"

@interface UpdatesViewController ()
@property (nonatomic, strong, readwrite) SnapshotStore *snapshotStore;
@property (nonatomic, strong) NSTextField *runningField;
@property (nonatomic, strong) NSTextField *servedField;
@property (nonatomic, strong) NSTextField *gapField;
@property (nonatomic, strong) NSTextField *statusField;
@property (nonatomic, strong) NSButton *applyButton;
@end

@implementation UpdatesViewController

- (instancetype)initWithSnapshotStore:(SnapshotStore *)store {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _snapshotStore = store;
        _statusText = @"";
    }
    return self;
}

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 300)];

    NSTextField *header = [NSTextField labelWithString:@"Snapshot updates"];
    [header setFont:[NSFont systemFontOfSize:15 weight:NSFontWeightSemibold]];
    [header setFrame:NSMakeRect(20, 300 - 36, 600, 20)];
    [header setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:header];

    _runningField = [NSTextField labelWithString:@""];
    [_runningField setFont:[NSFont systemFontOfSize:13]];
    [_runningField setFrame:NSMakeRect(20, 300 - 66, 600, 18)];
    [_runningField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:_runningField];

    _servedField = [NSTextField labelWithString:@""];
    [_servedField setFont:[NSFont systemFontOfSize:13]];
    [_servedField setFrame:NSMakeRect(20, 300 - 90, 600, 18)];
    [_servedField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:_servedField];

    _gapField = [NSTextField labelWithString:@""];
    [_gapField setFont:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]];
    [[_gapField cell] setWraps:YES];
    [_gapField setFrame:NSMakeRect(20, 300 - 128, 600, 30)];
    [_gapField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:_gapField];

    _statusField = [NSTextField labelWithString:@""];
    [_statusField setFont:[NSFont systemFontOfSize:12]];
    [_statusField setTextColor:[NSColor secondaryLabelColor]];
    [[_statusField cell] setWraps:YES];
    [_statusField setFrame:NSMakeRect(20, 52, 600, 96)];
    [_statusField setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [root addSubview:_statusField];

    NSButton *checkButton = [[NSButton alloc] initWithFrame:NSMakeRect(20, 12, 120, 28)];
    [checkButton setTitle:@"Check Now"];
    [checkButton setBezelStyle:NSBezelStyleRounded];
    [checkButton setTarget:self];
    [checkButton setAction:@selector(checkClicked:)];
    [root addSubview:checkButton];

    _applyButton = [[NSButton alloc] initWithFrame:NSMakeRect(150, 12, 140, 28)];
    [_applyButton setTitle:@"Apply Update"];
    [_applyButton setBezelStyle:NSBezelStyleRounded];
    [_applyButton setTarget:self];
    [_applyButton setAction:@selector(applyClicked:)];
    [root addSubview:_applyButton];

    self.view = root;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self refreshUpdates];
}

#pragma mark - Rendering

- (void)refreshUpdates {
    NSString *runningVersion = self.snapshotStore.snapshotVersion;
    NSString *runningSHA = self.snapshotStore.snapshotSHA256;
    if (runningVersion != nil) {
        NSString *shortSHA = (runningSHA != nil && [runningSHA length] > 12)
            ? [NSString stringWithFormat:@"%@…", [runningSHA substringToIndex:12]]
            : (runningSHA != nil ? runningSHA : @"—");
        [_runningField setStringValue:[NSString stringWithFormat:
                                       @"Running snapshot: %@ (SHA-256 %@)",
                                       runningVersion, shortSHA]];
    } else {
        [_runningField setStringValue:@"Running snapshot: none verified"];
    }

    if (self.servedVersion != nil) {
        [_servedField setStringValue:[NSString stringWithFormat:
                                      @"Served snapshot: %@ (detroitautomationacademy.com)",
                                      self.servedVersion]];
    } else {
        [_servedField setStringValue:@"Served snapshot: not checked yet"];
    }

    if (runningVersion != nil && self.servedVersion != nil) {
        if ([runningVersion isEqualToString:self.servedVersion]) {
            [_gapField setStringValue:@"Up to date — the running snapshot is the published one."];
        } else {
            [_gapField setStringValue:[NSString stringWithFormat:
                                       @"Running %@ · Served %@ — an update is published",
                                       runningVersion, self.servedVersion]];
        }
    } else if (self.servedVersion == nil) {
        [_gapField setStringValue:@"Check Now fetches the published manifest; nothing downloads or swaps on its own."];
    } else {
        [_gapField setStringValue:@"No verified snapshot is running, so there is nothing to compare the served one against."];
    }

    [_statusField setStringValue:(self.statusText != nil) ? self.statusText : @""];
    [_applyButton setEnabled:self.stagedUpdateAvailable];
}

#pragma mark - Buttons (forwarded to AppDelegate's existing actions)

- (IBAction)checkClicked:(id)sender {
    if (self.checkRequestedHandler != nil) {
        self.checkRequestedHandler();
    }
}

- (IBAction)applyClicked:(id)sender {
    if (self.applyRequestedHandler != nil) {
        self.applyRequestedHandler();
    }
}

@end
