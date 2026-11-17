#import "TerminalViewController.h"
#import "SnapshotStore.h"
#import "WriteBackQueue.h"
#import "AcademyTheme.h"

// The ONE shared session core (merge tranche M3 extraction): plain C
// behind bridge.h, linked into this app from MinionCore/libminioncore.a
// and into the bundled `minion` binary from the same objects.
#import "session.h"
#import "version.h"

@interface TerminalViewController ()
@property (nonatomic, strong, readwrite, nullable) SnapshotStore *snapshotStore;
@property (nonatomic, strong, readwrite, nullable) WriteBackQueue *writeBackQueue;
@property (nonatomic, strong) NSTextField *statusField;
@property (nonatomic, strong) NSTextView *transcriptView;
@property (nonatomic, strong) NSTextField *inputField;
@property (nonatomic, strong) NSButton *stopButton;
// Lines typed while a turn is draining: held here (order preserved)
// and enqueued into the core queue the moment the drain returns —
// the GUI's type-ahead, mirroring the CLI's stdin pipe. Guarded by
// @synchronized(self); never held across a core call.
@property (nonatomic, strong) NSMutableArray<NSString *> *pendingLines;
// Bridge event sink, invoked from the C callback on the session
// queue while a drain runs.
- (void)handleBridgeEventType:(MinionBridgeEventType)type
                         text:(const char *)text;
@end

@implementation TerminalViewController {
    MinionSession _session;
    BOOL _sessionTried;
    BOOL _sessionOpen;
    NSString *_sessionOpenError;
    volatile int _interruptFlag;
    BOOL _draining;
    // DELTA snapshot diffing (the bridge.h contract: DELTA carries
    // the full reply so far; print only the appended suffix — the
    // CLI front-end's PrintCtx, same semantics).
    size_t _deltaLastLen;
    BOOL _deltaPrintedAny;
    dispatch_queue_t _sessionQueue;
}

#pragma mark - Bridge event sink (C callback; ctx is this controller)

static void TerminalBridgeEvent(void *ctx, const MinionBridgeEvent *ev) {
    TerminalViewController *controller =
        (__bridge TerminalViewController *)ctx;
    [controller handleBridgeEventType:ev->type text:ev->text];
}

- (void)handleBridgeEventType:(MinionBridgeEventType)type
                         text:(const char *)text {
    switch (type) {
        case MINION_BRIDGE_DELTA:
            if (text != NULL) {
                size_t n = strlen(text);
                if (n > _deltaLastLen) {
                    NSString *suffix = [NSString stringWithUTF8String:
                        (text + _deltaLastLen)];
                    _deltaLastLen = n;
                    _deltaPrintedAny = YES;
                    if (suffix != nil) {
                        [self appendTranscript:suffix];
                    }
                }
            }
            break;
        case MINION_BRIDGE_DONE:
            if (!_deltaPrintedAny) {
                if (text != NULL && text[0] != '\0') {
                    [self appendTranscript:[NSString stringWithUTF8String:text]];
                } else {
                    [self appendTranscript:@"(no reply text)"];
                }
            }
            [self appendTranscript:@"\n"];
            _deltaLastLen = 0;
            _deltaPrintedAny = NO;
            break;
        case MINION_BRIDGE_ERROR:
            [self appendTranscript:[NSString stringWithFormat:@"!! %@\n",
                text != NULL ? [NSString stringWithUTF8String:text]
                             : @"bridge error"]];
            _deltaLastLen = 0;
            _deltaPrintedAny = NO;
            break;
        case MINION_BRIDGE_INTERRUPTED:
            [self appendTranscript:@"\n[interrupted — remainder of the queue stays queued]\n"];
            _deltaLastLen = 0;
            _deltaPrintedAny = NO;
            break;
    }
}

#pragma mark - Lifecycle

