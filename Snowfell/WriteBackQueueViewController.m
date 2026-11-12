#import "WriteBackQueueViewController.h"
#import "WriteBackQueue.h"
#import "GitHubProjectsClient.h"

@interface WriteBackQueueViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong, readwrite) WriteBackQueue *queue;
@property (nonatomic, strong, readwrite) GitHubProjectsClient *client;
@property (nonatomic, strong) NSTextField *armField;
@property (nonatomic, strong) NSTextField *reasonField;
@property (nonatomic, strong) NSTableView *table;
@property (nonatomic, strong) NSButton *sendButton;
@property (nonatomic, copy) NSArray<WriteBackMutation *> *rows;
@end

@implementation WriteBackQueueViewController

- (instancetype)initWithQueue:(WriteBackQueue *)queue
                       client:(GitHubProjectsClient *)client {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _queue = queue;
        _client = client;
        _rows = @[];
    }
    return self;
}

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 860, 480)];

    _armField = [NSTextField labelWithString:@""];
    [_armField setFont:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]];
    [_armField setFrame:NSMakeRect(16, 480 - 30, 828, 18)];
    [_armField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:_armField];

    _reasonField = [NSTextField labelWithString:@""];
    [_reasonField setFont:[NSFont systemFontOfSize:12]];
    [_reasonField setTextColor:[NSColor secondaryLabelColor]];
    [[_reasonField cell] setWraps:YES];
    [_reasonField setFrame:NSMakeRect(16, 480 - 66, 828, 30)];
    [_reasonField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [root addSubview:_reasonField];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 52, 860, 480 - 126)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setBorderType:NSNoBorder];
    [scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    _table = [[NSTableView alloc] initWithFrame:scrollView.bounds];
    [_table setDataSource:self];
    [_table setDelegate:self];
    [_table setUsesAlternatingRowBackgroundColors:YES];
    [_table setRowHeight:20];
    [_table setAllowsMultipleSelection:NO];

    NSArray<NSArray *> *columns = @[
        @[@"kind", @"Change", @110],
        @[@"target", @"Target", @330],
        @[@"state", @"State", @70],
        @[@"attempts", @"Attempts", @60],
        @[@"created", @"Staged", @150],
        @[@"error", @"Last error", @220],
    ];
    for (NSArray *spec in columns) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:spec[0]];
        [[column headerCell] setStringValue:spec[1]];
        [column setWidth:[spec[2] doubleValue]];
        [_table addTableColumn:column];
    }
    [scrollView setDocumentView:_table];
    [root addSubview:scrollView];

    NSButton *refreshButton = [[NSButton alloc] initWithFrame:NSMakeRect(16, 12, 110, 28)];
    [refreshButton setTitle:@"Refresh"];
    [refreshButton setBezelStyle:NSBezelStyleRounded];
    [refreshButton setTarget:self];
    [refreshButton setAction:@selector(refreshClicked:)];
    [root addSubview:refreshButton];

    _sendButton = [[NSButton alloc] initWithFrame:NSMakeRect(860 - 196, 12, 180, 28)];
    [_sendButton setTitle:@"Send Pending Changes…"];
    [_sendButton setBezelStyle:NSBezelStyleRounded];
    [_sendButton setTarget:self];
    [_sendButton setAction:@selector(sendClicked:)];
    [_sendButton setAutoresizingMask:NSViewMinXMargin];
    [root addSubview:_sendButton];

    self.view = root;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self reloadQueue];
}

#pragma mark - Rendering

