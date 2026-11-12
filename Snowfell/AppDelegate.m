#import "AppDelegate.h"
#import "AcademyWelcomeController.h"
#import "PortfolioViewController.h"
#import "BoardViewController.h"
#import "ItemDetailViewController.h"
#import "WriteBackQueueViewController.h"
#import "OrchestrationViewController.h"
#import "RoadmapViewController.h"
#import "CommandPaletteViewController.h"
#import "IncidentsViewController.h"
#import "IncidentModels.h"
#import "StorageViewController.h"
#import "CloudServiceClient.h"
#import "AcademyTheme.h"
#import "BoardSummary.h"
#import "BoardItem.h"
#import "DatedItem.h"
#import "DraftRow.h"
#import "SnapshotStore.h"
#import "StatusField.h"
#import "WriteBackQueue.h"
#import "DispatchStore.h"
#import "GitHubProjectsClient.h"
#import "SnapshotSync.h"

@interface AppDelegate () <BoardViewControllerDelegate>
@property (nonatomic, strong) NSWindow *mainWindow;
@property (nonatomic, strong) NSWindow *boardWindow;
@property (nonatomic, strong) NSWindow *detailWindow;
@property (nonatomic, strong) NSWindow *queueWindow;
@property (nonatomic, strong) NSWindow *orchestrationWindow;
@property (nonatomic, strong) NSWindow *roadmapWindow;
@property (nonatomic, strong) NSPanel *palettePanel;
@property (nonatomic, strong) NSWindow *preferencesWindow;
@property (nonatomic, strong) SnapshotStore *snapshotStore;
@property (nonatomic, strong) PortfolioViewController *portfolioController;
@property (nonatomic, strong) BoardViewController *boardController;
@property (nonatomic, strong) ItemDetailViewController *detailController;
@property (nonatomic, strong) WriteBackQueueViewController *queueController;
@property (nonatomic, strong) OrchestrationViewController *orchestrationController;
@property (nonatomic, strong) RoadmapViewController *roadmapController;
@property (nonatomic, strong) CommandPaletteViewController *paletteController;
@property (nonatomic, strong) IncidentsViewController *incidentsController;
@property (nonatomic, strong) NSWindow *incidentsWindow;
@property (nonatomic, strong) StorageViewController *storageController;
@property (nonatomic, strong) NSWindow *storageWindow;
// SF-T12f: the Storage lens's REST client — created LAZILY by its
// getter on first use (the client itself is stateless apart from its
// session; the operator token is never held here or anywhere but the
// Keychain, read by the client at call time).
@property (nonatomic, strong, nullable) CloudServiceClient *cloudServiceClient;
@property (nonatomic, strong) AcademyWelcomeController *welcomeController;
// SF-T4 write-back machinery: the local queue + the (inert) GitHub
// client. The queue opens at launch; the client is never asked to send
// except by the owner's explicit sendPendingMutations: action, and in
// this build the client's compile-time lock refuses regardless.
@property (nonatomic, strong, nullable) WriteBackQueue *writeBackQueue;
@property (nonatomic, strong, nullable) NSError *writeBackQueueError;
// SF-T5: the estate-lane dispatch store — a sibling table set in the
// SAME file as the write-back queue (DispatchStore.defaultStorePath is
// WriteBackQueue's path), sharing local_audit_log. Enqueue-only from
// this app; Minion/hooks execute (SF-T6).
@property (nonatomic, strong, nullable) DispatchStore *dispatchStore;
@property (nonatomic, strong, nullable) NSError *dispatchStoreError;
@property (nonatomic, strong) GitHubProjectsClient *githubClient;
// SF-T6 snapshot sync: the fetcher/stager plus the session's sync state.
// Sync is owner-pressed only — nothing here runs on a timer. The staged
// pair is a VERIFIED download (SnapshotSync checks size + SHA-256 before
// Apply ever enables); the swap itself goes through the same
// SnapshotStore load path as File > Open Snapshot....
@property (nonatomic, strong) SnapshotSync *snapshotSync;
@property (nonatomic, copy, nullable) NSDictionary *servedManifest;
@property (nonatomic, copy, nullable) NSString *stagedDatabasePath;
@property (nonatomic, copy, nullable) NSString *stagedManifestPath;
@property (nonatomic, copy) NSString *syncStatusText;
@end

@implementation AppDelegate