- (instancetype)initWithSnapshotStore:(SnapshotStore *)snapshotStore
                       writeBackQueue:(WriteBackQueue *)writeBackQueue {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _snapshotStore = snapshotStore;
        _writeBackQueue = writeBackQueue;
        _syncStatusText = @"";
        _pendingLines = [[NSMutableArray alloc] init];
        _sessionQueue = dispatch_queue_create(
            "com.detroitautomationacademy.snowfell.terminal-session",
            DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    if (_sessionOpen) {
        minion_session_close(&_session);
        _sessionOpen = NO;
    }
}

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1180, 720)];

    // — Status strip (architecture section D): session state,
    // snapshot version + freshness, queue depth / staged count. —
    _statusField = [NSTextField labelWithString:@""];
    [_statusField setFont:[NSFont systemFontOfSize:12]];
    [_statusField setTextColor:[AcademyTheme inkSecondaryColor]];
    [_statusField setFrame:NSMakeRect(16, 720 - 36, 1148, 18)];
    [_statusField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:_statusField];

    // — Transcript —
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:
        NSMakeRect(16, 58, 1148, 620)];
    [scroll setHasVerticalScroller:YES];
    [scroll setBorderType:NSBezelBorder];
    [scroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    _transcriptView = [[NSTextView alloc] initWithFrame:
        NSMakeRect(0, 0, 1148, 620)];
    [_transcriptView setEditable:NO];
    [_transcriptView setSelectable:YES];
    [_transcriptView setFont:[NSFont userFixedPitchFontOfSize:12]];
    [_transcriptView setTextColor:[AcademyTheme inkColor]];
    [_transcriptView setBackgroundColor:[AcademyTheme panelColor]];
    [_transcriptView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [scroll setDocumentView:_transcriptView];
    [root addSubview:scroll];

    // — Prompt row —
    _inputField = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 16, 940, 28)];
    [_inputField setPlaceholderString:@"Message Minion — /help lists the local commands"];
    [_inputField setTarget:self];
    [_inputField setAction:@selector(sendMessage:)];
    [_inputField setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
    [root addSubview:_inputField];

    NSButton *sendButton = [[NSButton alloc] initWithFrame:NSMakeRect(964, 16, 96, 28)];
    [sendButton setTitle:@"Send"];
    [sendButton setBezelStyle:NSBezelStyleRounded];
    [sendButton setTarget:self];
    [sendButton setAction:@selector(sendMessage:)];
    [sendButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
    [root addSubview:sendButton];

    _stopButton = [[NSButton alloc] initWithFrame:NSMakeRect(1068, 16, 96, 28)];
    [_stopButton setTitle:@"Stop"];
    [_stopButton setBezelStyle:NSBezelStyleRounded];
    [_stopButton setTarget:self];
    [_stopButton setAction:@selector(stopStreaming:)];
    [_stopButton setEnabled:NO];
    [_stopButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
    [root addSubview:_stopButton];

    self.view = root;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    __weak TerminalViewController *weakSelf = self;
    dispatch_async(_sessionQueue, ^{
        [weakSelf ensureSessionOnSessionQueue];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf printBanner];
            [weakSelf refreshTerminal];
        });
    });
}

- (void)adoptSnapshotStore:(SnapshotStore *)snapshotStore {
    self.snapshotStore = snapshotStore;
    [self refreshTerminal];
}

#pragma mark - Session core (session queue only)

// Opens the shared session exactly once. Must be called on the
// session queue; every other core call is serialized there too.
- (void)ensureSessionOnSessionQueue {
    if (_sessionTried) {
        return;
    }
    _sessionTried = YES;
    const char *error = NULL;
    if (minion_session_open(&_session, &error) == 0) {
        _sessionOpen = YES;
    } else {
        _sessionOpen = NO;
        _sessionOpenError = error != NULL
            ? [NSString stringWithUTF8String:error] : @"unknown error";
    }
}

// The `minion status` block, formatted from the core's own state —
// the same lines session.c prints, rendered into the transcript or
// read for the strip. Must be called on the session queue.
- (NSString *)statusBlockOnSessionQueue {
    if (!_sessionOpen) {
        return [NSString stringWithFormat:
            @"session: closed (%@)", _sessionOpenError ?: @"not opened"];
    }
    return [NSString stringWithFormat:
        @"session: open\n"
        @"bridge: %@\n"
        @"identity: %@\n"
        @"version: %@%@\n"
        @"queued: %zu\n"
        @"enqueued: %llu\n"
        @"completed: %llu\n"
        @"last completed seq: %llu",
        [NSString stringWithUTF8String:minion_bridge_name(_session.bridge)],
        [NSString stringWithUTF8String:_session.identity],
        [NSString stringWithUTF8String:minion_version()],
        minion_version_is_stamped()
            ? @""
            : @" (developer build — no version stamp injected; "
              @"packaging stamps from the bundle Info.plist)",
        _session.queue.depth,
        (unsigned long long)_session.queue.total_enqueued,
        (unsigned long long)_session.queue.total_completed,
        (unsigned long long)_session.last_completed_seq];
}