- (void)reloadQueue {
    NSError *error = nil;
    NSArray<WriteBackMutation *> *rows = (self.queue != nil)
        ? [self.queue allMutationsWithError:&error] : nil;
    self.rows = (rows != nil) ? rows : @[];
    [_table reloadData];

    BOOL compiled = [GitHubProjectsClient writeBackCompiledEnabled];
    GitHubTokenStatus tokenStatus = (self.client != nil)
        ? [self.client tokenStatus] : GitHubTokenStatusNotConfigured;
    NSInteger pending = (self.queue != nil) ? [self.queue pendingCount] : 0;

    [_armField setStringValue:[NSString stringWithFormat:
                               @"Staged changes — %lu total, %ld waiting to send · sending %@ in this build%@",
                               (unsigned long)[self.rows count], (long)pending,
                               compiled ? @"ON" : @"OFF",
                               (tokenStatus == GitHubTokenStatusAvailable) ? @"" : @" · no GitHub token stored"]];

    NSMutableArray<NSString *> *reasons = [NSMutableArray array];
    if (!compiled) {
        [reasons addObject:@"Sending is off in this build, so staged changes stay on this Mac and no network call can be made. Each row's tooltip carries the full record: what will be sent, where, and by what mechanism."];
    }
    if (tokenStatus != GitHubTokenStatusAvailable) {
        [reasons addObject:@"No GitHub token is stored in your macOS Keychain, so there is nothing to send with yet."];
    }
    if (pending == 0) {
        [reasons addObject:@"Nothing is waiting to send."];
    }
    if ([reasons count] == 0) {
        [reasons addObject:@"Ready: Send Pending Changes sends each waiting change once, in the order staged, and records the outcome here."];
    }
    [_reasonField setStringValue:[reasons componentsJoinedByString:@" "]];
    [_sendButton setEnabled:(compiled && tokenStatus == GitHubTokenStatusAvailable && pending > 0)];
}

- (void)refreshClicked:(id)sender {
    [self reloadQueue];
}

- (void)sendClicked:(id)sender {
    if (self.sendRequestedHandler != nil) {
        self.sendRequestedHandler();
    }
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)[self.rows count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    WriteBackMutation *mutation = self.rows[(NSUInteger)row];
    NSString *identifier = [tableColumn identifier];
    if ([identifier isEqualToString:@"kind"]) {
        // User terms in the list; the raw kind stays in the tooltip.
        if ([mutation.kind isEqualToString:@"status_move"]) {
            return @"Status change";
        }
        if ([mutation.kind isEqualToString:@"create_item"]) {
            return @"New item";
        }
        if ([mutation.kind isEqualToString:@"comment"]) {
            return @"Comment";
        }
        return mutation.kind;
    }
    if ([identifier isEqualToString:@"target"]) {
        return mutation.targetSummary;
    }
    if ([identifier isEqualToString:@"state"]) {
        if ([mutation.state isEqualToString:@"pending"]) {
            return @"Waiting";
        }
        if ([mutation.state isEqualToString:@"sending"]) {
            return @"Sending…";
        }
        if ([mutation.state isEqualToString:@"sent"]) {
            return @"Sent";
        }
        if ([mutation.state isEqualToString:@"failed"]) {
            return @"Failed";
        }
        return mutation.state;
    }
    if ([identifier isEqualToString:@"attempts"]) {
        return [NSString stringWithFormat:@"%ld", (long)mutation.attempts];
    }
    if ([identifier isEqualToString:@"created"]) {
        return mutation.createdAt;
    }
    if ([identifier isEqualToString:@"error"]) {
        return (mutation.lastError != nil) ? mutation.lastError : @"";
    }
    return @"";
}

#pragma mark - NSTableViewDelegate

- (NSString *)tableView:(NSTableView *)tableView toolTipForCell:(NSCell *)cell rect:(NSRectPointer)rect tableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row mouseLocation:(NSPoint)mouseLocation {
    WriteBackMutation *mutation = self.rows[(NSUInteger)row];
    return [NSString stringWithFormat:@"#%lld · %@\nboard %@\n%@\nDestination when sent: %@ (GitHub GraphQL API, over HTTPS)",
            mutation.queueID, mutation.kind, mutation.boardID, mutation.payloadJSON,
            [GitHubProjectsClient graphQLEndpoint]];
}

@end