#pragma mark - Lifecycle

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setMainMenu:[self buildMainMenu]];

    // Startup sequence (design §2 contract): verify + open the bundled
    // snapshot FIRST; the Portfolio and the welcome both read its verdict.
    self.snapshotStore = [[SnapshotStore alloc] init];
    [self.snapshotStore loadBundledSnapshot];

    // SF-T4: open the LOCAL write-back queue (its own file in Application
    // Support — the snapshot is untouched) and stand up the GitHub
    // client object. Opening the queue sends nothing; the client is
    // inert unless an armed build's owner fires sendPendingMutations:.
    NSError *queueError = nil;
    self.writeBackQueue = [[WriteBackQueue alloc] initWithStorePath:[WriteBackQueue defaultStorePath]
                                                              error:&queueError];
    self.writeBackQueueError = queueError;
    // SF-T5: open the estate-lane dispatch store (same file, sibling
    // tables). Opening it enqueues and executes nothing.
    NSError *dispatchError = nil;
    self.dispatchStore = [[DispatchStore alloc] initWithStorePath:[DispatchStore defaultStorePath]
                                                            error:&dispatchError];
    self.dispatchStoreError = dispatchError;
    self.githubClient = [[GitHubProjectsClient alloc] init];
    // SF-T6: stand up the sync object + its initial (unchecked) state.
    // No fetch happens here — sync starts at the owner's Check Now.
    self.snapshotSync = [[SnapshotSync alloc] init];
    self.syncStatusText = @"Not checked yet — Check Now fetches the published manifest; nothing downloads or swaps on its own.";

    self.portfolioController = [[PortfolioViewController alloc] initWithSnapshotStore:self.snapshotStore];
    [self wirePortfolioController];

    NSRect frame = NSMakeRect(0, 0, 960, 600);
    self.mainWindow = [[NSWindow alloc] initWithContentRect:frame
                                                  styleMask:(NSWindowStyleMaskTitled |
                                                             NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskMiniaturizable |
                                                             NSWindowStyleMaskResizable)
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    [self.mainWindow setTitle:@"Snowfell — Portfolio"];
    // snowfell-test-2 uplift: the baseline window field (--win #f6f6f6)
    // behind every lens hosted in the main window.
    [self.mainWindow setBackgroundColor:[AcademyTheme windowColor]];
    [self.mainWindow setContentViewController:self.portfolioController];
    [self.mainWindow setMinSize:NSMakeSize(720, 420)];
    [self.mainWindow center];
    [self.mainWindow makeKeyAndOrderFront:nil];

    // SDS-8 welcome + SDS-10 startup surfaces (logo / version / sound).
    self.welcomeController = [[AcademyWelcomeController alloc] initWithSnapshotStore:self.snapshotStore];
    NSWindow *window = self.mainWindow;
    AcademyWelcomeController *welcome = self.welcomeController;
    dispatch_async(dispatch_get_main_queue(), ^{
        [welcome presentAsSheetOnWindow:window];
    });
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

#pragma mark - Menu construction (SDS-10 §10.4: real bar, every item wired)

- (NSMenuItem *)itemWithTitle:(NSString *)title
                       action:(SEL)action
                keyEquivalent:(NSString *)key
                       target:(id)target {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    [item setTarget:target];
    return item;
}

- (NSMenu *)buildMainMenu {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    // — App menu —
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItem:[self itemWithTitle:@"About Snowfell"
                                  action:@selector(showAbout:)
                           keyEquivalent:@""
                                  target:self]];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:[self itemWithTitle:@"Preferences…"
                                  action:@selector(showPreferences:)
                           keyEquivalent:@","
                                  target:self]];
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quitItem = [self itemWithTitle:@"Quit Snowfell"
                                        action:@selector(terminate:)
                                 keyEquivalent:@"q"
                                        target:NSApp];
    [appMenu addItem:quitItem];
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    [appMenuItem setSubmenu:appMenu];
    [mainMenu addItem:appMenuItem];

    // — File menu —
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItem:[self itemWithTitle:@"Open Snapshot…"
                                   action:@selector(openSnapshot:)
                            keyEquivalent:@"o"
                                   target:self]];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItem:[self itemWithTitle:@"Refresh Portfolio"
                                   action:@selector(refreshPortfolio:)
                            keyEquivalent:@"r"
                                   target:self]];
    NSMenuItem *syncItem = [self itemWithTitle:@"Check for Snapshot Update…"
                                        action:@selector(checkForSnapshotUpdate:)
                                 keyEquivalent:@""
                                        target:self];
    [syncItem setTag:302];
    [fileMenu addItem:syncItem];
    NSMenuItem *sendItem = [self itemWithTitle:@"Send Pending Mutations…"
                                        action:@selector(sendPendingMutations:)
                                 keyEquivalent:@""
                                        target:self];
    [sendItem setTag:301];
    [fileMenu addItem:sendItem];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItem:[self itemWithTitle:@"Close Window"
                                   action:@selector(closeWindow:)
                            keyEquivalent:@"w"
                                   target:self]];
    NSMenuItem *fileMenuItem = [[NSMenuItem alloc] init];
    [fileMenuItem setTitle:@"File"];
    [fileMenuItem setSubmenu:fileMenu];
    [mainMenu addItem:fileMenuItem];

    // — Edit menu (first-responder chain: the selectors are NSText's) —
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItem:[self itemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x" target:nil]];
    [editMenu addItem:[self itemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c" target:nil]];
    [editMenu addItem:[self itemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v" target:nil]];
    [editMenu addItem:[self itemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a" target:nil]];
    NSMenuItem *editMenuItem = [[NSMenuItem alloc] init];
    [editMenuItem setTitle:@"Edit"];
    [editMenuItem setSubmenu:editMenu];
    [mainMenu addItem:editMenuItem];

    // — View menu —
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem *closedItem = [self itemWithTitle:@"Show Closed Boards"
                                          action:@selector(toggleShowClosedBoards:)
                                   keyEquivalent:@""
                                          target:self];
    [closedItem setTag:101];
    [viewMenu addItem:closedItem];
    NSMenuItem *archivedItem = [self itemWithTitle:@"Show Archived Boards"
                                            action:@selector(toggleShowArchivedBoards:)
                                     keyEquivalent:@""
                                            target:self];
    [archivedItem setTag:102];
    [viewMenu addItem:archivedItem];
    [viewMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *portfolioItem = [self itemWithTitle:@"Portfolio"
                                             action:@selector(showPortfolio:)
                                      keyEquivalent:@"1"
                                             target:self];
    [portfolioItem setTag:201];
    [viewMenu addItem:portfolioItem];
    NSMenuItem *boardItem = [self itemWithTitle:@"Board"
                                         action:@selector(showBoard:)
                                  keyEquivalent:@"2"
                                         target:self];
    [boardItem setTag:202];
    [viewMenu addItem:boardItem];
    NSMenuItem *detailItem = [self itemWithTitle:@"Item Detail"
                                          action:@selector(showItemDetail:)
                                   keyEquivalent:@"3"
                                          target:self];
    [detailItem setTag:203];
    [viewMenu addItem:detailItem];
    NSMenuItem *queueItem = [self itemWithTitle:@"Write-back Queue"
                                         action:@selector(showWriteBackQueue:)
                                  keyEquivalent:@"4"
                                         target:self];
    [queueItem setTag:204];
    [viewMenu addItem:queueItem];
    NSMenuItem *orchestrationItem = [self itemWithTitle:@"Orchestration Center"
                                                 action:@selector(showOrchestrationCenter:)
                                          keyEquivalent:@"5"
                                                 target:self];
    [orchestrationItem setTag:205];
    [viewMenu addItem:orchestrationItem];
    NSMenuItem *roadmapItem = [self itemWithTitle:@"Roadmap"
                                           action:@selector(showRoadmap:)
                                    keyEquivalent:@"6"
                                           target:self];
    [roadmapItem setTag:206];
    [viewMenu addItem:roadmapItem];
    // SF-T11: the V11 Incidents lens (design record §13, View Menu section).
    NSMenuItem *incidentsItem = [self itemWithTitle:@"Incidents"
                                             action:@selector(showIncidents:)
                                      keyEquivalent:@"7"
                                             target:self];
    [incidentsItem setTag:208];
    [viewMenu addItem:incidentsItem];
    // SF-T12f: the V12 Storage lens (cloud storage design record 03, §9).
    NSMenuItem *storageItem = [self itemWithTitle:@"Storage"
                                           action:@selector(showStorage:)
                                    keyEquivalent:@"8"
                                           target:self];
    [storageItem setTag:209];
    [viewMenu addItem:storageItem];
    [viewMenu addItem:[NSMenuItem separatorItem]];
    // SF-T7: ⌘K is an ordinary app-menu item — the app's ONLY palette
    // registration (no global hotkey, nothing outside this menu).
    NSMenuItem *paletteItem = [self itemWithTitle:@"Command Palette…"
                                           action:@selector(showCommandPalette:)
                                    keyEquivalent:@"k"
                                           target:self];
    [paletteItem setTag:207];
    [viewMenu addItem:paletteItem];
    [viewMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *fullScreenItem = [self itemWithTitle:@"Enter Full Screen"
                                              action:@selector(toggleFullScreen:)
                                       keyEquivalent:@"f"
                                              target:self];
    [fullScreenItem setKeyEquivalentModifierMask:NSEventModifierFlagControl | NSEventModifierFlagCommand];
    [viewMenu addItem:fullScreenItem];
    NSMenuItem *viewMenuItem = [[NSMenuItem alloc] init];
    [viewMenuItem setTitle:@"View"];
    [viewMenuItem setSubmenu:viewMenu];
    [mainMenu addItem:viewMenuItem];

    // — Window menu —
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItem:[self itemWithTitle:@"Minimize"
                                     action:@selector(minimizeWindow:)
                              keyEquivalent:@"m"
                                     target:self]];
    [windowMenu addItem:[self itemWithTitle:@"Zoom"
                                     action:@selector(zoomWindow:)
                              keyEquivalent:@""
                                     target:self]];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItem:[self itemWithTitle:@"Bring All to Front"
                                     action:@selector(bringAllToFront:)
                              keyEquivalent:@""
                                     target:self]];
    NSMenuItem *windowMenuItem = [[NSMenuItem alloc] init];
    [windowMenuItem setTitle:@"Window"];
    [windowMenuItem setSubmenu:windowMenu];
    [mainMenu addItem:windowMenuItem];
    [NSApp setWindowsMenu:windowMenu];

    // — Help menu —
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
    [helpMenu addItem:[self itemWithTitle:@"Snapshot Details"
                                   action:@selector(showSnapshotDetails:)
                            keyEquivalent:@""
                                   target:self]];
    [helpMenu addItem:[self itemWithTitle:@"Snowfell Help"
                                   action:@selector(showHelp:)
                            keyEquivalent:@"?"
                                   target:self]];
    NSMenuItem *helpMenuItem = [[NSMenuItem alloc] init];
    [helpMenuItem setTitle:@"Help"];
    [helpMenuItem setSubmenu:helpMenu];
    [mainMenu addItem:helpMenuItem];
    [NSApp setHelpMenu:helpMenu];

    return mainMenu;
}

#pragma mark - Menu validation

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if ([menuItem tag] == 101) {
        [menuItem setState:self.portfolioController.showClosedBoards ? NSControlStateValueOn : NSControlStateValueOff];
        return YES;
    }
    if ([menuItem tag] == 102) {
        [menuItem setState:self.portfolioController.showArchivedBoards ? NSControlStateValueOn : NSControlStateValueOff];
        return YES;
    }
    if ([menuItem tag] == 202) {
        // Board needs a verified snapshot to read.
        return self.snapshotStore.snapshotPath != nil;
    }
    if ([menuItem tag] == 203) {
        // Item Detail is enabled exactly when a card is selected — the
        // disabled state is the honest wiring, not a dead item.
        return self.boardController.selectedItem != nil;
    }
    if ([menuItem tag] == 204) {
        return YES;  // the Queue panel always opens; it states its own state
    }
    if ([menuItem tag] == 205) {
        return YES;  // the Orchestration Center always opens; it states its own state
    }
    if ([menuItem tag] == 206) {
        // Roadmap reads the verified snapshot, like the Board.
        return self.snapshotStore.snapshotPath != nil;
    }
    if ([menuItem tag] == 207) {
        return YES;  // the palette always opens; it states its own state
    }
    if ([menuItem tag] == 209) {
        return YES;  // the Storage lens always opens; it states its own state (pairing / stopped / running)
    }
    if ([menuItem tag] == 302) {
        // Checking is always safe: it is a read-only GET of the Academy's
        // own published manifest, and any swap stays behind Apply.
        return YES;
    }
    if ([menuItem tag] == 301) {
        // Send Pending arms only when BOTH locks are open and work is
        // waiting: compiled in (SF-T4 lock — shut in this build) AND a
        // Keychain token configured AND at least one pending row.
        return [GitHubProjectsClient writeBackCompiledEnabled]
            && [self.githubClient tokenStatus] == GitHubTokenStatusAvailable
            && [self.writeBackQueue pendingCount] > 0;
    }
    return YES;
}

#pragma mark - App menu actions

- (IBAction)showAbout:(id)sender {
    // SDS-10 §10.2.3: the About panel shows the same runtime-read string
    // as the welcome screen.
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *version = [NSString stringWithFormat:@"%@ (%@)",
                         info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"]];
    [NSApp orderFrontStandardAboutPanelWithOptions:@{@"Version": version}];
    [NSApp activateIgnoringOtherApps:YES];
}

- (IBAction)showPreferences:(id)sender {
    if (self.preferencesWindow == nil) {
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 460, 452)
                                                       styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        [window setTitle:@"Snowfell Preferences"];
        NSView *content = [window contentView];

        NSString *snapshotText;
        if (self.snapshotStore.snapshotPath != nil) {
            snapshotText = [NSString stringWithFormat:@"Snapshot: %@ (pinned, SHA-256 verified at launch)",
                            self.snapshotStore.snapshotVersion];
        } else {
            snapshotText = [NSString stringWithFormat:@"Snapshot: none verified — %@",
                            self.snapshotStore.loadError.localizedDescription];
        }
        NSTextField *snapshotField = [NSTextField labelWithString:snapshotText];
        [snapshotField setFrame:NSMakeRect(20, 394, 420, 34)];
        [content addSubview:snapshotField];

        // V7 Sync & Settings (SF-T7 completion): three SEPARATE state
        // lines, each refreshed on every Preferences open (below) from
        // the live objects — nothing here fakes a state.
        //   401 GitHub token state: a Keychain PRESENCE check only
        //       (the client's attributes-only probe; the secret bytes
        //       never materialize, and are never read or displayed).
        //   407 Write-back flag state: the compiled value of
        //       SNOWFELL_WRITEBACK_ENABLED, read honestly.
        //   408 Queue counts: pending write-backs + queued estate
        //       dispatches, from the two local stores.
        NSTextField *tokenField = [NSTextField labelWithString:@""];
        [tokenField setTag:401];
        [[tokenField cell] setWraps:YES];
        [tokenField setFrame:NSMakeRect(20, 346, 420, 34)];
        [content addSubview:tokenField];

        NSTextField *writeBackField = [NSTextField labelWithString:@""];
        [writeBackField setTag:407];
        [[writeBackField cell] setWraps:YES];
        [writeBackField setFrame:NSMakeRect(20, 318, 420, 22)];
        [content addSubview:writeBackField];

        NSTextField *queueField = [NSTextField labelWithString:@""];
        [queueField setTag:408];
        [[queueField cell] setWraps:YES];
        [queueField setFrame:NSMakeRect(20, 290, 420, 22)];
        [content addSubview:queueField];

        // Token ENTRY cannot work in this app, by D4 design — so the
        // control renders disabled WITH its reason, per the V7 rule:
        // the token is provisioned directly into the Keychain (README
        // enable path); Snowfell only ever checks presence.
        NSTextField *tokenEntryLabel = [NSTextField labelWithString:@"GitHub token entry"];
        [tokenEntryLabel setFont:[NSFont boldSystemFontOfSize:[NSFont systemFontSize]]];
        [tokenEntryLabel setFrame:NSMakeRect(20, 262, 420, 18)];
        [content addSubview:tokenEntryLabel];

        NSTextField *tokenEntryField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 234, 420, 22)];
        [tokenEntryField setTag:409];
        [tokenEntryField setFont:[NSFont systemFontOfSize:11]];
        [tokenEntryField setStringValue:@"Disabled — D4 custody: provision into the Keychain directly; Snowfell never accepts a token in-app."];
        [tokenEntryField setEditable:NO];
        [tokenEntryField setEnabled:NO];
        [content addSubview:tokenEntryField];

        // SF-T6 Snapshot sync block. This replaces the SF-T2-era
        // "Sync: offline" line with the truthful new state: the running
        // snapshot's version, the last served version seen, and the sync
        // state text. Check Now is the only network trigger in the app
        // outside the (inert) write-back client; Apply Update enables
        // only when a VERIFIED staged pair exists. Nothing here runs on
        // a timer and nothing swaps without the Apply press.
        NSTextField *syncHeader = [NSTextField labelWithString:@"Snapshot sync"];
        [syncHeader setFont:[NSFont boldSystemFontOfSize:[NSFont systemFontSize]]];
        [syncHeader setFrame:NSMakeRect(20, 204, 420, 18)];
        [content addSubview:syncHeader];

        NSTextField *syncCurrentField = [NSTextField labelWithString:@""];
        [syncCurrentField setTag:402];
        [syncCurrentField setFrame:NSMakeRect(20, 182, 420, 18)];
        [content addSubview:syncCurrentField];

        NSTextField *syncServedField = [NSTextField labelWithString:@""];
        [syncServedField setTag:403];
        [syncServedField setFrame:NSMakeRect(20, 160, 420, 18)];
        [content addSubview:syncServedField];

        NSTextField *syncStateField = [NSTextField labelWithString:@""];
        [syncStateField setTag:404];
        [[syncStateField cell] setWraps:YES];
        [syncStateField setFrame:NSMakeRect(20, 122, 420, 34)];
        [content addSubview:syncStateField];

        NSButton *checkButton = [[NSButton alloc] initWithFrame:NSMakeRect(20, 60, 120, 28)];
        [checkButton setTitle:@"Check Now"];
        [checkButton setBezelStyle:NSBezelStyleRounded];
        [checkButton setTarget:self];
        [checkButton setAction:@selector(checkForSnapshotUpdate:)];
        [content addSubview:checkButton];

        NSButton *applyButton = [[NSButton alloc] initWithFrame:NSMakeRect(150, 60, 140, 28)];
        [applyButton setTag:406];
        [applyButton setTitle:@"Apply Update"];
        [applyButton setBezelStyle:NSBezelStyleRounded];
        [applyButton setTarget:self];
        [applyButton setAction:@selector(applyStagedSnapshot:)];
        [content addSubview:applyButton];

        NSButton *closeButton = [[NSButton alloc] initWithFrame:NSMakeRect(350, 60, 90, 28)];
        [closeButton setTitle:@"Close"];
        [closeButton setBezelStyle:NSBezelStyleRounded];
        [closeButton setTarget:self];
        [closeButton setAction:@selector(closePreferences:)];
        [content addSubview:closeButton];

        // SF-T12f Cloud service port (V12 Storage): the port half of
        // CloudServiceClient's loopback base URL — the host is pinned
        // to 127.0.0.1 in the client and is NOT a setting. The field
        // (tag 410) is refreshed on every Preferences open from
        // +[CloudServiceClient configuredPort] and writes
        // NSUserDefaults SnowfellCloudPort on commit (cloudPortChanged:);
        // an out-of-range entry is refused and the field resets.
        NSTextField *cloudPortLabel = [NSTextField labelWithString:@"Cloud service port (Storage):"];
        [cloudPortLabel setFont:[NSFont boldSystemFontOfSize:[NSFont systemFontSize]]];
        [cloudPortLabel setFrame:NSMakeRect(20, 26, 200, 18)];
        [content addSubview:cloudPortLabel];

        NSTextField *cloudPortField = [[NSTextField alloc] initWithFrame:NSMakeRect(224, 24, 64, 22)];
        [cloudPortField setTag:410];
        [cloudPortField setFont:[NSFont systemFontOfSize:12]];
        [cloudPortField setTarget:self];
        [cloudPortField setAction:@selector(cloudPortChanged:)];
        [content addSubview:cloudPortField];

        NSTextField *cloudPortHint = [NSTextField labelWithString:@"loopback only · default 8471"];
        [cloudPortHint setFont:[NSFont systemFontOfSize:11]];
        [cloudPortHint setTextColor:[NSColor secondaryLabelColor]];
        [cloudPortHint setFrame:NSMakeRect(296, 26, 144, 18)];
        [content addSubview:cloudPortHint];

        self.preferencesWindow = window;
    }
    // Refresh the V7 state lines from the live objects every open.
    // Token line: PRESENCE ONLY — tokenStatus is the client's
    // attributes-only Keychain probe; the secret is never read here.
    NSTextField *tokenField = (NSTextField *)[[self.preferencesWindow contentView] viewWithTag:401];
    BOOL tokenPresent = ([self.githubClient tokenStatus] == GitHubTokenStatusAvailable);
    [tokenField setStringValue:[NSString stringWithFormat:
                                @"GitHub token: %@ (Keychain service %@ — presence checked only; the secret is never read or shown).",
                                tokenPresent ? @"token present in Keychain" : @"no token stored",
                                GitHubProjectsKeychainService]];
    // Flag line: the compiled lock, stated as it is in THIS build.
    NSTextField *writeBackField = (NSTextField *)[[self.preferencesWindow contentView] viewWithTag:407];
    if ([GitHubProjectsClient writeBackCompiledEnabled]) {
        [writeBackField setStringValue:@"Write-back: ENABLED in this build (SNOWFELL_WRITEBACK_ENABLED = 1) — sending still requires the token and your explicit Send Pending action."];
    } else {
        [writeBackField setStringValue:@"Write-back: DISABLED in this build (SNOWFELL_WRITEBACK_ENABLED = 0) — no mutation can be sent from this build."];
    }
    // Queue line: both local stores' waiting counts (or their failure).
    NSTextField *queueField = (NSTextField *)[[self.preferencesWindow contentView] viewWithTag:408];
    NSString *writeBackCount = (self.writeBackQueue != nil)
        ? [NSString stringWithFormat:@"%ld write-back(s) pending", (long)[self.writeBackQueue pendingCount]]
        : [NSString stringWithFormat:@"write-back queue unavailable (%@)",
           self.writeBackQueueError.localizedDescription];
    NSString *dispatchCount = (self.dispatchStore != nil)
        ? [NSString stringWithFormat:@"%ld estate dispatch(es) queued", (long)[self.dispatchStore queuedCount]]
        : [NSString stringWithFormat:@"dispatch store unavailable (%@)",
           self.dispatchStoreError.localizedDescription];
    [queueField setStringValue:[NSString stringWithFormat:@"Local queues: %@ · %@", writeBackCount, dispatchCount]];
    // Cloud port line: the client's own configured value (defaults
    // key SnowfellCloudPort, default 8471) — never a cached copy.
    NSTextField *cloudPortField = (NSTextField *)[[self.preferencesWindow contentView] viewWithTag:410];
    [cloudPortField setIntegerValue:[CloudServiceClient configuredPort]];
    [self refreshSnapshotSyncBlock];
    [self.preferencesWindow center];
    [self.preferencesWindow makeKeyAndOrderFront:sender];
    [NSApp activateIgnoringOtherApps:YES];
}

- (IBAction)closePreferences:(id)sender {
    [self.preferencesWindow close];
}

// SF-T12f: commit of the Preferences Cloud service port field. Only
// the PORT is a setting — CloudServiceClient pins the host to
// 127.0.0.1 in code (design §9), so no preference can widen the base
// URL. Out-of-range input is refused and the field resets to the
// configured value.
- (IBAction)cloudPortChanged:(id)sender {
    NSTextField *field = (NSTextField *)sender;
    NSInteger port = [field integerValue];
    if (port < 1 || port > 65535) {
        [field setIntegerValue:[CloudServiceClient configuredPort]];
        return;
    }
    [[NSUserDefaults standardUserDefaults] setInteger:port forKey:CloudServicePortDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - File menu actions

- (IBAction)openSnapshot:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:NO];
    [panel setAllowsMultipleSelection:NO];
    [panel setAllowedFileTypes:@[@"db"]];
    [panel setMessage:@"Choose a registry.db snapshot. Its snapshot-manifest.json must sit beside it; the pair is verified before opening."];
    NSWindow *window = self.mainWindow;
    [panel beginSheetModalForWindow:window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) {
            return;
        }
        NSString *databasePath = [[panel URL] path];
        NSString *manifestPath = [[databasePath stringByDeletingLastPathComponent]
                                  stringByAppendingPathComponent:@"snapshot-manifest.json"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:manifestPath]) {
            manifestPath = [[databasePath stringByDeletingLastPathComponent]
                            stringByAppendingPathComponent:@"registry-manifest.json"];
        }
        SnapshotStore *store = [[SnapshotStore alloc] init];
        if ([store loadSnapshotAtPath:databasePath manifestPath:manifestPath]) {
            [self adoptLoadedSnapshotStore:store];
            // A manual swap supersedes any staged sync download.
            self.stagedDatabasePath = nil;
            self.stagedManifestPath = nil;
            self.syncStatusText = [NSString stringWithFormat:
                                   @"Manual snapshot opened (%@). Sync staging cleared.",
                                   store.snapshotVersion];
            [self refreshSnapshotSyncBlock];
        } else {
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:@"Snapshot not loaded"];
            [alert setInformativeText:store.loadError.localizedDescription];
            [alert beginSheetModalForWindow:window completionHandler:nil];
        }
    }];
}

