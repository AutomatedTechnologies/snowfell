// TerminalViewController — the Terminal lens (merge tranche M4;
// snowfell-test-9): the owner's command seat inside the merged app,
// and the app's launch home (merge architecture of record,
// minion-cli-high-sierra/files/MERGE-ARCHITECTURE-2026-11-14.md
// sections B/D — host model (d): the GUI Terminal lens and the
// standalone `minion` binary are two front-ends over ONE session
// core).
//
// The lens links the shared session core (MinionCore/core —
// queue/session/bridge behind the unchanged bridge.h, extracted in
// tranche M3) and drives it exactly as the CLI front-end does:
// every line the owner sends is enqueued first and drained
// head-first (FIFO, never superseded, never time-capped — the two
// defects of the retired hosted bridge this program exists to
// remove). Local commands keep the CLI's parity set: /help, /clear,
// /view (the honest stub — no hosted window exists in this app),
// /status, /quit.
//
// Honest state, stated on the surface rather than discovered: the
// bridge's wire seam is UNCONFIRMED until the owner's T4 capture
// (tranche M6) fills it, and the bridge stops a send at the auth
// boundary — before any network traffic — when no session cookie
// is supplied. GUI cookie custody (the Keychain item of record) is
// M6's implementation and is NOT in this build; nothing here reads
// or stores a credential.
//
// The status strip carries the architecture's three lines: Muse
// session state (the core's own session/bridge state) · snapshot
// version + freshness (the loaded store's verified version and the
// session's sync state, pushed by AppDelegate on every sync step —
// the same push that feeds the Updates lens) · queue depth / staged
// count (the core queue's depth and the write-back queue's pending
// count — two separate queues in two separate stores, never
// conflated).
//
// Threading: the C queue is single-threaded by design (the CLI's
// model). Every core call — open, enqueue, drain — runs on this
// controller's serial session queue; bridge events marshal back to
// the main queue for display. Sends typed while a turn streams are
// enqueued and delivered after it, in order (type-ahead parity).
#import <AppKit/AppKit.h>

@class SnapshotStore;
@class WriteBackQueue;

NS_ASSUME_NONNULL_BEGIN

@interface TerminalViewController : NSViewController

@property (nonatomic, strong, readonly, nullable) SnapshotStore *snapshotStore;
@property (nonatomic, strong, readonly, nullable) WriteBackQueue *writeBackQueue;

// Snapshot sync state, pushed by AppDelegate before every
// refreshTerminal (the refreshSnapshotSyncBlock push).
@property (nonatomic, copy, nullable) NSString *servedVersion;   // nil = not checked yet
@property (nonatomic, copy) NSString *syncStatusText;

- (instancetype)initWithSnapshotStore:(nullable SnapshotStore *)snapshotStore
                       writeBackQueue:(nullable WriteBackQueue *)writeBackQueue;

// A snapshot swap (File > Open Snapshot… / Updates Apply) replaces
// the store under every lens. The Terminal's session is NOT dropped
// with it — the core session is independent of the snapshot — so
// AppDelegate re-points this lens at the new store in place and the
// strip re-renders against it.
- (void)adoptSnapshotStore:(nullable SnapshotStore *)snapshotStore;

// Re-renders the status strip from the core session + the pushed
// sync state. Safe before the view loads and with no snapshot.
- (void)refreshTerminal;

// Puts the keyboard focus in the prompt field (the launch-home
// contract: Terminal lands focused). No-op before the view loads.
- (void)focusPrompt;

@end

NS_ASSUME_NONNULL_END
