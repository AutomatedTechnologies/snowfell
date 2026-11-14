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
#import "UpdatesViewController.h"
#import "NavigationBar.h"
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
// snowfell-test-6: SINGLE-WINDOW model (owner verdict 2026-11-14: the
// test-4 bar "haphazard and inconsistent — some buttons open new
// windows, others open in same"). There is exactly ONE lens window —
// mainWindow — and all eight lenses live in it as content view
// controllers, switched in place by displaySection:. The satellite
// window properties (boardWindow / queueWindow / orchestrationWindow /
// roadmapWindow / incidentsWindow / storageWindow / updatesWindow) are
// GONE: their releasedWhenClosed lifetime web is the test-5 crash
// fault path — BOTH crashes (Staged, files/11; Item Detail via the
// Roadmap, Addendum 2) are the retain of a satellite window property's
// freed value, proven by symbolication of the shipped binary
// (files/12). Item Detail is an IN-PLACE drill-down in the main
// window (presentDetailForItem:), not a window at all. What remains a
// window is auxiliary by design and carries no segment bar: the
// Command Palette panel and Preferences — each created with
// releasedWhenClosed = NO so a close can never leave a dangling
// property behind.
@property (nonatomic, strong) NSWindow *mainWindow;
@property (nonatomic, strong) NSPanel *palettePanel;
@property (nonatomic, strong) NSWindow *preferencesWindow;
@property (nonatomic, assign) SFNavigationSection currentSection;
@property (nonatomic, strong) SnapshotStore *snapshotStore;
@property (nonatomic, strong) PortfolioViewController *portfolioController;
@property (nonatomic, strong) BoardViewController *boardController;
@property (nonatomic, strong) ItemDetailViewController *detailController;
@property (nonatomic, strong) WriteBackQueueViewController *queueController;
@property (nonatomic, strong) OrchestrationViewController *orchestrationController;
@property (nonatomic, strong) RoadmapViewController *roadmapController;
@property (nonatomic, strong) CommandPaletteViewController *paletteController;
@property (nonatomic, strong) IncidentsViewController *incidentsController;
@property (nonatomic, strong) StorageViewController *storageController;
// snowfell-test-4: the Updates lens (⌘9) — reads the same sync session
// state the Preferences block shows, refreshed by the same push.
@property (nonatomic, strong) UpdatesViewController *updatesController;
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

    // snowfell-test-6 sizing rule (the ONE rule, of record in files/12):
    // the single window's frame NEVER changes on a lens switch, and its
    // minimum size is the largest lens's own requirement — the
    // Orchestration Center's 1180 x 720 — so every lens fits the same
    // frame and no switch ever resizes, re-centers, or re-orders a
    // window. Initial frame = that minimum.
    NSRect frame = NSMakeRect(0, 0, 1180, 720);
    self.mainWindow = [[NSWindow alloc] initWithContentRect:frame
                                                  styleMask:(NSWindowStyleMaskTitled |
                                                             NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskMiniaturizable |
                                                             NSWindowStyleMaskResizable)
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    [self.mainWindow setReleasedWhenClosed:NO];
    [self.mainWindow setTitle:@"Snowfell — Portfolio"];
    // snowfell-test-2 uplift: the baseline window field (--win #f6f6f6)
    // behind every lens hosted in the main window.
    [self.mainWindow setBackgroundColor:[AcademyTheme windowColor]];
    [self.mainWindow setContentViewController:self.portfolioController];
    [self attachNavigationBarToWindow:self.mainWindow section:SFNavigationSectionPortfolio];
    [self.mainWindow setMinSize:NSMakeSize(1180, 720)];
    self.currentSection = SFNavigationSectionPortfolio;
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
    NSMenuItem *sendItem = [self itemWithTitle:@"Send Pending Changes…"
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
    NSMenuItem *queueItem = [self itemWithTitle:@"Staged Changes"
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
    // snowfell-test-4: the Updates lens (⌘9) — snapshot sync's own surface.
    NSMenuItem *updatesItem = [self itemWithTitle:@"Updates"
                                           action:@selector(showUpdates:)
                                    keyEquivalent:@"9"
                                           target:self];
    [updatesItem setTag:211];
    [viewMenu addItem:updatesItem];
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
    [fullScreenItem setTag:210];
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
        // Title follows state at menu-open time (the AppKit tab-bar
        // pattern): the label must agree with what the click will do.
        [menuItem setTitle:self.portfolioController.showClosedBoards ? @"Hide Closed Boards" : @"Show Closed Boards"];
        return YES;
    }
    if ([menuItem tag] == 102) {
        [menuItem setTitle:self.portfolioController.showArchivedBoards ? @"Hide Archived Boards" : @"Show Archived Boards"];
        return YES;
    }
    if ([menuItem tag] == 210) {
        // The Full Screen label follows the state of the very window
        // the action toggles ([NSApp keyWindow], as in toggleFullScreen:).
        NSWindow *target = [NSApp keyWindow];
        if (target == nil) {
            target = self.mainWindow;
        }
        BOOL fullScreen = (target != nil) && ((target.styleMask & NSWindowStyleMaskFullScreen) != 0);
        [menuItem setTitle:fullScreen ? @"Exit Full Screen" : @"Enter Full Screen"];
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
    if ([menuItem tag] == 211) {
        return YES;  // the Updates lens always opens; it states the sync session's state
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
        // snowfell-test-6: Preferences is re-shown from this property
        // for the app's whole life — its lifetime must not be tied to
        // its closed state (the test-5 Staged crash's defect class).
        [window setReleasedWhenClosed:NO];
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
                                @"GitHub token: %@ — kept in your macOS Keychain (service %@). Snowfell checks only that it is there; the secret is never read or shown.",
                                tokenPresent ? @"stored" : @"not stored",
                                GitHubProjectsKeychainService]];
    // Flag line: the compiled lock, stated as it is in THIS build.
    NSTextField *writeBackField = (NSTextField *)[[self.preferencesWindow contentView] viewWithTag:407];
    if ([GitHubProjectsClient writeBackCompiledEnabled]) {
        [writeBackField setStringValue:@"Sending: ON in this build — staged changes leave this Mac only with your Keychain token and your explicit Send Pending Changes action."];
    } else {
        [writeBackField setStringValue:@"Sending: OFF in this build — changes can be staged on this Mac but not sent from here."];
    }
    // Queue line: both local stores' waiting counts (or their failure).
    NSTextField *queueField = (NSTextField *)[[self.preferencesWindow contentView] viewWithTag:408];
    NSString *writeBackCount = (self.writeBackQueue != nil)
        ? [NSString stringWithFormat:@"%ld staged change(s) waiting", (long)[self.writeBackQueue pendingCount]]
        : [NSString stringWithFormat:@"write-back queue unavailable (%@)",
           self.writeBackQueueError.localizedDescription];
    NSString *dispatchCount = (self.dispatchStore != nil)
        ? [NSString stringWithFormat:@"%ld action(s) queued", (long)[self.dispatchStore queuedCount]]
        : [NSString stringWithFormat:@"dispatch store unavailable (%@)",
           self.dispatchStoreError.localizedDescription];
    [queueField setStringValue:[NSString stringWithFormat:@"On this Mac: %@ · %@", writeBackCount, dispatchCount]];
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
// Snapshot... since SF-T2; SF-T6 Apply Update since this tranche).
// snowfell-test-6 single-window form: the Portfolio rebuilds against
// the new store; every other snapshot-reading lens controller is
// DROPPED and rebuilds lazily against the new store the next time its
// section is displayed; the section on screen is re-displayed fresh in
// place — no window closes, because there are no satellite windows to
// close. The surfaces that read the old store and are not lenses
// (the Item Detail drill-down, the palette) are dropped/closed and
// rebuild on demand. (The local stores —
// write-back queue + dispatches — are snapshot-independent and are
// never touched by a swap, so the Staged and Storage controllers,
// which read only those, survive a swap intact.)
- (void)adoptLoadedSnapshotStore:(SnapshotStore *)store {
    self.snapshotStore = store;
    self.portfolioController = [[PortfolioViewController alloc] initWithSnapshotStore:store];
    [self wirePortfolioController];
    self.detailController = nil;
    [self.palettePanel close];
    self.palettePanel = nil;
    self.paletteController = nil;
    self.boardController = nil;
    self.orchestrationController = nil;
    self.roadmapController = nil;
    self.incidentsController = nil;
    self.updatesController = nil;
    [self displaySection:self.currentSection];
}

- (IBAction)refreshPortfolio:(id)sender {
    [self.portfolioController reloadPortfolio];
}

#pragma mark - SF-T6 snapshot sync (owner-pressed; no background fetch or swap)

// Pushes the session's sync state into the Preferences block when the
// window exists. Called on Preferences open and after every sync step.
- (void)refreshSnapshotSyncBlock {
    // snowfell-test-4: the Updates lens refreshes from the SAME session
    // state, on every sync step — not only when Preferences is open.
    if (self.updatesController != nil) {
        self.updatesController.servedVersion = self.servedManifest[@"version"];
        self.updatesController.statusText = self.syncStatusText;
        self.updatesController.stagedUpdateAvailable =
            (self.stagedDatabasePath != nil && self.stagedManifestPath != nil);
        [self.updatesController refreshUpdates];
    }
    // snowfell-test-5 freshness surfacing (freshness remainder, board
    // #78): the SAME session state drives two glanceable surfaces —
    // a dot on the bar's Updates segment (every window) and a line in
    // the Portfolio header naming the gap. Both clear the moment the
    // state does (up to date, or the staged update applied).
    {
        BOOL staged = (self.stagedDatabasePath != nil && self.stagedManifestPath != nil);
        NSString *servedVersion = self.servedManifest[@"version"];
        NSString *runningVersion = self.snapshotStore.snapshotVersion;
        BOOL gap = staged || (servedVersion != nil && runningVersion != nil &&
                              ![servedVersion isEqualToString:runningVersion]);
        for (NSWindow *window in [NSApp windows]) {
            [NavigationBar setUpdatesBadgeVisible:gap inWindow:window];
        }
        if (self.portfolioController != nil) {
            if (staged) {
                self.portfolioController.freshnessText = [NSString stringWithFormat:
                    @"Update %@ staged — Apply Update in the Updates lens",
                    servedVersion ?: runningVersion ?: @""];
            } else if (gap) {
                self.portfolioController.freshnessText = [NSString stringWithFormat:
                    @"Served %@ — an update is published", servedVersion];
            } else {
                self.portfolioController.freshnessText = nil;
            }
        }
    }
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
    [self displaySection:SFNavigationSectionPortfolio];
}

- (IBAction)showBoard:(id)sender {
    BoardSummary *board = [self.portfolioController selectedBoard];
    if (board != nil) {
        [self openBoardForBoard:board];
    } else {
        // No Portfolio selection: the Board opens on its own default
        // (user board #3) rather than doing nothing.
        [self displaySection:SFNavigationSectionBoard];
    }
}

- (IBAction)showItemDetail:(id)sender {
    BoardItem *item = self.boardController.selectedItem;
    if (item != nil) {
        [self presentDetailForItem:item];
    }
}

- (void)ensureBoardController {
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
}

- (void)openBoardForBoard:(BoardSummary *)board {
    [self displaySection:SFNavigationSectionBoard];
    [self.boardController showBoard:board];
}

// snowfell-test-6: Item Detail is the Board's drill-down IN PLACE —
// the main window's content swaps to the detail controller, the title
// names the drill-down, and the bar's selected segment stays Board
// (the lens the detail belongs to; pressing Board, or any segment,
// leaves the drill-down through displaySection:). There is no detail
// window: the pre-test-6 detailWindow was the SECOND crash's fault
// path (files/11 Addendum 2 — presentDetailForItem: + 569 is the
// retain of the detailWindow getter's freed value after the window
// had been closed; files/12). Callers (Board delegate, the Roadmap
// timeline, the palette, ⌘3) all land here, unchanged.
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
    [self.detailController showItem:item];
    if ([self.mainWindow contentViewController] != self.detailController) {
        [self.mainWindow setContentViewController:self.detailController];
    }
    [self.mainWindow setTitle:@"Snowfell — Item Detail"];
    [NavigationBar selectSection:SFNavigationSectionBoard inWindow:self.mainWindow];
    [self.mainWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

#pragma mark - SF-T4 write-back (queue-only in this build)

- (IBAction)showWriteBackQueue:(id)sender {
    [self displaySection:SFNavigationSectionStaged];
}

#pragma mark - SF-T5 orchestration (queue-only in this app, both lanes)

- (IBAction)showOrchestrationCenter:(id)sender {
    [self displaySection:SFNavigationSectionOrchestration];
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
    [self displaySection:SFNavigationSectionRoadmap];
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
        // snowfell-test-6: auxiliary surface, re-shown from this
        // property — lifetime never tied to its closed state.
        [panel setReleasedWhenClosed:NO];
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
    [self displaySection:SFNavigationSectionIncidents];
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
    [self displaySection:SFNavigationSectionStorage];
}

#pragma mark - snowfell-test-6 single-window navigation (bar: test-4; model: test-6)

// The bar is attached ONCE, to the main window, at launch: NavigationBar
// builds the shared toolbar; the Portfolio segment starts selected.
- (void)attachNavigationBarToWindow:(NSWindow *)window section:(SFNavigationSection)section {
    [NavigationBar attachToWindow:window
                          section:section
                           target:self
                           action:@selector(navigationSegmentChanged:)];
}

// THE navigation entry point (snowfell-test-6). Every route to a lens —
// a segment press, a View-menu item / ⌘ key, the palette, a Portfolio
// double-click — lands here, and here is all that happens: the lens's
// controller is built lazily on first display, refreshed exactly as
// its pre-test-6 show action refreshed it, and swapped into the ONE
// main window as its content view controller; the window's title and
// the bar's selected segment follow the visible lens. No window is
// created, ordered front, or closed by a lens switch, ever — the
// multi-window lifetime web that produced both the owner's "haphazard
// and inconsistent" verdict and the test-5 Staged crash (files/11,
// files/12) does not exist in this model.
- (void)displaySection:(SFNavigationSection)section {
    NSViewController *controller = nil;
    NSString *title = nil;
    switch (section) {
        case SFNavigationSectionPortfolio:
            controller = self.portfolioController;
            title = @"Snowfell — Portfolio";
            break;
        case SFNavigationSectionBoard:
            [self ensureBoardController];
            controller = self.boardController;
            title = @"Snowfell — Board";
            break;
        case SFNavigationSectionStaged:
            if (self.queueController == nil) {
                self.queueController = [[WriteBackQueueViewController alloc] initWithQueue:self.writeBackQueue
                                                                                    client:self.githubClient];
                __weak AppDelegate *weakSelf = self;
                self.queueController.sendRequestedHandler = ^{
                    [weakSelf sendPendingMutations:nil];
                };
            }
            controller = self.queueController;
            title = @"Snowfell — Staged Changes";
            break;
        case SFNavigationSectionOrchestration:
            if (self.orchestrationController == nil) {
                self.orchestrationController = [[OrchestrationViewController alloc] initWithSnapshotStore:self.snapshotStore
                                                                                            dispatchStore:self.dispatchStore
                                                                                           writeBackQueue:self.writeBackQueue];
            }
            controller = self.orchestrationController;
            title = @"Snowfell — Orchestration Center";
            break;
        case SFNavigationSectionRoadmap:
            if (self.roadmapController == nil) {
                self.roadmapController = [[RoadmapViewController alloc] initWithSnapshotStore:self.snapshotStore];
                __weak AppDelegate *weakSelf = self;
                self.roadmapController.itemActivationHandler = ^(DatedItem *datedItem) {
                    // The timeline row is a DatedItem; V3 wants the
                    // BoardItem — resolve through the store (the only
                    // snapshot door).
                    NSError *error = nil;
                    BoardItem *item = [weakSelf.snapshotStore itemWithNodeID:datedItem.nodeID error:&error];
                    if (item != nil) {
                        [weakSelf presentDetailForItem:item];
                    }
                };
            }
            controller = self.roadmapController;
            title = @"Snowfell — Roadmap";
            break;
        case SFNavigationSectionIncidents:
            if (self.incidentsController == nil) {
                self.incidentsController = [[IncidentsViewController alloc]
                                            initWithSnapshotStore:self.snapshotStore
                                                    dispatchStore:self.dispatchStore];
            }
            controller = self.incidentsController;
            title = @"Snowfell — Incidents";
            break;
        case SFNavigationSectionStorage:
            if (self.storageController == nil) {
                self.storageController = [[StorageViewController alloc]
                                          initWithCloudServiceClient:self.cloudServiceClient];
            }
            controller = self.storageController;
            title = @"Snowfell — Storage";
            break;
        case SFNavigationSectionUpdates:
            if (self.updatesController == nil) {
                self.updatesController = [[UpdatesViewController alloc] initWithSnapshotStore:self.snapshotStore];
                __weak AppDelegate *weakSelf = self;
                self.updatesController.checkRequestedHandler = ^{
                    [weakSelf checkForSnapshotUpdate:nil];
                };
                self.updatesController.applyRequestedHandler = ^{
                    [weakSelf applyStagedSnapshot:nil];
                };
            }
            controller = self.updatesController;
            title = @"Snowfell — Updates";
            break;
    }
    if (controller == nil) {
        return;
    }
    if ([self.mainWindow contentViewController] != controller) {
        [self.mainWindow setContentViewController:controller];
    }
    // Refresh AFTER the swap, with the lens's view loaded and installed
    // — the same refresh each pre-test-6 show action ran on every show.
    switch (section) {
        case SFNavigationSectionStaged:
            [self.queueController reloadQueue];
            break;
        case SFNavigationSectionOrchestration:
            [self.orchestrationController reloadOrchestration];
            break;
        case SFNavigationSectionRoadmap:
            [self.roadmapController reloadRoadmap];
            break;
        case SFNavigationSectionIncidents:
            self.incidentsController.snapshotVersion = self.snapshotStore.snapshotVersion;
            [self.incidentsController reloadIncidents];
            break;
        case SFNavigationSectionStorage:
            [self.storageController reloadStorage];
            break;
        case SFNavigationSectionUpdates:
            [self refreshSnapshotSyncBlock];
            break;
        default:
            break;
    }
    [self.mainWindow setTitle:title];
    self.currentSection = section;
    [NavigationBar selectSection:section inWindow:self.mainWindow];
    [self.mainWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

// A segment press names a section and nothing else — the bar adds no
// navigation logic of its own, and (test-6) neither does the routing:
// every segment lands in displaySection: on the one window.
- (IBAction)navigationSegmentChanged:(id)sender {
    NSSegmentedControl *control = (NSSegmentedControl *)sender;
    [self displaySection:(SFNavigationSection)[control selectedSegment]];
}

- (IBAction)showUpdates:(id)sender {
    [self displaySection:SFNavigationSectionUpdates];
}

// The primary line every staging confirm carries, in the owner's
// terms (owner verdict 2026-11-12): the action, the staging, and the
// push model. Mechanism lives behind the sheet's Details button.
- (NSString *)writeBackConfirmPreamble {
    return @"The change is staged in Snowfell's queue on this Mac — nothing has been sent. "
           @"It leaves this Mac only when you choose Send Pending Changes.";
}

// The full record, behind the confirm sheet's Details button: exact
// effect (mutation name included), destination, transport, staging
// store, and the send locks — auditability without primary-surface
// clutter.
- (NSString *)writeBackConfirmDetailsForEffect:(NSString *)effect {
    return [NSString stringWithFormat:
            @"Effect when sent: %@\n\n"
            @"Destination: %@ (GitHub GraphQL API; operator: GitHub), over HTTPS.\n"
            @"Staging store: the local write-back queue at %@ — the change waits there, on this Mac only, until sent.\n"
            @"Sending requires an armed build (SNOWFELL_WRITEBACK_ENABLED = 1), a GitHub token in the macOS Keychain, and your explicit Send Pending Changes action. Sending is compiled OFF in this build, so a staged change will wait in the queue.",
            effect, [GitHubProjectsClient graphQLEndpoint], [WriteBackQueue defaultStorePath]];
}

- (void)confirmEnqueueOnWindow:(NSWindow *)window
                   messageText:(NSString *)messageText
              informativeText:(NSString *)informativeText
                  detailsText:(NSString *)detailsText
              stageButtonTitle:(NSString *)stageButtonTitle
                    completion:(void (^)(BOOL confirmed))completion {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:messageText];
    [alert setInformativeText:informativeText];
    [alert addButtonWithTitle:stageButtonTitle];
    [alert addButtonWithTitle:@"Cancel"];
    if (detailsText != nil) {
        [alert addButtonWithTitle:@"Details…"];
    }
    NSWindow *sheetWindow = (window != nil) ? window : self.mainWindow;
    [alert beginSheetModalForWindow:sheetWindow completionHandler:^(NSModalResponse result) {
        if (result == NSAlertFirstButtonReturn) {
            completion(YES);
            return;
        }
        if (result == NSAlertThirdButtonReturn && detailsText != nil) {
            // Progressive disclosure: the full technical record, then
            // Back returns to this same confirm — nothing is staged
            // by looking.
            NSAlert *details = [[NSAlert alloc] init];
            [details setMessageText:@"Details"];
            [details setInformativeText:detailsText];
            [details addButtonWithTitle:@"Back"];
            [details addButtonWithTitle:@"Cancel"];
            [details beginSheetModalForWindow:sheetWindow completionHandler:^(NSModalResponse back) {
                if (back == NSAlertFirstButtonReturn) {
                    [self confirmEnqueueOnWindow:window
                                     messageText:messageText
                                informativeText:informativeText
                                    detailsText:detailsText
                               stageButtonTitle:stageButtonTitle
                                      completion:completion];
                } else {
                    completion(NO);
                }
            }];
            return;
        }
        completion(NO);
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
        [alert setMessageText:@"Staged-changes queue unavailable"];
        [alert setInformativeText:[NSString stringWithFormat:
                                   @"The local queue could not be opened: %@\nNothing was staged.",
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
        [alert setMessageText:@"Change not staged"];
        [alert setInformativeText:[NSString stringWithFormat:
                                   @"%@\nNothing was staged and nothing was sent.",
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
        [alert setMessageText:@"Status change not staged"];
        [alert setInformativeText:[NSString stringWithFormat:
                                   @"The snapshot has no status choices recorded for this board (%@). Nothing was staged.",
                                   (error != nil) ? error.localizedDescription : @"option not found"]];
        [alert beginSheetModalForWindow:self.mainWindow completionHandler:nil];
        completion(NO);
        return;
    }
    NSString *effect = [NSString stringWithFormat:
                        @"updateProjectV2ItemFieldValue will set the Status of “%@” on board “%@” from “%@” to “%@”.",
                        item.title, board.title,
                        (item.statusName != nil) ? item.statusName : @"(no status)", optionName];
    [self confirmEnqueueOnWindow:self.mainWindow
                     messageText:[NSString stringWithFormat:@"Move “%@” to %@ on %@?", item.title, optionName, board.title]
                informativeText:[NSString stringWithFormat:@"Status changes from “%@” to “%@”.\n\n%@",
                                 (item.statusName != nil) ? item.statusName : @"(no status)", optionName,
                                 [self writeBackConfirmPreamble]]
                    detailsText:[self writeBackConfirmDetailsForEffect:effect]
               stageButtonTitle:@"Stage Move"
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
                              sheetWindow:self.mainWindow];
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
                        @"addProjectV2DraftIssue will create a draft issue titled “%@” on board “%@”.%@",
                        title, board.title, statusClause];
    NSString *plainClause = (optionName != nil)
        ? [NSString stringWithFormat:@"A new draft item with Status “%@”.", optionName]
        : @"A new draft item.";
    [self confirmEnqueueOnWindow:self.mainWindow
                     messageText:[NSString stringWithFormat:@"Add “%@” to %@?", title, board.title]
                informativeText:[NSString stringWithFormat:@"%@\n\n%@", plainClause, [self writeBackConfirmPreamble]]
                    detailsText:[self writeBackConfirmDetailsForEffect:effect]
               stageButtonTitle:@"Stage Item"
                      completion:^(BOOL confirmed) {
        if (!confirmed) {
            return;
        }
        [self enqueueKind:WriteBackKindCreateItem
                  boardID:board.nodeID
                   itemID:nil
                  payload:payload
              sheetWindow:self.mainWindow];
    }];
}

- (void)handleCommentRequestForItem:(BoardItem *)item
                               body:(NSString *)body
                         completion:(void (^)(BOOL enqueued))completion {
    NSMutableString *effect = [NSMutableString stringWithFormat:
                               @"addComment will post this comment to %@ (“%@”):\n\n%@",
                               item.kindDisplay, item.title, body];
    if ([item.contentKind isEqualToString:@"DraftIssue"]) {
        [effect appendString:@"\n\nNote: GitHub offers NO comment mutation for draft issues — when a send is attempted this row will fail with that reason, on the record. (A draft's body is edited instead; that operation is outside write-back v1.)"];
    }
    [self confirmEnqueueOnWindow:self.mainWindow
                     messageText:[NSString stringWithFormat:@"Comment on “%@”?", item.title]
                informativeText:[NSString stringWithFormat:@"%@\n\n%@", body, [self writeBackConfirmPreamble]]
                    detailsText:[self writeBackConfirmDetailsForEffect:effect]
               stageButtonTitle:@"Stage Comment"
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
                              sheetWindow:self.mainWindow];
        completion(enqueued);
    }];
}

// The ONLY send entry point in the app: the owner's explicit action
// (File menu / Queue panel). Both locks are re-checked here even though
// the menu item and the button already gate on them.
- (IBAction)sendPendingMutations:(id)sender {
    if (![GitHubProjectsClient writeBackCompiledEnabled]) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Sending is off in this build"];
        [alert setInformativeText:@"This build can stage changes but cannot send them, whatever the Keychain holds. Staged changes stay in the queue on this Mac, unchanged, until an armed build sends them."];
        [alert beginSheetModalForWindow:self.mainWindow
                      completionHandler:nil];
        [self.queueController reloadQueue];
        return;
    }
    if ([self.githubClient tokenStatus] != GitHubTokenStatusAvailable) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"No GitHub token for sending"];
        [alert setInformativeText:@"Sending uses a GitHub token kept in your macOS Keychain. None is stored, so nothing was sent and the staged changes stay in the queue."];
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
     @"open the item. Each board uses its own status names.\n\n"
     @"Staging changes: a card's Status popup, the Board's New Item "
     @"button, and Item Detail's comment field stage changes in a "
     @"queue on this Mac (View ▸ Staged Changes, ⌘4) after a "
     @"confirmation that names the change in plain terms — the "
     @"sheet's Details button shows the exact GitHub operation for "
     @"the record. Sending is off in this build; in an armed build "
     @"it additionally requires your Keychain GitHub token and your "
     @"explicit Send Pending Changes action. Nothing leaves this "
     @"Mac from the queue here.\n\n"
     @"Orchestration: View ▸ Orchestration Center (⌘5) stages any "
     @"action from the snapshot's action list into a queue on this "
     @"Mac after a confirmation. Queued actions wait for Minion to "
     @"carry them out after approval; a GitHub status move staged "
     @"there lands in the same staged-changes queue as the Board's. "
     @"This app executes nothing from either queue itself.\n\n"
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
     @"(V7) states the GitHub token's Keychain presence, whether "
     @"sending is on in this build, and both local queue counts.\n\n"
     @"Storage (SF-T12): View ▸ Storage (⌘8) is the operator console "
     @"for the bundled SnowfellStorageService — tenants, logins, "
     @"buckets, and the audit trail, all over the service's REST API "
     @"on 127.0.0.1 only (the port is a Preferences setting; the host "
     @"never is). The lens starts/stops the bundled helper and pairs "
     @"the operator token into the Keychain on first use; without a "
     @"token it shows the pairing pane instead of data.\n\n"
     @"Navigation bar + Updates (snowfell-test-4; single-window model "
     @"snowfell-test-6): one window carries the navigation bar — "
     @"Portfolio, Board, Staged, Orchestration, Roadmap, Incidents, "
     @"Storage, Updates — and clicking a segment switches the lens in "
     @"that same window; the filled segment always names the lens on "
     @"screen, and the View menu's ⌘1–⌘9 items land on the same "
     @"lenses. View ▸ Updates (⌘9) shows the running snapshot next to "
     @"the published one, in plain terms, with the Check Now and "
     @"Apply Update buttons; snapshot sync itself works exactly as "
     @"it did before."];
    [alert beginSheetModalForWindow:self.mainWindow completionHandler:nil];
}

@end