// The ONE swap flow every snapshot replacement uses (File > Open
// Snapshot... since SF-T2; SF-T6 Apply Update since this tranche): the
// Portfolio rebuilds against the new store, and Board / Detail /
// Orchestration windows close — they were reading the replaced snapshot
// and rebuild lazily against the new store on demand. (The local stores
// — write-back queue + dispatches — are snapshot-independent and are
// never touched by a swap.)
- (void)adoptLoadedSnapshotStore:(SnapshotStore *)store {
    self.snapshotStore = store;
    self.portfolioController = [[PortfolioViewController alloc] initWithSnapshotStore:store];
    [self wirePortfolioController];
    [self.mainWindow setContentViewController:self.portfolioController];
    [self.boardWindow close];
    self.boardWindow = nil;
    self.boardController = nil;
    [self.detailWindow close];
    self.detailWindow = nil;
    self.detailController = nil;
    [self.orchestrationWindow close];
    self.orchestrationWindow = nil;
    self.orchestrationController = nil;
    [self.roadmapWindow close];
    self.roadmapWindow = nil;
    self.roadmapController = nil;
    [self.palettePanel close];
    self.palettePanel = nil;
    self.paletteController = nil;
}

- (IBAction)refreshPortfolio:(id)sender {
    [self.portfolioController reloadPortfolio];
}