- (void)printBanner {
    [self appendTranscript:
        @"Minion — terminal\n"
        @"a true command-line interface to Minion; this session "
        @"is its own channel\n"
        @"Type a message and press Enter. /help lists the "
        @"local commands.\n"];
    __weak TerminalViewController *weakSelf = self;
    dispatch_async(_sessionQueue, ^{
        NSString *block = [weakSelf statusBlockOnSessionQueue];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf appendTranscript:[block stringByAppendingString:@"\n"]];
        });
    });
}

#pragma mark - Transcript

// Appends on the main queue, from any thread.
- (void)appendTranscript:(NSString *)text {
    if (text == nil || [text length] == 0) {
        return;
    }
    if (![NSThread isMainThread]) {
        __weak TerminalViewController *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf appendTranscript:text];
        });
        return;
    }
    if (_transcriptView == nil) {
        return;
    }
    NSAttributedString *addition = [[NSAttributedString alloc]
        initWithString:text
            attributes:@{ NSFontAttributeName:
                              [NSFont userFixedPitchFontOfSize:12],
                          NSForegroundColorAttributeName:
                              [AcademyTheme inkColor] }];
    NSTextStorage *storage = [_transcriptView textStorage];
    [storage beginEditing];
    [storage appendAttributedString:addition];
    [storage endEditing];
    [_transcriptView scrollRangeToVisible:
        NSMakeRange([[_transcriptView string] length], 0)];
}

#pragma mark - Status strip

- (void)refreshTerminal {
    if (_statusField == nil) {
        return;
    }
    NSString *servedVersion = self.servedVersion;
    NSString *runningVersion = self.snapshotStore.snapshotVersion;
    NSString *snapshotPart;
    if (runningVersion == nil) {
        snapshotPart = @"Snapshot: none verified";
    } else if (servedVersion == nil) {
        snapshotPart = [NSString stringWithFormat:
            @"Snapshot: %@ · served not checked yet", runningVersion];
    } else if ([servedVersion isEqualToString:runningVersion]) {
        snapshotPart = [NSString stringWithFormat:
            @"Snapshot: %@ · up to date", runningVersion];
    } else {
        snapshotPart = [NSString stringWithFormat:
            @"Snapshot: %@ · served %@ published", runningVersion, servedVersion];
    }
    NSInteger staged = (self.writeBackQueue != nil)
        ? [self.writeBackQueue pendingCount] : -1;
    NSString *stagedPart = staged >= 0
        ? [NSString stringWithFormat:@"Staged: %ld staged change(s) waiting",
              (long)staged]
        : @"Staged: queue unavailable";
    __weak TerminalViewController *weakSelf = self;
    dispatch_async(_sessionQueue, ^{
        TerminalViewController *self_ = weakSelf;
        if (self_ == nil) {
            return;
        }
        NSString *sessionPart;
        NSString *queuePart;
        if (self_->_sessionOpen) {
            sessionPart = [NSString stringWithFormat:@"Session: open — %@",
                [NSString stringWithUTF8String:
                    minion_bridge_name(self_->_session.bridge)]];
            queuePart = [NSString stringWithFormat:@"Queue: %zu queued",
                self_->_session.queue.depth];
        } else if (self_->_sessionTried) {
            sessionPart = @"Session: closed";
            queuePart = @"Queue: 0 queued";
        } else {
            sessionPart = @"Session: opening…";
            queuePart = @"Queue: 0 queued";
        }
        NSString *line = [NSString stringWithFormat:@"%@ · %@ · %@ · %@",
            sessionPart, snapshotPart, queuePart, stagedPart];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.statusField setStringValue:line];
        });
    });
}

- (void)focusPrompt {
    if (_inputField != nil && [_inputField window] != nil) {
        [[_inputField window] makeFirstResponder:_inputField];
    }
}

#pragma mark - Sending

