// WriteBackQueueViewController — the Queue panel (View ▸ Write-back
// Queue, ⌘4; SF-T4): every pending mutation in the LOCAL WriteBackQueue
// with its kind, target, state, attempts, and last error — plus the arm
// state of the send path, stated as text: whether write-back is compiled
// in, and whether a Keychain token is configured.
//
// The Send button is enabled only when BOTH locks are open (compiled on
// AND token configured AND rows pending). In this build the compile-time
// lock is shut, so the button stays disabled and the reason label says
// exactly why — the panel never pretends a send happened or could.
#import <AppKit/AppKit.h>

@class WriteBackQueue;
@class GitHubProjectsClient;

NS_ASSUME_NONNULL_BEGIN

@interface WriteBackQueueViewController : NSViewController

@property (nonatomic, strong, readonly) WriteBackQueue *queue;
@property (nonatomic, strong, readonly) GitHubProjectsClient *client;

// Fired by the Send button. The delegate (AppDelegate) owns the actual
// send pass (sendPendingMutations:) and calls reloadQueue when it ends.
@property (nonatomic, copy, nullable) void (^sendRequestedHandler)(void);

- (instancetype)initWithQueue:(WriteBackQueue *)queue
                       client:(GitHubProjectsClient *)client;

// Re-reads the queue and the arm state, and re-renders.
- (void)reloadQueue;

@end

NS_ASSUME_NONNULL_END