#pragma mark - SF-T6 snapshot sync (owner-pressed; no background fetch or swap)

// Pushes the session's sync state into the Preferences block when the
// window exists. Called on Preferences open and after every sync step.
- (void)refreshSnapshotSyncBlock {
    if (self.preferencesWindow == nil) {
        return;
    }
    NSView *content = [self.preferencesWindow contentView];
    NSTextField *currentField = (NSTextField *)[content viewWithTag:402];
    NSTextField *servedField = (NSTextField *)[content viewWithTag:403];
    NSTextField *stateField = (NSTextField *)[content viewWithTag:404];
    NSButton *applyButton = (NSButton *)[content viewWithTag:406];
    if (self.snapshotStore.snapshotPath != nil) {
        [currentField setStringValue:[NSString stringWithFormat:@"Running snapshot: %@",
                                      self.snapshotStore.snapshotVersion]];
    } else {
        [currentField setStringValue:@"Running snapshot: none verified"];
    }
    if (self.servedManifest != nil) {
        [servedField setStringValue:[NSString stringWithFormat:@"Served snapshot: %@ (detroitautomationacademy.com)",
                                     self.servedManifest[@"version"]]];
    } else {
        [servedField setStringValue:@"Served snapshot: not checked yet"];
    }
    [stateField setStringValue:self.syncStatusText];
    [applyButton setEnabled:(self.stagedDatabasePath != nil && self.stagedManifestPath != nil)];
}

// When sync was triggered from the File menu with Preferences closed,
// the outcome still reaches the owner — as an alert, once, at completion.
- (void)presentSyncOutcomeAlertIfPreferencesClosedWithTitle:(NSString *)title {
    if (self.preferencesWindow != nil && [self.preferencesWindow isVisible]) {
        return;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:title];
    [alert setInformativeText:self.syncStatusText];
    [alert beginSheetModalForWindow:self.mainWindow completionHandler:nil];
}

