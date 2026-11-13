// UpdatesViewController — the Updates lens (View ▸ Updates, ⌘9;
// snowfell-test-4): where the owner sees the snapshot-sync state that
// used to live only inside Preferences. It shows the running snapshot
// (version + short SHA-256, from the loaded store's verified manifest),
// the served snapshot (the last manifest AppDelegate fetched, or "not
// checked yet"), a plain-language line for the gap between them, and
// the session's sync status text.
//
// This lens contains NO network code and no sync logic: Check Now and
// Apply Update fire the handler blocks below, which AppDelegate wires
// to its EXISTING actions (checkForSnapshotUpdate: /
// applyStagedSnapshot:) — SnapshotSync and the swap path stay exactly
// where they were. AppDelegate pushes fresh state in through the three
// properties on every sync step (the same refresh that feeds the
// Preferences block) and calls refreshUpdates.
#import <AppKit/AppKit.h>

@class SnapshotStore;

NS_ASSUME_NONNULL_BEGIN

@interface UpdatesViewController : NSViewController

@property (nonatomic, strong, readonly) SnapshotStore *snapshotStore;

// Session sync state, pushed by AppDelegate before every refreshUpdates.
@property (nonatomic, copy, nullable) NSString *servedVersion;   // nil = not checked yet
@property (nonatomic, copy) NSString *statusText;
@property (nonatomic, assign) BOOL stagedUpdateAvailable;

// Fired by the buttons; AppDelegate wires them to its existing
// checkForSnapshotUpdate: / applyStagedSnapshot: actions.
@property (nonatomic, copy, nullable) void (^checkRequestedHandler)(void);
@property (nonatomic, copy, nullable) void (^applyRequestedHandler)(void);

- (instancetype)initWithSnapshotStore:(SnapshotStore *)store;

// Re-renders every line from the store + the pushed session state.
// Safe with no snapshot loaded: the running line states that instead.
- (void)refreshUpdates;

@end

NS_ASSUME_NONNULL_END