- (IBAction)sendMessage:(id)sender {
    NSString *raw = [[_inputField stringValue]
        stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (raw == nil || [raw length] == 0) {
        return;
    }
    [_inputField setStringValue:@""];
    if ([raw hasPrefix:@"/"]) {
        [self handleLocalCommand:raw];
        return;
    }
    [self appendTranscript:[NSString stringWithFormat:@"minion > %@\n", raw]];
    __weak TerminalViewController *weakSelf = self;
    dispatch_async(_sessionQueue, ^{
        TerminalViewController *self_ = weakSelf;
        if (self_ == nil) {
            return;
        }
        [self_ ensureSessionOnSessionQueue];
        if (!self_->_sessionOpen) {
            [self_ appendTranscript:[NSString stringWithFormat:
                @"!! session is not open: %@\n",
                self_->_sessionOpenError ?: @"unknown error"]];
            [self_ refreshTerminal];
            return;
        }
        if (self_->_draining) {
            // Type-ahead: the running drain owns the core queue;
            // this line joins the pending list and is enqueued, in
            // order, when the drain returns (see drainLoop).
            @synchronized (self_) {
                [self_.pendingLines addObject:raw];
            }
            return;
        }
        if (minion_session_send(&self_->_session, [raw UTF8String]) == 0) {
            [self_ appendTranscript:@"!! could not queue the message\n"];
            [self_ refreshTerminal];
            return;
        }
        [self_ drainLoopOnSessionQueue];
    });
}

- (IBAction)stopStreaming:(id)sender {
    // The core's only early exit: the owner's interrupt flag, polled
    // by the bridge between events (the CLI's Ctrl-C, as a button).
    _interruptFlag = 1;
}

// Enqueues any GUI-pending lines into the core queue, in order.
// Session queue only. Returns YES when at least one line moved.
- (BOOL)enqueuePendingLinesOnSessionQueue {
    NSArray<NSString *> *lines = nil;
    @synchronized (self) {
        if ([_pendingLines count] > 0) {
            lines = [_pendingLines copy];
            [_pendingLines removeAllObjects];
        }
    }
    if (lines == nil) {
        return NO;
    }
    for (NSString *line in lines) {
        minion_session_send(&_session, [line UTF8String]);
    }
    return YES;
}

// Drains head-first until the queue empties. Session queue only.
// After an interrupt or an error the drain stops (the core's own
// semantics): GUI-pending lines are still enqueued behind the
// remainder — order is global — but nothing further is dispatched
// until the owner's next Send.
- (void)drainLoopOnSessionQueue {
    _draining = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.stopButton setEnabled:YES];
        [self refreshTerminal];
    });
    int rc = 0;
    for (;;) {
        _interruptFlag = 0;
        _deltaLastLen = 0;
        _deltaPrintedAny = NO;
        rc = minion_session_drain(&_session, &_interruptFlag,
                                  TerminalBridgeEvent,
                                  (__bridge void *)self);
        BOOL hadPending = [self enqueuePendingLinesOnSessionQueue];
        if (rc != 0 || !hadPending) {
            break;
        }
    }
    _draining = NO;
    size_t depth = _session.queue.depth;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.stopButton setEnabled:NO];
        if (rc == 2 && depth > 0) {
            [self appendTranscript:[NSString stringWithFormat:
                @"[%zu message(s) still queued]\n", depth]];
        }
        [self refreshTerminal];
    });
}

#pragma mark - Local commands (CLI parity — cli/commands.c + main.c)

// The CLI front-end's local-command surface, in this lens. /help
// prints the shared list verbatim (commands.c); /view and /quit
// answer with this environment's truth, exactly as /view does in
// the CLI itself (no hosted window exists in either front-end).
- (void)handleLocalCommand:(NSString *)line {
    if ([line isEqualToString:@"/help"]) {
        [self appendTranscript:
            @"/help   this list\n"
            @"/clear  clear the scrollback\n"
            @"/view   back to the hosted Minion window\n"
            @"/status session state (same as `minion status`)\n"
            @"/quit   leave the Minion CLI\n"
            @"Anything else is a message to Minion.\n"];
    } else if ([line isEqualToString:@"/clear"]) {
        [_transcriptView setString:@""];
    } else if ([line isEqualToString:@"/view"]) {
        [self appendTranscript:
            @"No hosted window in this app — the Terminal lens "
            @"is the primary interface.\n"];
    } else if ([line isEqualToString:@"/status"]) {
        __weak TerminalViewController *weakSelf = self;
        dispatch_async(_sessionQueue, ^{
            [weakSelf ensureSessionOnSessionQueue];
            NSString *block = [weakSelf statusBlockOnSessionQueue];
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf appendTranscript:
                    [block stringByAppendingString:@"\n"]];
            });
        });
    } else if ([line isEqualToString:@"/quit"] ||
               [line isEqualToString:@"/exit"]) {
        [self appendTranscript:
            @"This session lives with the app — Quit Snowfell "
            @"(⌘Q) closes it; the queue is in memory only.\n"];
    } else {
        [self appendTranscript:[NSString stringWithFormat:
            @"Unknown local command: %@ — /help lists them. "
            @"Nothing was sent.\n", line]];
    }
}

@end