- (IBAction)checkForSnapshotUpdate:(id)sender {
    self.syncStatusText = @"Checking detroitautomationacademy.com for the published snapshot manifest…";
    [self refreshSnapshotSyncBlock];
    [self.snapshotSync fetchServedManifestWithCompletion:^(NSDictionary *manifest, NSData *rawData, NSError *error) {
        if (manifest == nil) {
            self.syncStatusText = [NSString stringWithFormat:
                                   @"Sync check failed: %@ The running snapshot was not touched.",
                                   error.localizedDescription];
            [self refreshSnapshotSyncBlock];
            [self presentSyncOutcomeAlertIfPreferencesClosedWithTitle:@"Snapshot check failed"];
            return;
        }
        self.servedManifest = manifest;
        NSString *updateVersion = nil;
        SnapshotSyncCheckState state = [SnapshotSync checkStateForServedManifest:manifest
                                                                  loadedManifest:self.snapshotStore.manifest
                                                                 updateVersion:&updateVersion];
        if (state == SnapshotSyncCheckStateUpToDate) {
            self.syncStatusText = [NSString stringWithFormat:
                                   @"Up to date — the served snapshot is the running %@ (SHA-256 verified at load).",
                                   manifest[@"version"]];
            [self refreshSnapshotSyncBlock];
            [self presentSyncOutcomeAlertIfPreferencesClosedWithTitle:@"Snapshot up to date"];
            return;
        }
        if (state == SnapshotSyncCheckStateError) {
            self.syncStatusText = @"Sync check inconclusive: no verified snapshot is loaded, so there is nothing to compare the served manifest against. The running state was not touched.";
            [self refreshSnapshotSyncBlock];
            [self presentSyncOutcomeAlertIfPreferencesClosedWithTitle:@"Snapshot check inconclusive"];
            return;
        }
        // Update available: the Check press also downloads + verifies the
        // stage (a read-only GET of the Academy's own published bytes).
        // The SWAP remains a separate press — Apply Update.
        self.syncStatusText = [NSString stringWithFormat:
                               @"Update %@ is published — downloading and verifying it into staging…",
                               updateVersion];
        [self refreshSnapshotSyncBlock];
        [self.snapshotSync downloadAndStageServedManifest:manifest
                                        rawManifestData:rawData
                                             completion:^(NSString *stagedDatabasePath, NSString *stagedManifestPath, NSError *stageError) {
            if (stagedDatabasePath == nil) {
                self.syncStatusText = [NSString stringWithFormat:
                                       @"Update %@ could not be staged: %@ The running snapshot was not touched.",
                                       updateVersion, stageError.localizedDescription];
                [self refreshSnapshotSyncBlock];
                [self presentSyncOutcomeAlertIfPreferencesClosedWithTitle:@"Snapshot update not staged"];
                return;
            }
            self.stagedDatabasePath = stagedDatabasePath;
            self.stagedManifestPath = stagedManifestPath;
            self.syncStatusText = [NSString stringWithFormat:
                                   @"Update %@ downloaded and verified (size + SHA-256 match the served manifest) and staged. Press Apply Update to swap it in — the running %@ stands until you do.",
                                   updateVersion, self.snapshotStore.snapshotVersion];
            [self refreshSnapshotSyncBlock];
            [self presentSyncOutcomeAlertIfPreferencesClosedWithTitle:@"Snapshot update ready"];
        }];
    }];
}

// The swap press. The staged pair goes through the EXISTING SnapshotStore
// load path (verify-then-open, a second full verification at swap time)
// and the shared adopt flow — Portfolio rebuild, Board/Detail/
// Orchestration teardown, exactly as a manual Open Snapshot... swap.
- (IBAction)applyStagedSnapshot:(id)sender {
    if (self.stagedDatabasePath == nil || self.stagedManifestPath == nil) {
        return;
    }
    SnapshotStore *store = [[SnapshotStore alloc] init];
    if ([store loadSnapshotAtPath:self.stagedDatabasePath manifestPath:self.stagedManifestPath]) {
        NSString *appliedVersion = store.snapshotVersion;
        [self adoptLoadedSnapshotStore:store];
        self.stagedDatabasePath = nil;
        self.stagedManifestPath = nil;
        self.syncStatusText = [NSString stringWithFormat:
                               @"Running snapshot %@ — applied from the verified staged download. Board, Item Detail, and Orchestration windows rebuild against it on demand.",
                               appliedVersion];
    } else {
        self.syncStatusText = [NSString stringWithFormat:
                               @"Apply failed: %@ The running snapshot stands; the staged pair was left in place for inspection.",
                               store.loadError.localizedDescription];
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Snapshot update not applied"];
        [alert setInformativeText:store.loadError.localizedDescription];
        [alert beginSheetModalForWindow:self.mainWindow completionHandler:nil];
    }
    [self refreshSnapshotSyncBlock];
}

- (IBAction)closeWindow:(id)sender {
    [[NSApp keyWindow] performClose:sender];
}

#pragma mark - View menu actions

- (IBAction)toggleShowClosedBoards:(id)sender {
    self.portfolioController.showClosedBoards = !self.portfolioController.showClosedBoards;
}

- (IBAction)toggleShowArchivedBoards:(id)sender {
    self.portfolioController.showArchivedBoards = !self.portfolioController.showArchivedBoards;
}

- (IBAction)toggleFullScreen:(id)sender {
    [[NSApp keyWindow] toggleFullScreen:sender];
}

#pragma mark - View navigation (SF-T3: Portfolio / Board / Item Detail)

- (void)wirePortfolioController {
    __weak AppDelegate *weakSelf = self;
    self.portfolioController.boardActivationHandler = ^(BoardSummary *board) {
        [weakSelf openBoardForBoard:board];
    };
}

- (IBAction)showPortfolio:(id)sender {
    [self.mainWindow makeKeyAndOrderFront:sender];
    [NSApp activateIgnoringOtherApps:YES];
}

- (IBAction)showBoard:(id)sender {
    BoardSummary *board = [self.portfolioController selectedBoard];
    if (board != nil) {
        [self openBoardForBoard:board];
    } else {
        // No Portfolio selection: the Board opens on its own default
        // (user board #3) rather than doing nothing.
        [self ensureBoardWindow];
        [self.boardWindow makeKeyAndOrderFront:sender];
        [NSApp activateIgnoringOtherApps:YES];
    }
}

- (IBAction)showItemDetail:(id)sender {
    BoardItem *item = self.boardController.selectedItem;
    if (item != nil) {
        [self presentDetailForItem:item];
    }
}

- (void)ensureBoardWindow {
    if (self.boardController == nil) {
        self.boardController = [[BoardViewController alloc] initWithSnapshotStore:self.snapshotStore];
        self.boardController.delegate = self;
        __weak AppDelegate *weakSelf = self;
        self.boardController.statusMoveRequestHandler = ^(BoardItem *item,
                                                          BoardSummary *board,
                                                          NSString *optionName,
                                                          void (^completion)(BOOL enqueued)) {
            [weakSelf handleStatusMoveRequestForItem:item board:board optionName:optionName completion:completion];
        };
        self.boardController.createItemRequestHandler = ^(BoardSummary *board,
                                                          NSString *title,
                                                          NSString *optionName) {
            [weakSelf handleCreateItemRequestForBoard:board title:title optionName:optionName];
        };
    }
    if (self.boardWindow == nil) {
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1120, 660)
                                                       styleMask:(NSWindowStyleMaskTitled |
                                                                  NSWindowStyleMaskClosable |
                                                                  NSWindowStyleMaskMiniaturizable |
                                                                  NSWindowStyleMaskResizable)
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        [window setTitle:@"Snowfell — Board"];
        [window setContentViewController:self.boardController];
        [window setMinSize:NSMakeSize(760, 440)];
        [window center];
        self.boardWindow = window;
    }
}

- (void)openBoardForBoard:(BoardSummary *)board {
    [self ensureBoardWindow];
    [self.boardController showBoard:board];
    [self.boardWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)presentDetailForItem:(BoardItem *)item {
    if (self.detailController == nil) {
        self.detailController = [[ItemDetailViewController alloc] initWithSnapshotStore:self.snapshotStore];
        __weak AppDelegate *weakSelf = self;
        self.detailController.commentRequestHandler = ^(BoardItem *commentItem,
                                                        NSString *body,
                                                        void (^completion)(BOOL enqueued)) {
            [weakSelf handleCommentRequestForItem:commentItem body:body completion:completion];
        };
    }
    if (self.detailWindow == nil) {
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 780, 580)
                                                       styleMask:(NSWindowStyleMaskTitled |
                                                                  NSWindowStyleMaskClosable |
                                                                  NSWindowStyleMaskMiniaturizable |
                                                                  NSWindowStyleMaskResizable)
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        [window setTitle:@"Snowfell — Item Detail"];
        [window setContentViewController:self.detailController];
        [window setMinSize:NSMakeSize(620, 460)];
        [window center];
        self.detailWindow = window;
    }
    [self.detailController showItem:item];
    [self.detailWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

#pragma mark - SF-T4 write-back (queue-only in this build)

- (IBAction)showWriteBackQueue:(id)sender {
    if (self.queueController == nil) {
        self.queueController = [[WriteBackQueueViewController alloc] initWithQueue:self.writeBackQueue
                                                                            client:self.githubClient];
        __weak AppDelegate *weakSelf = self;
        self.queueController.sendRequestedHandler = ^{
            [weakSelf sendPendingMutations:nil];
        };
    }
    if (self.queueWindow == nil) {
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 520)
                                                       styleMask:(NSWindowStyleMaskTitled |
                                                                  NSWindowStyleMaskClosable |
                                                                  NSWindowStyleMaskMiniaturizable |
                                                                  NSWindowStyleMaskResizable)
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        [window setTitle:@"Snowfell — Write-back Queue"];
        [window setContentViewController:self.queueController];
        [window setMinSize:NSMakeSize(700, 380)];
        [window center];
        self.queueWindow = window;
    }
    [self.queueController reloadQueue];
    [self.queueWindow makeKeyAndOrderFront:sender];
    [NSApp activateIgnoringOtherApps:YES];
}

#pragma mark - SF-T5 orchestration (queue-only in this app, both lanes)

- (IBAction)showOrchestrationCenter:(id)sender {
    if (self.orchestrationController == nil) {
        self.orchestrationController = [[OrchestrationViewController alloc] initWithSnapshotStore:self.snapshotStore
                                                                                    dispatchStore:self.dispatchStore
                                                                                   writeBackQueue:self.writeBackQueue];
    }
    if (self.orchestrationWindow == nil) {
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1180, 720)
                                                       styleMask:(NSWindowStyleMaskTitled |
                                                                  NSWindowStyleMaskClosable |
                                                                  NSWindowStyleMaskMiniaturizable |
                                                                  NSWindowStyleMaskResizable)
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        [window setTitle:@"Snowfell — Orchestration Center"];
        [window setContentViewController:self.orchestrationController];
        [window setMinSize:NSMakeSize(1180, 720)];
        [window center];
        self.orchestrationWindow = window;
    }
    [self.orchestrationController reloadOrchestration];
    [self.orchestrationWindow makeKeyAndOrderFront:sender];
    [NSApp activateIgnoringOtherApps:YES];
}

// SF-T7 seam (palette routing): open the Orchestration Center and THEN
// preselect the action — showOrchestrationCenter reloads the manifest,
// and the reload's keep-selection logic must run before the routing
// lands, not after.
- (void)openOrchestrationCenterWithActionID:(NSString *)actionID {
    [self showOrchestrationCenter:nil];
    if (actionID != nil) {
        [self.orchestrationController selectActionWithID:actionID];
    }
}

#pragma mark - SF-T7 Roadmap (V5) + Command Palette (V6)

- (IBAction)showRoadmap:(id)sender {
    if (self.roadmapController == nil) {
        self.roadmapController = [[RoadmapViewController alloc] initWithSnapshotStore:self.snapshotStore];
        __weak AppDelegate *weakSelf = self;
        self.roadmapController.itemActivationHandler = ^(DatedItem *datedItem) {
            // The timeline row is a DatedItem; V3 wants the BoardItem —
            // resolve through the store (the only snapshot door).
            NSError *error = nil;
            BoardItem *item = [weakSelf.snapshotStore itemWithNodeID:datedItem.nodeID error:&error];
            if (item != nil) {
                [weakSelf presentDetailForItem:item];
            }
        };
    }
    if (self.roadmapWindow == nil) {
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1120, 660)
                                                       styleMask:(NSWindowStyleMaskTitled |
                                                                  NSWindowStyleMaskClosable |
                                                                  NSWindowStyleMaskMiniaturizable |
                                                                  NSWindowStyleMaskResizable)
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        [window setTitle:@"Snowfell — Roadmap"];
        [window setContentViewController:self.roadmapController];
        [window setMinSize:NSMakeSize(760, 440)];
        [window center];
        self.roadmapWindow = window;
    }
    [self.roadmapController reloadRoadmap];
    [self.roadmapWindow makeKeyAndOrderFront:sender];
    [NSApp activateIgnoringOtherApps:YES];
}

- (IBAction)showCommandPalette:(id)sender {
    if (self.paletteController == nil) {
        self.paletteController = [[CommandPaletteViewController alloc] initWithSnapshotStore:self.snapshotStore];
        __weak AppDelegate *weakSelf = self;
        self.paletteController.boardActivationHandler = ^(BoardSummary *board) {
            [weakSelf openBoardForBoard:board];
        };
        self.paletteController.itemActivationHandler = ^(BoardItem *item) {
            [weakSelf presentDetailForItem:item];
        };
        self.paletteController.actionActivationHandler = ^(NSString *actionID) {
            [weakSelf openOrchestrationCenterWithActionID:actionID];
        };
        self.paletteController.targetActivationHandler = ^(NSString *targetID) {
            // A target alone preselects nothing: targets are chosen
            // inside the composer's target_id dropdown. The palette
            // routes to the Orchestration Center (the deploy lane's
            // home); the routed-from target is the one the status line
            // named before the panel closed.
            [weakSelf showOrchestrationCenter:nil];
        };
        self.paletteController.draftActivationHandler = ^(DraftRow *draft) {
            // Draft → the Orchestration deploy lane, preselecting the
            // deploy action the draft's OWN target names: instagram →
            // media.deploy.instagram, linkedin → signal.publish.linkedin,
            // any other registered target → media.deploy. A draft with
            // no target (visibly incomplete in the Drafts lens) opens
            // the Center unpreselected — nothing is invented for it.
            NSString *actionID = nil;
            if ([draft.deployTargetID hasPrefix:@"instagram:"]) {
                actionID = @"media.deploy.instagram";
            } else if ([draft.deployTargetID hasPrefix:@"linkedin:"]) {
                actionID = @"signal.publish.linkedin";
            } else if (draft.deployTargetID != nil) {
                actionID = @"media.deploy";
            }
            [weakSelf openOrchestrationCenterWithActionID:actionID];
        };
    }
    if (self.palettePanel == nil) {
        NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 640, 420)
                                                    styleMask:(NSWindowStyleMaskTitled |
                                                               NSWindowStyleMaskClosable |
                                                               NSWindowStyleMaskUtilityWindow)
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        [panel setTitle:@"Snowfell — Command Palette"];
        [panel setContentViewController:self.paletteController];
        [panel setFloatingPanel:YES];
        [panel center];
        self.palettePanel = panel;
    }
    [self.paletteController resetPalette];
    [self.palettePanel makeKeyAndOrderFront:sender];
    [NSApp activateIgnoringOtherApps:YES];
}

#pragma mark - SF-T11 Incidents (V11)

- (IBAction)showIncidents:(id)sender {
    if (self.incidentsController == nil) {
        self.incidentsController = [[IncidentsViewController alloc]
                                    initWithSnapshotStore:self.snapshotStore
                                            dispatchStore:self.dispatchStore];
    }
    if (self.incidentsWindow == nil) {
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1120, 680)
                                                       styleMask:(NSWindowStyleMaskTitled |
                                                                  NSWindowStyleMaskClosable |
                                                                  NSWindowStyleMaskMiniaturizable |
                                                                  NSWindowStyleMaskResizable)
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        [window setTitle:@"Snowfell — Incidents"];
        [window setContentViewController:self.incidentsController];
        [window setMinSize:NSMakeSize(1100, 680)];
        [window center];
        self.incidentsWindow = window;
    }
    self.incidentsController.snapshotVersion = self.snapshotStore.snapshotVersion;
    [self.incidentsController reloadIncidents];
    [self.incidentsWindow makeKeyAndOrderFront:sender];
    [NSApp activateIgnoringOtherApps:YES];
}

#pragma mark - SF-T12f Storage (V12)

// Lazy: the client is built on first use of the lens, never at launch
// (a launch with no Storage interest pays nothing and touches neither
// the Keychain nor the network — the client's first act is a call the
// lens makes).
- (CloudServiceClient *)cloudServiceClient {
    if (_cloudServiceClient == nil) {
        _cloudServiceClient = [[CloudServiceClient alloc] init];
    }
    return _cloudServiceClient;
}

- (IBAction)showStorage:(id)sender {
    if (self.storageController == nil) {
        self.storageController = [[StorageViewController alloc]
                                  initWithCloudServiceClient:self.cloudServiceClient];
    }
    if (self.storageWindow == nil) {
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1120, 680)
                                                       styleMask:(NSWindowStyleMaskTitled |
                                                                  NSWindowStyleMaskClosable |
                                                                  NSWindowStyleMaskMiniaturizable |
                                                                  NSWindowStyleMaskResizable)
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        [window setTitle:@"Snowfell — Storage"];
        [window setContentViewController:self.storageController];
        [window setMinSize:NSMakeSize(1100, 680)];
        [window center];
        self.storageWindow = window;
    }
    [self.storageController reloadStorage];
    [self.storageWindow makeKeyAndOrderFront:sender];
    [NSApp activateIgnoringOtherApps:YES];
}

// The access-review preamble every confirm sheet carries (§3 envelope
// form): destination + operator, transport, and the fact that in this
// build nothing leaves the machine.
- (NSString *)writeBackConfirmPreamble {
    return [NSString stringWithFormat:
            @"Destination when sent: %@ (GitHub GraphQL API, operator GitHub) over HTTPS.\n"
            @"Nothing has been sent. Confirming records the mutation in the LOCAL write-back queue only "
            @"(%@); it leaves this Mac solely through the owner's explicit Send Pending action in an armed build.",
            [GitHubProjectsClient graphQLEndpoint],
            [WriteBackQueue defaultStorePath]];
}

- (void)confirmEnqueueOnWindow:(NSWindow *)window
                   messageText:(NSString *)messageText
              informativeText:(NSString *)informativeText
                    completion:(void (^)(BOOL confirmed))completion {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:messageText];
    [alert setInformativeText:informativeText];
    [alert addButtonWithTitle:@"Enqueue Locally"];
    [alert addButtonWithTitle:@"Cancel"];
    NSWindow *sheetWindow = (window != nil) ? window : self.mainWindow;
    [alert beginSheetModalForWindow:sheetWindow completionHandler:^(NSModalResponse result) {
        completion(result == NSAlertFirstButtonReturn);
    }];
}

// Shared enqueue tail: write the row, refresh the Queue panel, and report
// failure as fact → state (an alert), never silently.
- (BOOL)enqueueKind:(NSString *)kind
            boardID:(NSString *)boardID
             itemID:(NSString *)itemID
            payload:(NSDictionary *)payload
         sheetWindow:(NSWindow *)window {
    if (self.writeBackQueue == nil) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Write-back queue unavailable"];
        [alert setInformativeText:[NSString stringWithFormat:
                                   @"The local queue could not be opened: %@\nNothing was queued.",
                                   self.writeBackQueueError.localizedDescription]];
        [alert beginSheetModalForWindow:(window != nil) ? window : self.mainWindow completionHandler:nil];
        return NO;
    }
    NSError *error = nil;
    int64_t queueID = [self.writeBackQueue enqueueMutationWithKind:kind
                                                           boardID:boardID
                                                            itemID:itemID
                                                           payload:payload
                                                             error:&error];
    if (queueID < 0) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Mutation not queued"];
        [alert setInformativeText:[NSString stringWithFormat:
                                   @"%@\nNothing was queued and nothing was sent.",
                                   (error != nil) ? error.localizedDescription : @"unknown error"]];
        [alert beginSheetModalForWindow:(window != nil) ? window : self.mainWindow completionHandler:nil];
        return NO;
    }
    [self.queueController reloadQueue];
    return YES;
}

- (void)handleStatusMoveRequestForItem:(BoardItem *)item
                                 board:(BoardSummary *)board
                            optionName:(NSString *)optionName
                            completion:(void (^)(BOOL enqueued))completion {
    NSError *error = nil;
    StatusField *statusField = [self.snapshotStore statusFieldForBoard:board.nodeID error:&error];
    StatusOptionRef *option = [statusField optionWithName:optionName];
    if (statusField == nil || option == nil) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Status move not queued"];
        [alert setInformativeText:[NSString stringWithFormat:
                                   @"The snapshot carries no Status field/option IDs for this board (%@). Nothing was queued.",
                                   (error != nil) ? error.localizedDescription : @"option not found"]];
        [alert beginSheetModalForWindow:self.boardWindow completionHandler:nil];
        completion(NO);
        return;
    }
    NSString *effect = [NSString stringWithFormat:
                        @"Effect when eventually sent: updateProjectV2ItemFieldValue will set the Status of “%@” on board “%@” from “%@” to “%@”.",
                        item.title, board.title,
                        (item.statusName != nil) ? item.statusName : @"(no status)", optionName];
    [self confirmEnqueueOnWindow:self.boardWindow
                     messageText:@"Queue status move?"
                informativeText:[NSString stringWithFormat:@"%@\n\n%@", effect, [self writeBackConfirmPreamble]]
                      completion:^(BOOL confirmed) {
        if (!confirmed) {
            completion(NO);
            return;
        }
        NSDictionary *payload = @{
            @"field_id": statusField.ghFieldID,
            @"option_id": option.ghOptionID,
            @"option_name": optionName,
            @"from_option_name": (item.statusName != nil) ? item.statusName : [NSNull null],
            @"item_title": item.title,
        };
        BOOL enqueued = [self enqueueKind:WriteBackKindStatusMove
                                  boardID:board.nodeID
                                   itemID:item.nodeID
                                  payload:payload
                              sheetWindow:self.boardWindow];
        completion(enqueued);
    }];
}

- (void)handleCreateItemRequestForBoard:(BoardSummary *)board
                                  title:(NSString *)title
                             optionName:(NSString *)optionName {
    NSMutableDictionary *payload = [@{@"title": title} mutableCopy];
    NSString *statusClause = @"";
    if (optionName != nil) {
        NSError *error = nil;
        StatusField *statusField = [self.snapshotStore statusFieldForBoard:board.nodeID error:&error];
        StatusOptionRef *option = [statusField optionWithName:optionName];
        if (option != nil) {
            payload[@"field_id"] = statusField.ghFieldID;
            payload[@"option_id"] = option.ghOptionID;
            payload[@"option_name"] = optionName;
            statusClause = [NSString stringWithFormat:@" Its Status will be set to “%@” in the same send.", optionName];
        }
    }
    NSString *effect = [NSString stringWithFormat:
                        @"Effect when eventually sent: addProjectV2DraftIssue will create a draft issue titled “%@” on board “%@”.%@",
                        title, board.title, statusClause];
    [self confirmEnqueueOnWindow:self.boardWindow
                     messageText:@"Queue new item?"
                informativeText:[NSString stringWithFormat:@"%@\n\n%@", effect, [self writeBackConfirmPreamble]]
                      completion:^(BOOL confirmed) {
        if (!confirmed) {
            return;
        }
        [self enqueueKind:WriteBackKindCreateItem
                  boardID:board.nodeID
                   itemID:nil
                  payload:payload
              sheetWindow:self.boardWindow];
    }];
}

- (void)handleCommentRequestForItem:(BoardItem *)item
                               body:(NSString *)body
                         completion:(void (^)(BOOL enqueued))completion {
    NSMutableString *effect = [NSMutableString stringWithFormat:
                               @"Effect when eventually sent: addComment will post this comment to %@ (“%@”):\n\n%@",
                               item.kindDisplay, item.title, body];
    if ([item.contentKind isEqualToString:@"DraftIssue"]) {
        [effect appendString:@"\n\nNote: GitHub offers NO comment mutation for draft issues — when a send is attempted this row will fail with that reason, on the record. (A draft's body is edited instead; that operation is outside write-back v1.)"];
    }
    [self confirmEnqueueOnWindow:self.detailWindow
                     messageText:@"Queue comment?"
                informativeText:[NSString stringWithFormat:@"%@\n\n%@", effect, [self writeBackConfirmPreamble]]
                      completion:^(BOOL confirmed) {
        if (!confirmed) {
            completion(NO);
            return;
        }
        NSDictionary *payload = @{
            @"body": body,
            @"item_title": item.title,
            @"content_kind": item.contentKind,
            @"content_repo": (item.contentRepo != nil) ? item.contentRepo : [NSNull null],
            @"content_number": (item.contentNumber != nil) ? item.contentNumber : [NSNull null],
        };
        BOOL enqueued = [self enqueueKind:WriteBackKindComment
                                  boardID:item.boardID
                                   itemID:item.nodeID
                                  payload:payload
                              sheetWindow:self.detailWindow];
        completion(enqueued);
    }];
}

// The ONLY send entry point in the app: the owner's explicit action
// (File menu / Queue panel). Both locks are re-checked here even though
// the menu item and the button already gate on them.
- (IBAction)sendPendingMutations:(id)sender {
    if (![GitHubProjectsClient writeBackCompiledEnabled]) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Write-back is compiled OFF in this build"];
        [alert setInformativeText:@"SNOWFELL_WRITEBACK_ENABLED = 0: no mutation can be sent from this build, whatever the Keychain holds. The queue is unchanged and stays pending for an armed rig build (see the app README's enable path)."];
        [alert beginSheetModalForWindow:(self.queueWindow != nil && [self.queueWindow isVisible]) ? self.queueWindow : self.mainWindow
                      completionHandler:nil];
        [self.queueController reloadQueue];
        return;
    }
    if ([self.githubClient tokenStatus] != GitHubTokenStatusAvailable) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"No GitHub token configured"];
        [alert setInformativeText:@"D4 custody: the token lives only in the macOS Keychain (service com.detroitautomationacademy.snowfell.github). Without it the client reports notConfigured and the queue stays pending. Nothing was sent."];
        [alert beginSheetModalForWindow:self.mainWindow completionHandler:nil];
        return;
    }
    NSError *error = nil;
    NSArray<WriteBackMutation *> *pending = [self.writeBackQueue pendingMutationsWithError:&error];
    if (pending == nil) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Queue unreadable"];
        [alert setInformativeText:(error != nil) ? error.localizedDescription : @"unknown error"];
        [alert beginSheetModalForWindow:self.mainWindow completionHandler:nil];
        return;
    }
    [self processPendingMutations:pending index:0];
}

// FIFO, one attempt per row per send action. Every outcome is recorded
// in the queue (state + last_error) and in local_audit_log.
- (void)processPendingMutations:(NSArray<WriteBackMutation *> *)pending index:(NSUInteger)index {
    if (index >= [pending count]) {
        [self.queueController reloadQueue];
        return;
    }
    WriteBackMutation *mutation = pending[index];
    NSString *objectRef = [NSString stringWithFormat:@"writeback_queue:%lld", mutation.queueID];
    [self.writeBackQueue markSending:mutation.queueID error:NULL];
    [self.writeBackQueue recordAuditAction:@"writeback.send.attempt"
                                objectRef:objectRef
                                   before:@{@"state": mutation.state}
                                    after:@{@"state": WriteBackStateSending,
                                            @"attempt": @(mutation.attempts + 1)}
                                    error:NULL];
    [self.queueController reloadQueue];
    [self.githubClient sendMutation:mutation completion:^(BOOL success, NSString *resultRef, NSError *error) {
        if (success) {
            [self.writeBackQueue markSent:mutation.queueID error:NULL];
            [self.writeBackQueue recordAuditAction:@"writeback.send.succeeded"
                                        objectRef:objectRef
                                           before:@{@"state": WriteBackStateSending}
                                            after:@{@"state": WriteBackStateSent,
                                                    @"result_ref": (resultRef != nil) ? resultRef : [NSNull null]}
                                            error:NULL];
        } else {
            NSString *message = (error != nil) ? error.localizedDescription : @"unknown error";
            [self.writeBackQueue markFailed:mutation.queueID message:message error:NULL];
            [self.writeBackQueue recordAuditAction:@"writeback.send.failed"
                                        objectRef:objectRef
                                           before:@{@"state": WriteBackStateSending}
                                            after:@{@"state": WriteBackStateFailed,
                                                    @"error": message}
                                            error:NULL];
        }
        [self processPendingMutations:pending index:index + 1];
    }];
}

#pragma mark - BoardViewControllerDelegate

- (void)boardViewController:(BoardViewController *)controller
            didSelectItem:(BoardItem *)item {
    [self presentDetailForItem:item];
}

#pragma mark - Window menu actions

- (IBAction)minimizeWindow:(id)sender {
    [[NSApp keyWindow] performMiniaturize:sender];
}

- (IBAction)zoomWindow:(id)sender {
    [[NSApp keyWindow] performZoom:sender];
}

- (IBAction)bringAllToFront:(id)sender {
    [NSApp arrangeInFront:sender];
}

#pragma mark - Help menu actions

- (IBAction)showSnapshotDetails:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Snapshot Details"];
    if (self.snapshotStore.snapshotPath != nil) {
        NSDictionary *manifest = self.snapshotStore.manifest;
        [alert setInformativeText:[NSString stringWithFormat:
                                   @"Version: %@\nSchema: %@ · Ledger head: %@\nSHA-256: %@\nSize: %@ bytes\nRegistry commit: %@\nPath: %@",
                                   manifest[@"version"], manifest[@"schema_version"],
                                   manifest[@"ledger_head"], manifest[@"sha256"],
                                   manifest[@"size_bytes"], manifest[@"registry_commit"],
                                   self.snapshotStore.snapshotPath]];
    } else {
        [alert setInformativeText:[NSString stringWithFormat:
                                   @"No verified snapshot is loaded.\n%@",
                                   self.snapshotStore.loadError.localizedDescription]];
    }
    [alert beginSheetModalForWindow:self.mainWindow completionHandler:nil];
}

- (IBAction)showHelp:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Snowfell Help"];
    [alert setInformativeText:
     @"Snowfell is the Academy's board over GitHub Projects, read from a "
     @"pinned, hash-verified registry snapshot.\n\n"
     @"Double-click a Portfolio row to open its board; click a card to "
     @"open the item. Status columns are each board's own vocabulary — "
     @"Snowfell stores status as data, never as a fixed enum.\n\n"
     @"Write-back (SF-T4): a card's Status popup, the Board's New Item "
     @"button, and Item Detail's comment field QUEUE mutations locally "
     @"(View ▸ Write-back Queue, ⌘4) after a confirm sheet naming the "
     @"exact GitHub effect. Sending is compiled OFF in this build and "
     @"additionally requires a Keychain token and the owner's explicit "
     @"Send Pending action — nothing leaves this Mac from the queue "
     @"here.\n\n"
     @"Orchestration (SF-T5): View ▸ Orchestration Center (⌘5) composes "
     @"any manifest action (sf_actions — actions are data) into a local "
     @"queue after an access-review confirm sheet. Estate-lane rows wait "
     @"in local_dispatches for Minion/hooks to execute (SF-T6); the one "
     @"GitHub-lane mapping this build carries (gh.project.move_item) "
     @"lands in the SF-T4 write-back queue instead. This app executes "
     @"nothing from either queue.\n\n"
     @"Snapshot sync (SF-T6): File ▸ Check for Snapshot Update… fetches "
     @"the Academy's published snapshot manifest; a newer snapshot is "
     @"downloaded and hash-verified into staging, and swaps in only "
     @"when you press Apply Update in Preferences. Nothing downloads "
     @"or swaps on its own.\n\n"
     @"Roadmap + Palette (SF-T7): View ▸ Roadmap (⌘6) draws the dated "
     @"items (Start/Target dates, per board) as a month timeline — only "
     @"dates the snapshot actually holds. View ▸ Command Palette… "
     @"(⌘K) searches boards, items, actions, deploy targets, and "
     @"upcoming drafts; Enter opens the hit in its view. Preferences "
     @"(V7) states the GitHub token's Keychain presence, the compiled "
     @"write-back arm state, and both local queue counts.\n\n"
     @"Storage (SF-T12): View ▸ Storage (⌘8) is the operator console "
     @"for the bundled SnowfellStorageService — tenants, logins, "
     @"buckets, and the audit trail, all over the service's REST API "
     @"on 127.0.0.1 only (the port is a Preferences setting; the host "
     @"never is). The lens starts/stops the bundled helper and pairs "
     @"the operator token into the Keychain on first use; without a "
     @"token it shows the pairing pane instead of data."];
    [alert beginSheetModalForWindow:self.mainWindow completionHandler:nil];
}

@end
