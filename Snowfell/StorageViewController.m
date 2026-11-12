#import "StorageViewController.h"
#import "CloudServiceClient.h"
#import "CloudModels.h"

@interface StorageViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong, readwrite) CloudServiceClient *cloudClient;
@property (nonatomic, copy) NSArray<CloudTenant *> *tenants;
@property (nonatomic, strong, nullable) CloudTenant *selectedTenant;
@property (nonatomic, copy) NSArray<CloudBucket *> *buckets;
@property (nonatomic, copy) NSArray<CloudLogin *> *logins;
@property (nonatomic, copy) NSArray<CloudAuditEntry *> *auditEntries;
@property (nonatomic, copy) NSArray<CloudCollection *> *collections;
@property (nonatomic, copy) NSArray<CloudContentItem *> *contentItems;
@property (nonatomic, copy) NSArray<CloudContentVersion *> *contentVersions;
@property (nonatomic, copy) NSArray<NSDictionary *> *backends;
@property (nonatomic, strong, nullable) CloudServiceHealth *lastHealth;
@property (nonatomic, strong, nullable) NSTask *serviceTask;
@property (nonatomic, strong, nullable) NSTimer *healthTimer;

// Pairing pane (§5.5) — shown instead of data while no token is stored.
@property (nonatomic, strong) NSView *pairingView;
@property (nonatomic, strong) NSSecureTextField *pairTokenField;
@property (nonatomic, strong) NSTextField *pairStatusField;

// Data pane.
@property (nonatomic, strong) NSView *dataView;
@property (nonatomic, strong) NSTextField *serviceStateField;
@property (nonatomic, strong) NSButton *startServiceButton;
@property (nonatomic, strong) NSButton *stopServiceButton;
@property (nonatomic, strong) NSTextField *tenantDetailField;
@property (nonatomic, strong) NSTableView *tenantTable;
@property (nonatomic, strong) NSTableView *bucketTable;
@property (nonatomic, strong) NSTableView *loginTable;
@property (nonatomic, strong) NSTableView *auditTable;
@property (nonatomic, strong) NSTextField *dedupField;
@property (nonatomic, strong) NSTableView *collectionTable;
@property (nonatomic, strong) NSTableView *contentTable;
@property (nonatomic, strong) NSTableView *versionTable;
@property (nonatomic, strong) NSTextField *statusField;
@property (nonatomic, strong) NSButton *closeTenantButton;
@property (nonatomic, strong) NSButton *createLoginButton;
@property (nonatomic, strong) NSButton *setPasswordButton;
@property (nonatomic, strong) NSButton *issueResetButton;
@property (nonatomic, strong) NSButton *deleteLoginButton;
@property (nonatomic, strong) NSButton *createBucketButton;
@property (nonatomic, strong) NSButton *deleteBucketButton;
@property (nonatomic, strong) NSButton *createCollectionButton;
@property (nonatomic, strong) NSButton *createContentButton;
@property (nonatomic, strong) NSButton *createVersionButton;
@property (nonatomic, strong) NSButton *rollbackContentButton;
@property (nonatomic, strong) NSButton *setContentStateButton;
@property (nonatomic, strong) NSButton *deleteContentButton;
@property (nonatomic, strong) NSButton *runGCButton;
@end

@implementation StorageViewController

- (instancetype)initWithCloudServiceClient:(CloudServiceClient *)client {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _cloudClient = client;
        _tenants = @[];
        _buckets = @[];
        _logins = @[];
        _auditEntries = @[];
        _collections = @[];
        _contentItems = @[];
        _contentVersions = @[];
        _backends = @[];
    }
    return self;
}

#pragma mark - View construction

- (NSTableColumn *)columnWithIdentifier:(NSString *)identifier
                                  title:(NSString *)title
                                  width:(CGFloat)width
                                inTable:(NSTableView *)table {
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifier];
    [column setTitle:title];
    [column setWidth:width];
    [column setMinWidth:40];
    [table addTableColumn:column];
    return column;
}

- (NSButton *)buttonWithTitle:(NSString *)title action:(SEL)action frame:(NSRect)frame {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    [button setBezelStyle:NSRoundedBezelStyle];
    [button setFrame:frame];
    return button;
}

- (NSTextField *)headerLabelWithString:(NSString *)string frame:(NSRect)frame {
    NSTextField *label = [NSTextField labelWithString:string];
    [label setFont:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]];
    [label setFrame:frame];
    return label;
}

- (NSScrollView *)scrollViewWithTable:(NSTableView *)table frame:(NSRect)frame {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:frame];
    [scroll setHasVerticalScroller:YES];
    [scroll setBorderType:NSBezelBorder];
    [scroll setDocumentView:table];
    return scroll;
}

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1120, 680)];
    [self buildPairingViewInRoot:root];
    [self buildDataViewInRoot:root];
    self.view = root;
}

- (void)buildPairingViewInRoot:(NSView *)root {
    NSView *pairing = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1120, 680)];
    [pairing setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    NSTextField *title = [NSTextField labelWithString:@"Storage — pair the operator token"];
    [title setFont:[NSFont systemFontOfSize:14 weight:NSFontWeightSemibold]];
    [title setFrame:NSMakeRect(60, 596, 1000, 22)];
    [pairing addSubview:title];

    NSTextField *instructions = [NSTextField labelWithString:
        @"This lens administers the SnowfellStorageService over its REST API, and every call "
        @"carries the operator token. No token is in the Keychain yet, so the lens shows this "
        @"pairing pane instead of data.\n\n"
        @"Bootstrap (design §5.5): on first run the service generates the operator token, "
        @"stores only its SHA-256 digest, and writes the plaintext ONCE to\n"
        @"~/Library/Application Support/Snowfell/cloud/bootstrap-operator-token.txt\n"
        @"(mode 0600, inside the 0700 data directory). Open that file, copy the token, and "
        @"paste it below. Saving stores it in the macOS Keychain — service "
        @"com.detroitautomationacademy.snowfell.cloud-operator, account operator — which is "
        @"its only custody: this app never writes it to a file or database and never logs it.\n\n"
        @"The bootstrap file's job is then done — delete it. The service also deletes it "
        @"automatically on the first successful operator authentication. There is no default "
        @"password and no hardcoded credential."];
    [instructions setFont:[NSFont systemFontOfSize:12]];
    [[instructions cell] setWraps:YES];
    [instructions setFrame:NSMakeRect(60, 396, 1000, 188)];
    [pairing addSubview:instructions];

    _pairTokenField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(60, 348, 700, 26)];
    [_pairTokenField setPlaceholderString:@"Operator token (from bootstrap-operator-token.txt)"];
    [pairing addSubview:_pairTokenField];

    NSButton *saveButton = [self buttonWithTitle:@"Save to Keychain"
                                          action:@selector(savePairingToken:)
                                           frame:NSMakeRect(776, 346, 170, 30)];
    [pairing addSubview:saveButton];

    _pairStatusField = [NSTextField labelWithString:@""];
    [_pairStatusField setFont:[NSFont systemFontOfSize:12]];
    [_pairStatusField setTextColor:[NSColor secondaryLabelColor]];
    [[_pairStatusField cell] setWraps:YES];
    [_pairStatusField setFrame:NSMakeRect(60, 292, 1000, 44)];
    [pairing addSubview:_pairStatusField];

    _pairingView = pairing;
    [root addSubview:pairing];
}

- (void)buildDataViewInRoot:(NSView *)root {
    NSView *data = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1120, 680)];
    [data setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    _serviceStateField = [NSTextField labelWithString:@""];
    [_serviceStateField setFont:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]];
    [[_serviceStateField cell] setWraps:YES];
    [_serviceStateField setFrame:NSMakeRect(16, 642, 796, 34)];
    [data addSubview:_serviceStateField];

    _startServiceButton = [self buttonWithTitle:@"Start Service"
                                         action:@selector(startService:)
                                          frame:NSMakeRect(828, 646, 132, 28)];
    [data addSubview:_startServiceButton];
    _stopServiceButton = [self buttonWithTitle:@"Stop Service"
                                        action:@selector(stopService:)
                                         frame:NSMakeRect(972, 646, 132, 28)];
    [data addSubview:_stopServiceButton];

    NSTextField *subheader = [NSTextField labelWithString:
        @"Operator console for SnowfellStorageService — every figure below arrives over the "
        @"loopback REST API (design §9); this lens holds no SQL and never opens cloud.db. "
        @"Mutations open a confirm sheet naming the target before anything is sent."];
    [subheader setFont:[NSFont systemFontOfSize:12]];
    [subheader setTextColor:[NSColor secondaryLabelColor]];
    [[subheader cell] setWraps:YES];
    [subheader setFrame:NSMakeRect(16, 610, 1088, 28)];
    [data addSubview:subheader];

    // Mutation buttons row.
    CGFloat bx = 16.0;
    NSButton *newTenantButton = [self buttonWithTitle:@"New Tenant…"
                                               action:@selector(newTenant:)
                                                frame:NSMakeRect(bx, 576, 108, 26)];
    [data addSubview:newTenantButton];
    bx += 114.0;
    _closeTenantButton = [self buttonWithTitle:@"Close Tenant…"
                                        action:@selector(closeTenant:)
                                         frame:NSMakeRect(bx, 576, 112, 26)];
    [data addSubview:_closeTenantButton];
    bx += 118.0;
    _createLoginButton = [self buttonWithTitle:@"New Login…"
                                     action:@selector(newLogin:)
                                      frame:NSMakeRect(bx, 576, 104, 26)];
    [data addSubview:_createLoginButton];
    bx += 110.0;
    _setPasswordButton = [self buttonWithTitle:@"Set Password…"
                                        action:@selector(setPassword:)
                                         frame:NSMakeRect(bx, 576, 116, 26)];
    [data addSubview:_setPasswordButton];
    bx += 122.0;
    _issueResetButton = [self buttonWithTitle:@"Issue Reset…"
                                       action:@selector(issueReset:)
                                        frame:NSMakeRect(bx, 576, 108, 26)];
    [data addSubview:_issueResetButton];
    bx += 114.0;
    _deleteLoginButton = [self buttonWithTitle:@"Delete Login…"
                                        action:@selector(deleteLogin:)
                                         frame:NSMakeRect(bx, 576, 110, 26)];
    [data addSubview:_deleteLoginButton];
    bx += 116.0;
    _createBucketButton = [self buttonWithTitle:@"New Bucket…"
                                      action:@selector(newBucket:)
                                       frame:NSMakeRect(bx, 576, 108, 26)];
    [data addSubview:_createBucketButton];
    bx += 114.0;
    _deleteBucketButton = [self buttonWithTitle:@"Delete Bucket…"
                                         action:@selector(deleteBucket:)
                                          frame:NSMakeRect(bx, 576, 114, 26)];
    [data addSubview:_deleteBucketButton];
    bx += 120.0;
    NSButton *refreshButton = [self buttonWithTitle:@"Refresh"
                                             action:@selector(refresh:)
                                              frame:NSMakeRect(bx, 576, 84, 26)];
    [data addSubview:refreshButton];

    // Left: the tenant table.
    [data addSubview:[self headerLabelWithString:@"Tenants" frame:NSMakeRect(16, 548, 400, 18)]];
    _tenantTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 400, 464)];
    [self columnWithIdentifier:@"slug" title:@"Slug" width:120 inTable:_tenantTable];
    [self columnWithIdentifier:@"tname" title:@"Name" width:140 inTable:_tenantTable];
    [self columnWithIdentifier:@"tstate" title:@"State" width:64 inTable:_tenantTable];
    [self columnWithIdentifier:@"tused" title:@"Used" width:72 inTable:_tenantTable];
    [_tenantTable setDataSource:self];
    [_tenantTable setDelegate:self];
    [_tenantTable setAllowsMultipleSelection:NO];
    NSScrollView *tenantScroll = [self scrollViewWithTable:_tenantTable
                                                     frame:NSMakeRect(16, 76, 400, 464)];
    [tenantScroll setAutoresizingMask:NSViewHeightSizable];
    [data addSubview:tenantScroll];

    // Right: the selected tenant's detail.
    _tenantDetailField = [NSTextField labelWithString:@""];
    [_tenantDetailField setFont:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]];
    [[_tenantDetailField cell] setWraps:YES];
    [_tenantDetailField setFrame:NSMakeRect(432, 540, 672, 26)];
    [data addSubview:_tenantDetailField];

    [data addSubview:[self headerLabelWithString:@"Buckets" frame:NSMakeRect(432, 516, 672, 18)]];
    _bucketTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 672, 76)];
    [self columnWithIdentifier:@"bname" title:@"Name" width:230 inTable:_bucketTable];
    [self columnWithIdentifier:@"bobjects" title:@"Objects" width:80 inTable:_bucketTable];
    [self columnWithIdentifier:@"bbytes" title:@"Bytes" width:130 inTable:_bucketTable];
    [self columnWithIdentifier:@"bquota" title:@"Quota" width:130 inTable:_bucketTable];
    [self columnWithIdentifier:@"bbackend" title:@"Backend" width:90 inTable:_bucketTable];
    [_bucketTable setDataSource:self];
    [_bucketTable setDelegate:self];
    [_bucketTable setAllowsMultipleSelection:NO];
    [data addSubview:[self scrollViewWithTable:_bucketTable frame:NSMakeRect(432, 436, 672, 76)]];

    [data addSubview:[self headerLabelWithString:@"Logins" frame:NSMakeRect(432, 412, 672, 18)]];
    _loginTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 672, 76)];
    [self columnWithIdentifier:@"luser" title:@"Username" width:170 inTable:_loginTable];
    [self columnWithIdentifier:@"lrole" title:@"Role" width:130 inTable:_loginTable];
    [self columnWithIdentifier:@"lstate" title:@"State" width:90 inTable:_loginTable];
    [self columnWithIdentifier:@"llock" title:@"Lock" width:70 inTable:_loginTable];
    [self columnWithIdentifier:@"llast" title:@"Last login" width:190 inTable:_loginTable];
    [_loginTable setDataSource:self];
    [_loginTable setDelegate:self];
    [_loginTable setAllowsMultipleSelection:NO];
    [data addSubview:[self scrollViewWithTable:_loginTable frame:NSMakeRect(432, 332, 672, 76)]];

    [data addSubview:[self headerLabelWithString:@"Audit — this tenant, as served" frame:NSMakeRect(432, 308, 672, 18)]];
    _auditTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 672, 76)];
    [self columnWithIdentifier:@"ats" title:@"Time" width:170 inTable:_auditTable];
    [self columnWithIdentifier:@"aactor" title:@"Actor" width:130 inTable:_auditTable];
    [self columnWithIdentifier:@"aaction" title:@"Action" width:190 inTable:_auditTable];
    [self columnWithIdentifier:@"aobject" title:@"Object" width:110 inTable:_auditTable];
    [self columnWithIdentifier:@"aresult" title:@"Result" width:60 inTable:_auditTable];
    [_auditTable setDataSource:self];
    [_auditTable setDelegate:self];
    [_auditTable setAllowsMultipleSelection:NO];
    [data addSubview:[self scrollViewWithTable:_auditTable frame:NSMakeRect(432, 228, 672, 76)]];

    // Content (§13.5 CMS, SF-T12j): collections / items / versions
    // side by side under the buckets/logins/audit stack, the §13.6
    // dedup figures right-aligned on the section header line, and
    // the content mutation buttons on their own row.
    [data addSubview:[self headerLabelWithString:@"Content" frame:NSMakeRect(432, 204, 200, 18)]];
    _dedupField = [NSTextField labelWithString:@""];
    [_dedupField setFont:[NSFont systemFontOfSize:12]];
    [_dedupField setTextColor:[NSColor secondaryLabelColor]];
    [_dedupField setAlignment:NSTextAlignmentRight];
    [_dedupField setFrame:NSMakeRect(640, 205, 464, 16)];
    [data addSubview:_dedupField];

    [data addSubview:[self headerLabelWithString:@"Collections" frame:NSMakeRect(432, 180, 150, 16)]];
    [data addSubview:[self headerLabelWithString:@"Items" frame:NSMakeRect(590, 180, 274, 16)]];
    [data addSubview:[self headerLabelWithString:@"Versions" frame:NSMakeRect(872, 180, 232, 16)]];

    _collectionTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 150, 76)];
    [self columnWithIdentifier:@"cname" title:@"Name" width:58 inTable:_collectionTable];
    [self columnWithIdentifier:@"cslug" title:@"Slug" width:52 inTable:_collectionTable];
    [self columnWithIdentifier:@"cparent" title:@"Parent" width:40 inTable:_collectionTable];
    [_collectionTable setDataSource:self];
    [_collectionTable setDelegate:self];
    [_collectionTable setAllowsMultipleSelection:NO];
    [data addSubview:[self scrollViewWithTable:_collectionTable frame:NSMakeRect(432, 100, 150, 76)]];

    _contentTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 274, 76)];
    [self columnWithIdentifier:@"islug" title:@"Slug" width:68 inTable:_contentTable];
    [self columnWithIdentifier:@"ititle" title:@"Title" width:62 inTable:_contentTable];
    [self columnWithIdentifier:@"ikind" title:@"Kind" width:36 inTable:_contentTable];
    [self columnWithIdentifier:@"istate" title:@"State" width:44 inTable:_contentTable];
    [self columnWithIdentifier:@"iver" title:@"Ver" width:26 inTable:_contentTable];
    [self columnWithIdentifier:@"isize" title:@"Size" width:38 inTable:_contentTable];
    [_contentTable setDataSource:self];
    [_contentTable setDelegate:self];
    [_contentTable setAllowsMultipleSelection:NO];
    [data addSubview:[self scrollViewWithTable:_contentTable frame:NSMakeRect(590, 100, 274, 76)]];

    _versionTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 232, 76)];
    [self columnWithIdentifier:@"vno" title:@"Ver" width:28 inTable:_versionTable];
    [self columnWithIdentifier:@"vsha" title:@"SHA-256" width:76 inTable:_versionTable];
    [self columnWithIdentifier:@"vsize" title:@"Size" width:44 inTable:_versionTable];
    [self columnWithIdentifier:@"vnote" title:@"Note" width:36 inTable:_versionTable];
    [self columnWithIdentifier:@"vcreated" title:@"Created" width:48 inTable:_versionTable];
    [_versionTable setDataSource:self];
    [_versionTable setDelegate:self];
    [_versionTable setAllowsMultipleSelection:NO];
    [data addSubview:[self scrollViewWithTable:_versionTable frame:NSMakeRect(872, 100, 232, 76)]];

    CGFloat cx = 432.0;
    _createCollectionButton = [self buttonWithTitle:@"New Collection…"
                                             action:@selector(newCollection:)
                                              frame:NSMakeRect(cx, 70, 100, 26)];
    [data addSubview:_createCollectionButton];
    cx += 106.0;
    _createContentButton = [self buttonWithTitle:@"New Content…"
                                          action:@selector(newContent:)
                                           frame:NSMakeRect(cx, 70, 96, 26)];
    [data addSubview:_createContentButton];
    cx += 102.0;
    _createVersionButton = [self buttonWithTitle:@"New Version…"
                                          action:@selector(newVersion:)
                                           frame:NSMakeRect(cx, 70, 96, 26)];
    [data addSubview:_createVersionButton];
    cx += 102.0;
    _rollbackContentButton = [self buttonWithTitle:@"Roll Back…"
                                            action:@selector(rollBackContent:)
                                             frame:NSMakeRect(cx, 70, 80, 26)];
    [data addSubview:_rollbackContentButton];
    cx += 86.0;
    _setContentStateButton = [self buttonWithTitle:@"Set State…"
                                            action:@selector(setContentState:)
                                             frame:NSMakeRect(cx, 70, 80, 26)];
    [data addSubview:_setContentStateButton];
    cx += 86.0;
    _deleteContentButton = [self buttonWithTitle:@"Delete Content…"
                                          action:@selector(deleteContent:)
                                           frame:NSMakeRect(cx, 70, 106, 26)];
    [data addSubview:_deleteContentButton];
    cx += 112.0;
    _runGCButton = [self buttonWithTitle:@"Run GC…"
                                  action:@selector(runGC:)
                                   frame:NSMakeRect(cx, 70, 78, 26)];
    [data addSubview:_runGCButton];

    _statusField = [NSTextField labelWithString:@""];
    [_statusField setFont:[NSFont systemFontOfSize:11]];
    [_statusField setTextColor:[NSColor secondaryLabelColor]];
    [[_statusField cell] setWraps:YES];
    [_statusField setFrame:NSMakeRect(16, 40, 1088, 28)];
    [data addSubview:_statusField];

    _dataView = data;
    [root addSubview:data];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self reloadStorage];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    // Health polls while the lens is on screen (the state line's
    // freshness); no polling — and no network — while it is not.
    if (self.healthTimer == nil) {
        self.healthTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                              target:self
                                                            selector:@selector(refreshServiceState)
                                                            userInfo:nil
                                                             repeats:YES];
    }
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    [self.healthTimer invalidate];
    self.healthTimer = nil;
}

#pragma mark - Pairing (§5.5)

- (IBAction)savePairingToken:(id)sender {
    NSString *token = [self.pairTokenField stringValue];
    NSError *error = nil;
    if (![self.cloudClient saveOperatorToken:token error:&error]) {
        [self.pairStatusField setStringValue:[NSString stringWithFormat:
            @"Not saved: %@", (error != nil) ? error.localizedDescription : @"unknown error"]];
        return;
    }
    [self.pairTokenField setStringValue:@""];
    [self.pairStatusField setStringValue:@""];
    [self reloadStorage];
}

#pragma mark - Loading

- (void)reloadStorage {
    BOOL paired = [CloudServiceClient hasOperatorToken];
    [self.pairingView setHidden:paired];
    [self.dataView setHidden:!paired];
    if (!paired) {
        return;
    }
    [self refreshServiceState];
    [self refreshBackends];
    __weak StorageViewController *weakSelf = self;
    [self.cloudClient fetchTenantsWithCompletion:^(NSArray<CloudTenant *> *tenants, NSError *error) {
        if (tenants == nil) {
            weakSelf.tenants = @[];
            [weakSelf.tenantTable reloadData];
            [weakSelf selectTenant:nil];
            if (weakSelf.lastHealth != nil) {
                // The service answers health but tenants failed — say
                // so; a stopped service already reads Stopped above.
                [weakSelf.statusField setStringValue:[NSString stringWithFormat:
                    @"Tenants could not be loaded: %@", error.localizedDescription]];
            }
            return;
        }
        weakSelf.tenants = tenants;
        [weakSelf.tenantTable reloadData];
        CloudTenant *selection = nil;
        if (weakSelf.selectedTenant != nil) {
            for (CloudTenant *tenant in tenants) {
                if (tenant.tenantID == weakSelf.selectedTenant.tenantID) {
                    selection = tenant;
                    break;
                }
            }
        }
        if (selection == nil && [tenants count] > 0) {
            selection = tenants[0];
        }
        if (selection != nil) {
            [weakSelf.tenantTable selectRowIndexes:[NSIndexSet indexSetWithIndex:[tenants indexOfObject:selection]]
                               byExtendingSelection:NO];
        }
        [weakSelf selectTenant:selection];
    }];
}

- (void)refreshBackends {
    __weak StorageViewController *weakSelf = self;
    [self.cloudClient fetchBackendsWithCompletion:^(NSArray<NSDictionary *> *backends, NSError *error) {
        if (backends != nil) {
            weakSelf.backends = backends;
        }
    }];
}

- (void)selectTenant:(CloudTenant *)tenant {
    self.selectedTenant = tenant;
    [self refreshActionButtons];
    if (tenant == nil) {
        [self.tenantDetailField setStringValue:@"No tenant selected"];
        self.buckets = @[];
        self.logins = @[];
        self.auditEntries = @[];
        self.collections = @[];
        self.contentItems = @[];
        self.contentVersions = @[];
        [self.dedupField setStringValue:@""];
        [self.bucketTable reloadData];
        [self.loginTable reloadData];
        [self.auditTable reloadData];
        [self.collectionTable reloadData];
        [self.contentTable reloadData];
        [self.versionTable reloadData];
        return;
    }
    [self.tenantDetailField setStringValue:[NSString stringWithFormat:
        @"%@ — %@ · state: %@ · used %@ · quota %@",
        tenant.slug, tenant.displayName, tenant.state,
        [self bytesString:tenant.usedBytes],
        (tenant.quotaBytes >= 0) ? [self bytesString:tenant.quotaBytes] : @"service default"]];
    __weak StorageViewController *weakSelf = self;
    int64_t tenantID = tenant.tenantID;
    [self.cloudClient fetchBucketsForTenantID:tenantID
                                   completion:^(NSArray<CloudBucket *> *buckets, NSError *error) {
        if (weakSelf.selectedTenant == nil || weakSelf.selectedTenant.tenantID != tenantID) {
            return;
        }
        weakSelf.buckets = (buckets != nil) ? buckets : @[];
        [weakSelf.bucketTable reloadData];
        [weakSelf refreshActionButtons];
        if (buckets == nil && weakSelf.lastHealth != nil) {
            [weakSelf.statusField setStringValue:[NSString stringWithFormat:
                @"Buckets could not be loaded: %@", error.localizedDescription]];
        }
    }];
    [self.cloudClient fetchLoginsForTenantID:tenantID
                                  completion:^(NSArray<CloudLogin *> *logins, NSError *error) {
        if (weakSelf.selectedTenant == nil || weakSelf.selectedTenant.tenantID != tenantID) {
            return;
        }
        weakSelf.logins = (logins != nil) ? logins : @[];
        [weakSelf.loginTable reloadData];
        [weakSelf refreshActionButtons];
    }];
    [self.cloudClient fetchAuditForTenantID:tenantID
                                 completion:^(NSArray<CloudAuditEntry *> *entries, NSError *error) {
        if (weakSelf.selectedTenant == nil || weakSelf.selectedTenant.tenantID != tenantID) {
            return;
        }
        weakSelf.auditEntries = (entries != nil) ? entries : @[];
        [weakSelf.auditTable reloadData];
    }];
    [self.cloudClient fetchUsageForTenantID:tenantID
                                 completion:^(NSDictionary *usage, NSError *error) {
        if (usage == nil || weakSelf.selectedTenant == nil || weakSelf.selectedTenant.tenantID != tenantID) {
            return;
        }
        // The /usage payload is rendered with its own figures when it
        // carries them (envelope≠payload); absent keys leave the
        // list-row figures standing.
        [weakSelf renderDedupFromUsage:usage];
        id used = usage[@"used_bytes"];
        id quota = usage[@"quota_bytes"];
        if ([used isKindOfClass:[NSNumber class]]) {
            NSString *quotaText = ([quota isKindOfClass:[NSNumber class]] && [quota longLongValue] >= 0)
                ? [weakSelf bytesString:[quota longLongValue]] : @"service default";
            [weakSelf.tenantDetailField setStringValue:[NSString stringWithFormat:
                @"%@ — %@ · state: %@ · used %@ · quota %@",
                tenant.slug, tenant.displayName, tenant.state,
                [weakSelf bytesString:[used longLongValue]], quotaText]];
        }
    }];
    [self refreshContent];
}

#pragma mark - Content loading (§13.5/§13.6; SF-T12j)

// Renders the §13.6 dedup figures from a usage payload's dedup block
// (figures uncompressed, envelope≠payload). No block — no line: the
// label clears rather than showing invented numbers.
- (void)renderDedupFromUsage:(NSDictionary *)usage {
    id dedup = usage[@"dedup"];
    if (![dedup isKindOfClass:[NSDictionary class]]) {
        [self.dedupField setStringValue:@""];
        return;
    }
    [self renderDedup:dedup];
}

- (void)renderDedup:(NSDictionary *)dedup {
    int64_t logical = [dedup[@"logical_bytes"] isKindOfClass:[NSNumber class]]
        ? [dedup[@"logical_bytes"] longLongValue] : 0;
    int64_t physical = [dedup[@"physical_bytes"] isKindOfClass:[NSNumber class]]
        ? [dedup[@"physical_bytes"] longLongValue] : 0;
    int64_t saved = [dedup[@"bytes_saved"] isKindOfClass:[NSNumber class]]
        ? [dedup[@"bytes_saved"] longLongValue] : 0;
    double ratio = [dedup[@"dedup_ratio"] isKindOfClass:[NSNumber class]]
        ? [dedup[@"dedup_ratio"] doubleValue] : 1.0;
    int64_t blobCount = [dedup[@"blob_count"] isKindOfClass:[NSNumber class]]
        ? [dedup[@"blob_count"] longLongValue] : 0;
    int64_t refCount = [dedup[@"reference_count"] isKindOfClass:[NSNumber class]]
        ? [dedup[@"reference_count"] longLongValue] : 0;
    [self.dedupField setStringValue:[NSString stringWithFormat:
        @"Dedup — logical %@ · physical %@ · saved %@ · ratio %.2f× · %lld blob(s), %lld ref(s)",
        [self bytesString:logical], [self bytesString:physical],
        [self bytesString:saved], ratio, (long long)blobCount, (long long)refCount]];
}

// Reloads the Content section for the selected tenant: collections,
// the item list (filtered by the selected collection, if any), and
// the dedup figures. Versions reload with the item selection.
- (void)refreshContent {
    CloudTenant *tenant = self.selectedTenant;
    if (tenant == nil) {
        return;
    }
    int64_t tenantID = tenant.tenantID;
    __weak StorageViewController *weakSelf = self;
    [self.cloudClient fetchCollectionsForTenantID:tenantID
                                       completion:^(NSArray<CloudCollection *> *collections, NSError *error) {
        if (weakSelf.selectedTenant == nil || weakSelf.selectedTenant.tenantID != tenantID) {
            return;
        }
        weakSelf.collections = (collections != nil) ? collections : @[];
        [weakSelf.collectionTable reloadData];
        [weakSelf refreshActionButtons];
        if (collections == nil && weakSelf.lastHealth != nil) {
            [weakSelf.statusField setStringValue:[NSString stringWithFormat:
                @"Collections could not be loaded: %@", error.localizedDescription]];
        }
    }];
    [self refreshContentItems];
    [self.cloudClient fetchDedupForTenantID:tenantID
                                 completion:^(NSDictionary *dedup, NSError *error) {
        if (weakSelf.selectedTenant == nil || weakSelf.selectedTenant.tenantID != tenantID) {
            return;
        }
        if (dedup != nil) {
            [weakSelf renderDedup:dedup];
        }
    }];
}

- (void)refreshContentItems {
    CloudTenant *tenant = self.selectedTenant;
    if (tenant == nil) {
        return;
    }
    int64_t tenantID = tenant.tenantID;
    CloudCollection *collection = [self selectedCollection];
    int64_t collectionID = (collection != nil) ? collection.collectionID : 0;
    __weak StorageViewController *weakSelf = self;
    [self.cloudClient fetchContentForTenantID:tenantID
                                 collectionID:collectionID
                                         kind:nil
                                        state:nil
                                        query:nil
                                   completion:^(NSArray<CloudContentItem *> *items, NSError *error) {
        if (weakSelf.selectedTenant == nil || weakSelf.selectedTenant.tenantID != tenantID) {
            return;
        }
        weakSelf.contentItems = (items != nil) ? items : @[];
        weakSelf.contentVersions = @[];
        [weakSelf.contentTable reloadData];
        [weakSelf.versionTable reloadData];
        // reloadData keeps the row selection: restore the selected
        // item's versions rather than leaving the pane cleared.
        [weakSelf refreshVersionsForSelectedItem];
        [weakSelf refreshActionButtons];
        if (items == nil && weakSelf.lastHealth != nil) {
            [weakSelf.statusField setStringValue:[NSString stringWithFormat:
                @"Content could not be loaded: %@", error.localizedDescription]];
        }
    }];
}

- (void)refreshVersionsForSelectedItem {
    CloudTenant *tenant = self.selectedTenant;
    CloudContentItem *item = [self selectedContentItem];
    if (tenant == nil || item == nil) {
        self.contentVersions = @[];
        [self.versionTable reloadData];
        return;
    }
    int64_t tenantID = tenant.tenantID;
    int64_t contentID = item.contentID;
    __weak StorageViewController *weakSelf = self;
    [self.cloudClient fetchVersionsForTenantID:tenantID
                                     contentID:contentID
                                    completion:^(NSArray<CloudContentVersion *> *versions, NSError *error) {
        CloudContentItem *current = [weakSelf selectedContentItem];
        if (current == nil || current.contentID != contentID) {
            return;
        }
        weakSelf.contentVersions = (versions != nil) ? versions : @[];
        [weakSelf.versionTable reloadData];
        [weakSelf refreshActionButtons];
    }];
}

- (CloudCollection *)selectedCollection {
    NSInteger row = [self.collectionTable selectedRow];
    if (row < 0 || row >= (NSInteger)[self.collections count]) {
        return nil;
    }
    return self.collections[(NSUInteger)row];
}

- (CloudContentItem *)selectedContentItem {
    NSInteger row = [self.contentTable selectedRow];
    if (row < 0 || row >= (NSInteger)[self.contentItems count]) {
        return nil;
    }
    return self.contentItems[(NSUInteger)row];
}

- (CloudContentVersion *)selectedContentVersion {
    NSInteger row = [self.versionTable selectedRow];
    if (row < 0 || row >= (NSInteger)[self.contentVersions count]) {
        return nil;
    }
    return self.contentVersions[(NSUInteger)row];
}

- (NSString *)collectionNameForID:(int64_t)collectionID {
    for (CloudCollection *collection in self.collections) {
        if (collection.collectionID == collectionID) {
            return collection.name;
        }
    }
    return @"—";
}

- (NSString *)shortSHA:(NSString *)sha256Hex {
    if ([sha256Hex length] == 0) {
        return @"—";
    }
    return [sha256Hex substringToIndex:MIN([sha256Hex length], (NSUInteger)12)];
}

- (NSString *)bytesString:(int64_t)bytes {
    return [NSByteCountFormatter stringFromByteCount:bytes
                                          countStyle:NSByteCountFormatterCountStyleFile];
}

- (CloudLogin *)selectedLogin {
    NSInteger row = [self.loginTable selectedRow];
    if (row < 0 || row >= (NSInteger)[self.logins count]) {
        return nil;
    }
    return self.logins[(NSUInteger)row];
}

- (CloudBucket *)selectedBucket {
    NSInteger row = [self.bucketTable selectedRow];
    if (row < 0 || row >= (NSInteger)[self.buckets count]) {
        return nil;
    }
    return self.buckets[(NSUInteger)row];
}

- (void)refreshActionButtons {
    BOOL hasTenant = (self.selectedTenant != nil);
    BOOL hasLogin = ([self selectedLogin] != nil);
    BOOL hasBucket = ([self selectedBucket] != nil);
    [self.closeTenantButton setEnabled:hasTenant];
    [self.createLoginButton setEnabled:hasTenant];
    [self.createBucketButton setEnabled:hasTenant];
    [self.setPasswordButton setEnabled:hasLogin];
    [self.issueResetButton setEnabled:hasLogin];
    [self.deleteLoginButton setEnabled:hasLogin];
    [self.deleteBucketButton setEnabled:hasBucket];
    BOOL hasItem = ([self selectedContentItem] != nil);
    BOOL hasVersion = ([self selectedContentVersion] != nil);
    [self.createCollectionButton setEnabled:hasTenant];
    [self.createContentButton setEnabled:hasTenant];
    [self.runGCButton setEnabled:hasTenant];
    [self.createVersionButton setEnabled:hasItem];
    [self.setContentStateButton setEnabled:hasItem];
    [self.deleteContentButton setEnabled:hasItem];
    [self.rollbackContentButton setEnabled:(hasItem && hasVersion)];
}

#pragma mark - Service state + control (NSTask over the bundled helper)

- (nullable NSString *)helperPath {
    return [[NSBundle mainBundle] pathForAuxiliaryExecutable:@"SnowfellStorageService"];
}

- (void)refreshServiceState {
    __weak StorageViewController *weakSelf = self;
    [self.cloudClient fetchHealthWithCompletion:^(CloudServiceHealth *health, NSError *error) {
        weakSelf.lastHealth = health;
        [weakSelf updateServiceControls];
    }];
}

- (void)updateServiceControls {
    NSInteger port = [CloudServiceClient configuredPort];
    NSString *helperPath = [self helperPath];
    BOOL helperAbsent = (helperPath == nil);
    BOOL oursRunning = (self.serviceTask != nil && [self.serviceTask isRunning]);
    if (self.lastHealth != nil) {
        CloudServiceHealth *health = self.lastHealth;
        NSMutableString *line = [NSMutableString stringWithFormat:
            @"Running on 127.0.0.1:%ld — v%@ · bind %@ · %ld tenant(s) · uptime %lld s",
            (long)port, ([health.version length] > 0) ? health.version : @"?",
            ([health.bind length] > 0) ? health.bind : @"?", (long)health.tenantCount,
            (long long)health.uptimeSeconds];
        if (![health.bind isEqualToString:@"127.0.0.1"] && [health.bind length] > 0) {
            [line appendString:@" · WARNING: the bind is not loopback — a LAN bind is an owner config act (design §2.3)"];
        }
        if (!oursRunning) {
            [line appendString:@" · Started outside Snowfell — Stop applies only to a service this lens started"];
        }
        [self.serviceStateField setStringValue:line];
        [self.startServiceButton setEnabled:NO];
        [self.stopServiceButton setEnabled:oursRunning];
        return;
    }
    NSMutableString *line = [NSMutableString stringWithFormat:
        @"Stopped — no answer from http://127.0.0.1:%ld/v1/health", (long)port];
    if (helperAbsent) {
        [line appendString:
         @". The bundled helper (SnowfellStorageService) is absent from this build, so Start is "
         @"disabled — source builds may lack the helper until the full bundle assembles at "
         @"packaging (SF-T8); the service can still be run standalone from a terminal."];
    }
    [self.serviceStateField setStringValue:line];
    [self.startServiceButton setEnabled:(!helperAbsent && !oursRunning)];
    [self.stopServiceButton setEnabled:oursRunning];
}

- (IBAction)startService:(id)sender {
    if (self.lastHealth != nil) {
        // Starting a helper the owner already runs (here or
        // standalone) is a no-op success — health answers first (§9).
        [self.statusField setStringValue:@"The service is already running — Start is a no-op."];
        return;
    }
    NSString *helperPath = [self helperPath];
    if (helperPath == nil) {
        [self updateServiceControls];
        return;
    }
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:helperPath];
    [task setArguments:@[]];
    __weak StorageViewController *weakSelf = self;
    [task setTerminationHandler:^(NSTask *finishedTask) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.serviceTask == finishedTask) {
                weakSelf.serviceTask = nil;
            }
            [weakSelf refreshServiceState];
        });
    }];
    self.serviceTask = task;
    [task launch];
    [self.statusField setStringValue:[NSString stringWithFormat:
        @"Service starting (%@) — state follows the health poll.", helperPath]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf refreshServiceState];
        if (weakSelf.lastHealth != nil) {
            [weakSelf reloadStorage];
        }
    });
}

- (IBAction)stopService:(id)sender {
    if (self.serviceTask != nil && [self.serviceTask isRunning]) {
        [self.serviceTask terminate];
        [self.statusField setStringValue:@"Service stop sent to the helper this lens started."];
    }
}

- (IBAction)refresh:(id)sender {
    [self reloadStorage];
}

#pragma mark - Table data source / delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == self.tenantTable) {
        return (NSInteger)[self.tenants count];
    }
    if (tableView == self.bucketTable) {
        return (NSInteger)[self.buckets count];
    }
    if (tableView == self.loginTable) {
        return (NSInteger)[self.logins count];
    }
    if (tableView == self.auditTable) {
        return (NSInteger)[self.auditEntries count];
    }
    if (tableView == self.collectionTable) {
        return (NSInteger)[self.collections count];
    }
    if (tableView == self.contentTable) {
        return (NSInteger)[self.contentItems count];
    }
    if (tableView == self.versionTable) {
        return (NSInteger)[self.contentVersions count];
    }
    return 0;
}

- (id)tableView:(NSTableView *)tableView
objectValueForTableColumn:(NSTableColumn *)tableColumn
            row:(NSInteger)row {
    NSString *identifier = [tableColumn identifier];
    if (tableView == self.tenantTable) {
        CloudTenant *tenant = self.tenants[(NSUInteger)row];
        if ([identifier isEqualToString:@"slug"]) {
            return tenant.slug;
        }
        if ([identifier isEqualToString:@"tname"]) {
            return tenant.displayName;
        }
        if ([identifier isEqualToString:@"tstate"]) {
            return tenant.state;
        }
        if ([identifier isEqualToString:@"tused"]) {
            return [self bytesString:tenant.usedBytes];
        }
        return @"";
    }
    if (tableView == self.bucketTable) {
        CloudBucket *bucket = self.buckets[(NSUInteger)row];
        if ([identifier isEqualToString:@"bname"]) {
            return bucket.name;
        }
        if ([identifier isEqualToString:@"bobjects"]) {
            return [NSString stringWithFormat:@"%lld", (long long)bucket.objectCount];
        }
        if ([identifier isEqualToString:@"bbytes"]) {
            return [self bytesString:bucket.totalBytes];
        }
        if ([identifier isEqualToString:@"bquota"]) {
            return (bucket.quotaBytes >= 0) ? [self bytesString:bucket.quotaBytes] : @"—";
        }
        if ([identifier isEqualToString:@"bbackend"]) {
            return [NSString stringWithFormat:@"#%lld", (long long)bucket.backendID];
        }
        return @"";
    }
    if (tableView == self.loginTable) {
        CloudLogin *login = self.logins[(NSUInteger)row];
        if ([identifier isEqualToString:@"luser"]) {
            return login.username;
        }
        if ([identifier isEqualToString:@"lrole"]) {
            return login.role;
        }
        if ([identifier isEqualToString:@"lstate"]) {
            return login.state;
        }
        if ([identifier isEqualToString:@"llock"]) {
            return login.locked ? @"LOCKED" : @"—";
        }
        if ([identifier isEqualToString:@"llast"]) {
            return (login.lastLoginAt != nil) ? login.lastLoginAt : @"never";
        }
        return @"";
    }
    if (tableView == self.auditTable) {
        CloudAuditEntry *entry = self.auditEntries[(NSUInteger)row];
        if ([identifier isEqualToString:@"ats"]) {
            return entry.ts;
        }
        if ([identifier isEqualToString:@"aactor"]) {
            return entry.actorRef;
        }
        if ([identifier isEqualToString:@"aaction"]) {
            return entry.action;
        }
        if ([identifier isEqualToString:@"aobject"]) {
            return (entry.objectRef != nil) ? entry.objectRef : @"—";
        }
        if ([identifier isEqualToString:@"aresult"]) {
            return entry.result;
        }
        return @"";
    }
    if (tableView == self.collectionTable) {
        CloudCollection *collection = self.collections[(NSUInteger)row];
        if ([identifier isEqualToString:@"cname"]) {
            return collection.name;
        }
        if ([identifier isEqualToString:@"cslug"]) {
            return collection.slug;
        }
        if ([identifier isEqualToString:@"cparent"]) {
            return (collection.parentID > 0)
                ? [self collectionNameForID:collection.parentID] : @"root";
        }
        return @"";
    }
    if (tableView == self.contentTable) {
        CloudContentItem *item = self.contentItems[(NSUInteger)row];
        if ([identifier isEqualToString:@"islug"]) {
            return item.slug;
        }
        if ([identifier isEqualToString:@"ititle"]) {
            return item.title;
        }
        if ([identifier isEqualToString:@"ikind"]) {
            return item.kind;
        }
        if ([identifier isEqualToString:@"istate"]) {
            return item.state;
        }
        if ([identifier isEqualToString:@"iver"]) {
            return (item.currentVersionNo > 0)
                ? [NSString stringWithFormat:@"%lld", (long long)item.currentVersionNo] : @"—";
        }
        if ([identifier isEqualToString:@"isize"]) {
            return [self bytesString:item.currentSizeBytes];
        }
        return @"";
    }
    if (tableView == self.versionTable) {
        CloudContentVersion *version = self.contentVersions[(NSUInteger)row];
        if ([identifier isEqualToString:@"vno"]) {
            return [NSString stringWithFormat:@"%lld", (long long)version.versionNo];
        }
        if ([identifier isEqualToString:@"vsha"]) {
            return [self shortSHA:version.sha256Hex];
        }
        if ([identifier isEqualToString:@"vsize"]) {
            return [self bytesString:version.sizeBytes];
        }
        if ([identifier isEqualToString:@"vnote"]) {
            return (version.note != nil) ? version.note : @"—";
        }
        if ([identifier isEqualToString:@"vcreated"]) {
            return version.createdAt;
        }
        return @"";
    }
    return @"";
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSTableView *table = [notification object];
    if (table == self.tenantTable) {
        NSInteger row = [self.tenantTable selectedRow];
        CloudTenant *tenant = (row >= 0 && row < (NSInteger)[self.tenants count])
            ? self.tenants[(NSUInteger)row] : nil;
        if (tenant != self.selectedTenant) {
            [self selectTenant:tenant];
        }
    } else if (table == self.loginTable || table == self.bucketTable) {
        [self refreshActionButtons];
    } else if (table == self.collectionTable) {
        // Selecting a collection filters the item list (§13.7
        // collection_id); no selection shows the tenant's whole list.
        [self refreshContentItems];
        [self refreshActionButtons];
    } else if (table == self.contentTable) {
        [self refreshVersionsForSelectedItem];
        [self refreshActionButtons];
    } else if (table == self.versionTable) {
        [self refreshActionButtons];
    }
}

#pragma mark - Confirm sheets (access-review form)

- (NSString *)accessReviewTextForEffect:(NSString *)effect {
    return [NSString stringWithFormat:
        @"Destination: %@ (SnowfellStorageService on THIS Mac — the client is loopback-only; "
        @"no other host is reachable by it).\n"
        @"Operator: the Keychain operator token (service %@, account %@), read at call time "
        @"and carried in this one request's Authorization header only.\n"
        @"Effect: %@\n\n"
        @"The service audits the act under actor = operator. Declining sends nothing.",
        [[CloudServiceClient baseURL] absoluteString],
        CloudOperatorKeychainService, CloudOperatorKeychainAccount, effect];
}

- (void)confirmWithMessage:(NSString *)message
                    effect:(NSString *)effect
             confirmTitle:(NSString *)confirmTitle
               completion:(void (^)(BOOL confirmed))completion {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:message];
    [alert setInformativeText:[self accessReviewTextForEffect:effect]];
    [alert addButtonWithTitle:confirmTitle];
    [alert addButtonWithTitle:@"Cancel"];
    NSWindow *window = self.view.window;
    if (window == nil) {
        completion(NO);
        return;
    }
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse result) {
        completion(result == NSAlertFirstButtonReturn);
    }];
}

// A prompt sheet: a small form rides as the alert's accessory view;
// confirming hands the field values to the completion. The sheet's
// informative text is the same access-review block every mutation
// carries, with the target named in the message.
- (void)promptWithMessage:(NSString *)message
                   effect:(NSString *)effect
            confirmTitle:(NSString *)confirmTitle
            accessoryView:(NSView *)accessoryView
               completion:(void (^)(BOOL confirmed))completion {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:message];
    [alert setInformativeText:[self accessReviewTextForEffect:effect]];
    [alert setAccessoryView:accessoryView];
    [alert addButtonWithTitle:confirmTitle];
    [alert addButtonWithTitle:@"Cancel"];
    NSWindow *window = self.view.window;
    if (window == nil) {
        completion(NO);
        return;
    }
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse result) {
        completion(result == NSAlertFirstButtonReturn);
    }];
}

- (NSTextField *)formFieldWithPlaceholder:(NSString *)placeholder
                                    frame:(NSRect)frame
                                   secure:(BOOL)secure {
    NSTextField *field = secure
        ? [[NSSecureTextField alloc] initWithFrame:frame]
        : [[NSTextField alloc] initWithFrame:frame];
    [field setPlaceholderString:placeholder];
    [field setFont:[NSFont systemFontOfSize:12]];
    return field;
}

- (void)reportFailure:(NSString *)what error:(NSError *)error {
    [self.statusField setStringValue:[NSString stringWithFormat:
        @"%@ failed: %@ — nothing further was sent.",
        what, (error != nil) ? error.localizedDescription : @"unknown error"]];
}

#pragma mark - Tenant mutations

- (IBAction)newTenant:(id)sender {
    NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 64)];
    NSTextField *slugField = [self formFieldWithPlaceholder:@"Slug (unique, URL-safe)"
                                                      frame:NSMakeRect(0, 36, 340, 24)
                                                     secure:NO];
    [form addSubview:slugField];
    NSTextField *nameField = [self formFieldWithPlaceholder:@"Display name"
                                                      frame:NSMakeRect(0, 4, 340, 24)
                                                     secure:NO];
    [form addSubview:nameField];
    __weak StorageViewController *weakSelf = self;
    [self promptWithMessage:@"Create a new tenant?"
                     effect:@"POST /v1/tenants provisions the tenant in state active with the "
                            @"service-default quotas (§7.4) unless PATCHed later. A duplicate "
                            @"slug is refused by the service (409 conflict)."
               confirmTitle:@"Create Tenant"
              accessoryView:form
                 completion:^(BOOL confirmed) {
        if (!confirmed) {
            return;
        }
        NSString *slug = [[slugField stringValue] stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *name = [[nameField stringValue] stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([slug length] == 0) {
            [weakSelf.statusField setStringValue:@"New tenant needs a slug; nothing was sent."];
            return;
        }
        [weakSelf.cloudClient createTenantWithSlug:slug
                                       displayName:([name length] > 0) ? name : slug
                                        completion:^(CloudTenant *tenant, NSError *error) {
            if (tenant == nil) {
                [weakSelf reportFailure:@"Create tenant" error:error];
                return;
            }
            weakSelf.selectedTenant = tenant;
            [weakSelf.statusField setStringValue:[NSString stringWithFormat:
                @"Tenant %@ (#%lld) created.", tenant.slug, (long long)tenant.tenantID]];
            [weakSelf reloadStorage];
        }];
    }];
}

- (IBAction)closeTenant:(id)sender {
    CloudTenant *tenant = self.selectedTenant;
    if (tenant == nil) {
        return;
    }
    __weak StorageViewController *weakSelf = self;
    [self confirmWithMessage:[NSString stringWithFormat:@"Close tenant %@?", tenant.slug]
                      effect:[NSString stringWithFormat:
                              @"DELETE /v1/tenants/%lld closes tenant %@ (%@): state → closed, "
                              @"which blocks everything except operator reads (§3.1). Tenants "
                              @"are never hard-deleted with data (§8) — close is the delete "
                              @"this API offers, and it is audited.",
                              (long long)tenant.tenantID, tenant.slug, tenant.displayName]
              confirmTitle:@"Close Tenant"
                completion:^(BOOL confirmed) {
        if (!confirmed) {
            return;
        }
        [weakSelf.cloudClient closeTenantWithID:tenant.tenantID
                                     completion:^(BOOL success, NSError *error) {
            if (!success) {
                [weakSelf reportFailure:@"Close tenant" error:error];
                return;
            }
            [weakSelf.statusField setStringValue:[NSString stringWithFormat:
                @"Tenant %@ closed.", tenant.slug]];
            [weakSelf reloadStorage];
        }];
    }];
}

#pragma mark - Login mutations

- (IBAction)newLogin:(id)sender {
    CloudTenant *tenant = self.selectedTenant;
    if (tenant == nil) {
        return;
    }
    NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 128)];
    NSTextField *usernameField = [self formFieldWithPlaceholder:@"Username (unique in the tenant)"
                                                          frame:NSMakeRect(0, 100, 340, 24)
                                                         secure:NO];
    [form addSubview:usernameField];
    NSTextField *displayField = [self formFieldWithPlaceholder:@"Display name"
                                                         frame:NSMakeRect(0, 68, 340, 24)
                                                        secure:NO];
    [form addSubview:displayField];
    NSPopUpButton *rolePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 36, 340, 24) pullsDown:NO];
    [rolePopup addItemsWithTitles:@[@"tenant_user", @"tenant_admin"]];
    [form addSubview:rolePopup];
    NSTextField *passwordField = [self formFieldWithPlaceholder:@"Initial password (hashed by the service, never echoed)"
                                                          frame:NSMakeRect(0, 4, 340, 24)
                                                         secure:YES];
    [form addSubview:passwordField];
    __weak StorageViewController *weakSelf = self;
    [self promptWithMessage:[NSString stringWithFormat:@"Create a login in tenant %@?", tenant.slug]
                     effect:[NSString stringWithFormat:
                             @"POST /v1/tenants/%lld/logins creates the login with the initial "
                             @"password set in the same call (§5.2) — the service hashes it "
                             @"immediately (PBKDF2, §5.1) and never echoes it. A duplicate "
                             @"username in this tenant is refused (409).",
                             (long long)tenant.tenantID]
               confirmTitle:@"Create Login"
              accessoryView:form
                 completion:^(BOOL confirmed) {
        if (!confirmed) {
            return;
        }
        NSString *username = [[usernameField stringValue] stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *password = [passwordField stringValue];
        if ([username length] == 0 || [password length] == 0) {
            [weakSelf.statusField setStringValue:@"New login needs a username and an initial password; nothing was sent."];
            return;
        }
        NSString *display = [[displayField stringValue] stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [weakSelf.cloudClient createLoginForTenantID:tenant.tenantID
                                            username:username
                                         displayName:([display length] > 0) ? display : username
                                                role:[rolePopup titleOfSelectedItem]
                                            password:password
                                          completion:^(CloudLogin *login, NSError *error) {
            if (login == nil) {
                [weakSelf reportFailure:@"Create login" error:error];
                return;
            }
            [weakSelf.statusField setStringValue:[NSString stringWithFormat:
                @"Login %@ created in tenant %@ (role %@).", login.username, tenant.slug, login.role]];
            [weakSelf selectTenant:weakSelf.selectedTenant];
        }];
    }];
}

- (IBAction)setPassword:(id)sender {
    CloudTenant *tenant = self.selectedTenant;
    CloudLogin *login = [self selectedLogin];
    if (tenant == nil || login == nil) {
        return;
    }
    NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 32)];
    NSTextField *passwordField = [self formFieldWithPlaceholder:@"New password"
                                                          frame:NSMakeRect(0, 4, 340, 24)
                                                         secure:YES];
    [form addSubview:passwordField];
    __weak StorageViewController *weakSelf = self;
    [self promptWithMessage:[NSString stringWithFormat:@"Set the password for %@ (tenant %@)?",
                             login.username, tenant.slug]
                     effect:[NSString stringWithFormat:
                             @"POST /v1/tenants/%lld/logins/%lld/password is the ADMIN SET "
                             @"(§5.2): the service replaces the credential without the old "
                             @"password, audits it as login.password_set_by_admin, and revokes "
                             @"the login's existing sessions in the same act.",
                             (long long)tenant.tenantID, (long long)login.loginID]
               confirmTitle:@"Set Password"
              accessoryView:form
                 completion:^(BOOL confirmed) {
        if (!confirmed) {
            return;
        }
        NSString *password = [passwordField stringValue];
        if ([password length] == 0) {
            [weakSelf.statusField setStringValue:@"Set Password needs a non-empty password; nothing was sent."];
            return;
        }
        [weakSelf.cloudClient setPasswordForTenantID:tenant.tenantID
                                             loginID:login.loginID
                                         newPassword:password
                                          completion:^(BOOL success, NSError *error) {
            if (!success) {
                [weakSelf reportFailure:@"Set password" error:error];
                return;
            }
            [weakSelf.statusField setStringValue:[NSString stringWithFormat:
                @"Password set for %@ — its existing sessions were revoked by the service.",
                login.username]];
            [weakSelf selectTenant:weakSelf.selectedTenant];
        }];
    }];
}

- (IBAction)issueReset:(id)sender {
    CloudTenant *tenant = self.selectedTenant;
    CloudLogin *login = [self selectedLogin];
    if (tenant == nil || login == nil) {
        return;
    }
    __weak StorageViewController *weakSelf = self;
    [self confirmWithMessage:[NSString stringWithFormat:@"Issue a password reset for %@ (tenant %@)?",
                              login.username, tenant.slug]
                      effect:[NSString stringWithFormat:
                              @"POST /v1/tenants/%lld/logins/%lld/password-resets creates a "
                              @"single-use reset (1-hour expiry, §5.4). The plaintext token is "
                              @"returned ONCE, in the response to this call — you deliver it to "
                              @"the user out of band; there is no email lane in v1. The service "
                              @"stores only its SHA-256 digest.",
                              (long long)tenant.tenantID, (long long)login.loginID]
              confirmTitle:@"Issue Reset"
                completion:^(BOOL confirmed) {
        if (!confirmed) {
            return;
        }
        [weakSelf.cloudClient issuePasswordResetForTenantID:tenant.tenantID
                                                    loginID:login.loginID
                                                 completion:^(NSString *resetToken, NSError *error) {
            if (resetToken == nil) {
                [weakSelf reportFailure:@"Issue reset" error:error];
                return;
            }
            [weakSelf presentResetToken:resetToken forLogin:login];
            [weakSelf selectTenant:weakSelf.selectedTenant];
        }];
    }];
}

// The reset token exists in plaintext exactly once — here. It is
// shown in a selectable field for the owner's out-of-band delivery
// and kept in no property, file, or log (§5.4).
- (void)presentResetToken:(NSString *)resetToken forLogin:(CloudLogin *)login {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:[NSString stringWithFormat:@"Reset token for %@ — shown once", login.username]];
    [alert setInformativeText:
     @"Deliver this token to the user out of band. It completes at "
     @"POST /v1/auth/password-reset/complete within 1 hour, is single-use, and completing it "
     @"revokes the login's sessions. The service stores only its SHA-256 digest; this alert is "
     @"the only place the plaintext exists."];
    NSTextField *tokenField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 420, 24)];
    [tokenField setStringValue:resetToken];
    [tokenField setEditable:NO];
    [tokenField setSelectable:YES];
    [tokenField setFont:[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular]];
    [alert setAccessoryView:tokenField];
    [alert addButtonWithTitle:@"Done"];
    NSWindow *window = self.view.window;
    if (window != nil) {
        [alert beginSheetModalForWindow:window completionHandler:nil];
    }
}

- (IBAction)deleteLogin:(id)sender {
    CloudTenant *tenant = self.selectedTenant;
    CloudLogin *login = [self selectedLogin];
    if (tenant == nil || login == nil) {
        return;
    }
    __weak StorageViewController *weakSelf = self;
    [self confirmWithMessage:[NSString stringWithFormat:@"Delete login %@ (tenant %@)?",
                              login.username, tenant.slug]
                      effect:[NSString stringWithFormat:
                              @"DELETE /v1/tenants/%lld/logins/%lld hard-deletes the login with "
                              @"its credentials, tokens, and resets (§5.2), audited. The service "
                              @"refuses (409) deleting the tenant's last active admin.",
                              (long long)tenant.tenantID, (long long)login.loginID]
              confirmTitle:@"Delete Login"
                completion:^(BOOL confirmed) {
        if (!confirmed) {
            return;
        }
        [weakSelf.cloudClient deleteLoginForTenantID:tenant.tenantID
                                             loginID:login.loginID
                                          completion:^(BOOL success, NSError *error) {
            if (!success) {
                [weakSelf reportFailure:@"Delete login" error:error];
                return;
            }
            [weakSelf.statusField setStringValue:[NSString stringWithFormat:
                @"Login %@ deleted from tenant %@.", login.username, tenant.slug]];
            [weakSelf selectTenant:weakSelf.selectedTenant];
        }];
    }];
}

#pragma mark - Bucket mutations

- (IBAction)newBucket:(id)sender {
    CloudTenant *tenant = self.selectedTenant;
    if (tenant == nil) {
        return;
    }
    NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 64)];
    NSTextField *nameField = [self formFieldWithPlaceholder:@"Bucket name (unique in the tenant)"
                                                      frame:NSMakeRect(0, 36, 340, 24)
                                                     secure:NO];
    [form addSubview:nameField];
    NSPopUpButton *backendPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 4, 340, 24) pullsDown:NO];
    NSMenuItem *defaultItem = [[NSMenuItem alloc] initWithTitle:@"Service default backend"
                                                         action:nil
                                                  keyEquivalent:@""];
    [defaultItem setRepresentedObject:@(0)];
    [[backendPopup menu] addItem:defaultItem];
    for (NSDictionary *backend in self.backends) {
        id backendID = backend[@"id"];
        id backendName = backend[@"name"];
        if (![backendID isKindOfClass:[NSNumber class]]) {
            continue;
        }
        NSString *title = [NSString stringWithFormat:@"%@ (#%@)",
                           [backendName isKindOfClass:[NSString class]] ? backendName : @"backend",
                           backendID];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        [item setRepresentedObject:backendID];
        [[backendPopup menu] addItem:item];
    }
    [form addSubview:backendPopup];
    __weak StorageViewController *weakSelf = self;
    [self promptWithMessage:[NSString stringWithFormat:@"Create a bucket in tenant %@?", tenant.slug]
                     effect:[NSString stringWithFormat:
                             @"POST /v1/buckets creates the bucket in tenant %@ bound to the "
                             @"chosen backend (the service default is its first active "
                             @"backend, §8). A duplicate bucket name in the tenant is refused "
                             @"(409); the tenant's bucket quota (§7.4) applies.",
                             tenant.slug]
               confirmTitle:@"Create Bucket"
              accessoryView:form
                 completion:^(BOOL confirmed) {
        if (!confirmed) {
            return;
        }
        NSString *name = [[nameField stringValue] stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([name length] == 0) {
            [weakSelf.statusField setStringValue:@"New bucket needs a name; nothing was sent."];
            return;
        }
        NSNumber *backendID = [[backendPopup selectedItem] representedObject];
        [weakSelf.cloudClient createBucketForTenantID:tenant.tenantID
                                                 name:name
                                            backendID:(backendID != nil) ? [backendID longLongValue] : 0
                                           completion:^(CloudBucket *bucket, NSError *error) {
            if (bucket == nil) {
                [weakSelf reportFailure:@"Create bucket" error:error];
                return;
            }
            [weakSelf.statusField setStringValue:[NSString stringWithFormat:
                @"Bucket %@ created in tenant %@ (backend #%lld).",
                bucket.name, tenant.slug, (long long)bucket.backendID]];
            [weakSelf selectTenant:weakSelf.selectedTenant];
        }];
    }];
}

- (IBAction)deleteBucket:(id)sender {
    CloudTenant *tenant = self.selectedTenant;
    CloudBucket *bucket = [self selectedBucket];
    if (tenant == nil || bucket == nil) {
        return;
    }
    __weak StorageViewController *weakSelf = self;
    [self confirmWithMessage:[NSString stringWithFormat:@"Delete bucket %@ (tenant %@)?",
                              bucket.name, tenant.slug]
                      effect:[NSString stringWithFormat:
                              @"DELETE /v1/buckets/%@ deletes the bucket in tenant %@. The "
                              @"service refuses (409) a bucket that still holds objects (§8) — "
                              @"empty it first. The delete is audited.",
                              bucket.name, tenant.slug]
              confirmTitle:@"Delete Bucket"
                completion:^(BOOL confirmed) {
        if (!confirmed) {
            return;
        }
        [weakSelf.cloudClient deleteBucketForTenantID:tenant.tenantID
                                                 name:bucket.name
                                           completion:^(BOOL success, NSError *error) {
            if (!success) {
                [weakSelf reportFailure:@"Delete bucket" error:error];
                return;
            }
            [weakSelf.statusField setStringValue:[NSString stringWithFormat:
                @"Bucket %@ deleted from tenant %@.", bucket.name, tenant.slug]];
            [weakSelf selectTenant:weakSelf.selectedTenant];
        }];
    }];
}

#pragma mark - Content mutations (§13.5/§13.7; SF-T12j)

// A collection picker for the prompt forms: "Root" (id 0) first, then
// the tenant's collections by name. The chosen id rides the selected
// item's representedObject, the newBucket backend-picker pattern.
- (NSPopUpButton *)collectionPopupWithFrame:(NSRect)frame selectedID:(int64_t)selectedID {
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:frame pullsDown:NO];
    NSMenuItem *rootItem = [[NSMenuItem alloc] initWithTitle:@"Root (no collection)"
                                                      action:nil
                                               keyEquivalent:@""];
    [rootItem setRepresentedObject:@(0)];
    [[popup menu] addItem:rootItem];
    for (CloudCollection *collection in self.collections) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:
                            [NSString stringWithFormat:@"%@ (%@)", collection.name, collection.slug]
                                                      action:nil
                                               keyEquivalent:@""];
        [item setRepresentedObject:@(collection.collectionID)];
        [[popup menu] addItem:item];
        if (collection.collectionID == selectedID) {
            [popup selectItem:item];
        }
    }
    return popup;
}

- (IBAction)newCollection:(id)sender {
    CloudTenant *tenant = self.selectedTenant;
    if (tenant == nil) {
        return;
    }
    NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 96)];
    NSTextField *nameField = [self formFieldWithPlaceholder:@"Collection name"
                                                      frame:NSMakeRect(0, 68, 340, 24)
                                                     secure:NO];
    [form addSubview:nameField];
    NSTextField *slugField = [self formFieldWithPlaceholder:@"Slug (unique in the tenant)"
                                                      frame:NSMakeRect(0, 36, 340, 24)
                                                     secure:NO];
    [form addSubview:slugField];
    NSPopUpButton *parentPopup = [self collectionPopupWithFrame:NSMakeRect(0, 4, 340, 24)
                                                     selectedID:0];
    [form addSubview:parentPopup];
    __weak StorageViewController *weakSelf = self;
    [self promptWithMessage:[NSString stringWithFormat:@"Create a collection in tenant %@?", tenant.slug]
                     effect:[NSString stringWithFormat:
                             @"POST /v1/collections creates the structure row in tenant %@ "
                             @"(§13.5) under the chosen parent (Root when none). A duplicate "
                             @"slug in the tenant is refused (409). Collections hold no "
                             @"payload bytes — items reference blobs (§13.2).",
                             tenant.slug]
               confirmTitle:@"Create Collection"
              accessoryView:form
                 completion:^(BOOL confirmed) {
        if (!confirmed) {
            return;
        }
        NSString *name = [[nameField stringValue] stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *slug = [[slugField stringValue] stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([name length] == 0 || [slug length] == 0) {
            [weakSelf.statusField setStringValue:@"New collection needs a name and a slug; nothing was sent."];
            return;
        }
        NSNumber *parentID = [[parentPopup selectedItem] representedObject];
        [weakSelf.cloudClient createCollectionForTenantID:tenant.tenantID
                                                     name:name
                                                     slug:slug
                                                 parentID:(parentID != nil) ? [parentID longLongValue] : 0
                                               completion:^(CloudCollection *collection, NSError *error) {
            if (collection == nil) {
                [weakSelf reportFailure:@"Create collection" error:error];
                return;
            }
            [weakSelf.statusField setStringValue:[NSString stringWithFormat:
                @"Collection %@ (%@) created in tenant %@.",
                collection.name, collection.slug, tenant.slug]];
            [weakSelf refreshContent];
        }];
    }];
}

- (IBAction)newContent:(id)sender {
    CloudTenant *tenant = self.selectedTenant;
    if (tenant == nil) {
        return;
    }
    NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 160)];
    NSTextField *slugField = [self formFieldWithPlaceholder:@"Slug (unique in the tenant)"
                                                      frame:NSMakeRect(0, 132, 340, 24)
                                                     secure:NO];
    [form addSubview:slugField];
    NSTextField *titleField = [self formFieldWithPlaceholder:@"Title"
                                                       frame:NSMakeRect(0, 100, 340, 24)
                                                      secure:NO];
    [form addSubview:titleField];
    NSTextField *kindField = [self formFieldWithPlaceholder:@"Kind (text / media / document / data — free text)"
                                                      frame:NSMakeRect(0, 68, 340, 24)
                                                     secure:NO];
    [kindField setStringValue:@"text"];
    [form addSubview:kindField];
    NSPopUpButton *collectionPopup = [self collectionPopupWithFrame:NSMakeRect(0, 36, 340, 24)
                                                         selectedID:0];
    [form addSubview:collectionPopup];
    NSTextField *blobField = [self formFieldWithPlaceholder:@"Blob id (already uploaded via the API)"
                                                      frame:NSMakeRect(0, 4, 340, 24)
                                                     secure:NO];
    [form addSubview:blobField];
    __weak StorageViewController *weakSelf = self;
    [self promptWithMessage:[NSString stringWithFormat:@"Create content in tenant %@?", tenant.slug]
                     effect:[NSString stringWithFormat:
                             @"POST /v1/content creates the item AND version 1 in one "
                             @"transaction (§13.7), referencing the named blob — no bytes "
                             @"move through this lens: payloads enter via the API's blob "
                             @"upload, and content here is structure + reference (§13.1). "
                             @"A duplicate slug in tenant %@ is refused (409); an unknown "
                             @"blob id is refused by the service.",
                             tenant.slug]
               confirmTitle:@"Create Content"
              accessoryView:form
                 completion:^(BOOL confirmed) {
        if (!confirmed) {
            return;
        }
        NSString *slug = [[slugField stringValue] stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *title = [[titleField stringValue] stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *kind = [[kindField stringValue] stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        int64_t blobID = [[blobField stringValue] longLongValue];
        if ([slug length] == 0 || [title length] == 0 || blobID <= 0) {
            [weakSelf.statusField setStringValue:@"New content needs a slug, a title, and a blob id; nothing was sent."];
            return;
        }
        NSNumber *collectionID = [[collectionPopup selectedItem] representedObject];
        [weakSelf.cloudClient createContentForTenantID:tenant.tenantID
                                                  slug:slug
                                                 title:title
                                                  kind:([kind length] > 0) ? kind : @"text"
                                          collectionID:(collectionID != nil) ? [collectionID longLongValue] : 0
                                                blobID:blobID
                                            completion:^(CloudContentItem *item, NSError *error) {
            if (item == nil) {
                [weakSelf reportFailure:@"Create content" error:error];
                return;
            }
            [weakSelf.statusField setStringValue:[NSString stringWithFormat:
                @"Content %@ created in tenant %@ at version %lld.",
                item.slug, tenant.slug, (long long)item.currentVersionNo]];
            [weakSelf refreshContent];
        }];
    }];
}

- (IBAction)newVersion:(id)sender {
    CloudTenant *tenant = self.selectedTenant;
    CloudContentItem *item = [self selectedContentItem];
    if (tenant == nil || item == nil) {
        return;
    }
    NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 64)];
    NSTextField *blobField = [self formFieldWithPlaceholder:@"Blob id (already uploaded via the API)"
                                                      frame:NSMakeRect(0, 36, 340, 24)
                                                     secure:NO];
    [form addSubview:blobField];
    NSTextField *noteField = [self formFieldWithPlaceholder:@"Note (optional)"
                                                      frame:NSMakeRect(0, 4, 340, 24)
                                                     secure:NO];
    [form addSubview:noteField];
    __weak StorageViewController *weakSelf = self;
    [self promptWithMessage:[NSString stringWithFormat:@"Add a version to %@ (tenant %@)?",
                             item.slug, tenant.slug]
                     effect:[NSString stringWithFormat:
                             @"POST /v1/content/%lld/versions appends version %lld "
                             @"referencing the named blob (§13.5: payload changes always "
                             @"create versions; history is append-only and no version row "
                             @"is ever edited). If the tenant already holds that blob the "
                             @"version costs no new bytes (dedup, §13.2).",
                             (long long)item.contentID, (long long)(item.currentVersionNo + 1)]
               confirmTitle:@"Add Version"
              accessoryView:form
                 completion:^(BOOL confirmed) {
        if (!confirmed) {
            return;
        }
        int64_t blobID = [[blobField stringValue] longLongValue];
        if (blobID <= 0) {
            [weakSelf.statusField setStringValue:@"New version needs a blob id; nothing was sent."];
            return;
        }
        NSString *note = [[noteField stringValue] stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [weakSelf.cloudClient createVersionForTenantID:tenant.tenantID
                                             contentID:item.contentID
                                                blobID:blobID
                                                  note:([note length] > 0) ? note : nil
                                            completion:^(CloudContentVersion *version, NSError *error) {
            if (version == nil) {
                [weakSelf reportFailure:@"Add version" error:error];
                return;
            }
            [weakSelf.statusField setStringValue:[NSString stringWithFormat:
                @"%@ is now at version %lld (blob #%lld).",
                item.slug, (long long)version.versionNo, (long long)version.blobID]];
            [weakSelf refreshContent];
        }];
    }];
}

- (IBAction)rollBackContent:(id)sender {
    CloudTenant *tenant = self.selectedTenant;
    CloudContentItem *item = [self selectedContentItem];
    CloudContentVersion *version = [self selectedContentVersion];
    if (tenant == nil || item == nil || version == nil) {
        return;
    }
    __weak StorageViewController *weakSelf = self;
    [self confirmWithMessage:[NSString stringWithFormat:@"Roll %@ back to version %lld?",
                              item.slug, (long long)version.versionNo]
                      effect:[NSString stringWithFormat:
                              @"POST /v1/content/%lld/rollback creates a NEW version whose "
                              @"blob is version %lld's (blob #%lld) — history records the "
                              @"rollback as an event and is never rewritten (§13.5). Dedup "
                              @"makes the new version cost no new bytes (§13.2).",
                              (long long)item.contentID, (long long)version.versionNo,
                              (long long)version.blobID]
              confirmTitle:@"Roll Back"
                completion:^(BOOL confirmed) {
        if (!confirmed) {
            return;
        }
        [weakSelf.cloudClient rollbackContentForTenantID:tenant.tenantID
                                               contentID:item.contentID
                                             toVersionNo:version.versionNo
                                              completion:^(CloudContentVersion *newVersion, NSError *error) {
            if (newVersion == nil) {
                [weakSelf reportFailure:@"Roll back" error:error];
                return;
            }
            [weakSelf.statusField setStringValue:[NSString stringWithFormat:
                @"%@ rolled back: version %lld now references version %lld's blob.",
                item.slug, (long long)newVersion.versionNo, (long long)version.versionNo]];
            [weakSelf refreshContent];
        }];
    }];
}

- (IBAction)setContentState:(id)sender {
    CloudTenant *tenant = self.selectedTenant;
    CloudContentItem *item = [self selectedContentItem];
    if (tenant == nil || item == nil) {
        return;
    }
    NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 32)];
    NSPopUpButton *statePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 4, 340, 24) pullsDown:NO];
    [statePopup addItemsWithTitles:@[@"draft", @"published", @"archived"]];
    [statePopup selectItemWithTitle:item.state];
    [form addSubview:statePopup];
    __weak StorageViewController *weakSelf = self;
    [self promptWithMessage:[NSString stringWithFormat:@"Set the state of %@ (tenant %@)?",
                             item.slug, tenant.slug]
                     effect:[NSString stringWithFormat:
                             @"POST /v1/content/%lld/state moves the item from %@ to the "
                             @"chosen state (draft | published | archived) through the state "
                             @"route, so the transition audits distinctly (§13.5). No "
                             @"version is created and no payload changes.",
                             (long long)item.contentID, item.state]
               confirmTitle:@"Set State"
              accessoryView:form
                 completion:^(BOOL confirmed) {
        if (!confirmed) {
            return;
        }
        NSString *state = [statePopup titleOfSelectedItem];
        [weakSelf.cloudClient setStateForContentForTenantID:tenant.tenantID
                                                  contentID:item.contentID
                                                      state:state
                                                 completion:^(CloudContentItem *updated, NSError *error) {
            if (updated == nil) {
                [weakSelf reportFailure:@"Set state" error:error];
                return;
            }
            [weakSelf.statusField setStringValue:[NSString stringWithFormat:
                @"%@ is now %@.", item.slug, updated.state]];
            [weakSelf refreshContent];
        }];
    }];
}

- (IBAction)deleteContent:(id)sender {
    CloudTenant *tenant = self.selectedTenant;
    CloudContentItem *item = [self selectedContentItem];
    if (tenant == nil || item == nil) {
        return;
    }
    __weak StorageViewController *weakSelf = self;
    [self confirmWithMessage:[NSString stringWithFormat:@"Delete content %@ (tenant %@)?",
                              item.slug, tenant.slug]
                      effect:[NSString stringWithFormat:
                              @"DELETE /v1/content/%lld deletes the item and ALL its "
                              @"versions and drops their blob references (§13.5) — blobs "
                              @"whose refcount reaches 0 orphan and are reclaimed only by "
                              @"a GC sweep past the grace period (§13.3). The deletion is "
                              @"audited with the item's slug (in-session surface, §13.8).",
                              (long long)item.contentID]
              confirmTitle:@"Delete Content"
                completion:^(BOOL confirmed) {
        if (!confirmed) {
            return;
        }
        [weakSelf.cloudClient deleteContentForTenantID:tenant.tenantID
                                             contentID:item.contentID
                                            completion:^(BOOL success, NSError *error) {
            if (!success) {
                [weakSelf reportFailure:@"Delete content" error:error];
                return;
            }
            [weakSelf.statusField setStringValue:[NSString stringWithFormat:
                @"Content %@ deleted from tenant %@.", item.slug, tenant.slug]];
            [weakSelf refreshContent];
        }];
    }];
}

#pragma mark - Garbage collection (§13.3; SF-T12j)

// Run GC is a two-step act by design: the dry run goes first (it
// changes nothing), its AGGREGATES are shown in the confirm sheet,
// and only the confirmation sends the real sweep. Figures only ever
// cross this surface — scanned / orphans / deleted / bytes (§13.8).
- (IBAction)runGC:(id)sender {
    CloudTenant *tenant = self.selectedTenant;
    if (tenant == nil) {
        return;
    }
    __weak StorageViewController *weakSelf = self;
    [self.cloudClient runGCForTenantID:tenant.tenantID
                                dryRun:YES
                            completion:^(NSDictionary *result, NSError *error) {
        if (result == nil) {
            [weakSelf reportFailure:@"GC dry run" error:error];
            return;
        }
        [weakSelf confirmGCForTenant:tenant dryRunResult:result];
    }];
}

- (void)confirmGCForTenant:(CloudTenant *)tenant dryRunResult:(NSDictionary *)dryRunResult {
    int64_t scanned = [dryRunResult[@"scanned"] isKindOfClass:[NSNumber class]]
        ? [dryRunResult[@"scanned"] longLongValue] : 0;
    int64_t orphans = [dryRunResult[@"orphans"] isKindOfClass:[NSNumber class]]
        ? [dryRunResult[@"orphans"] longLongValue] : 0;
    __weak StorageViewController *weakSelf = self;
    [self confirmWithMessage:[NSString stringWithFormat:@"Run garbage collection for tenant %@?",
                              tenant.slug]
                      effect:[NSString stringWithFormat:
                              @"Dry run (already completed, nothing deleted): %lld blob(s) "
                              @"scanned in tenant %@, %lld orphaned past the grace period. "
                              @"POST /v1/admin/gc {tenant_id: %lld, dry_run: false} now "
                              @"recomputes refcounts and deletes those orphans — adapter "
                              @"bytes first, then the rows (§13.3). Referenced blobs are "
                              @"never touched. The sweep is audited (storage.gc) and its "
                              @"result is aggregates only (§13.8).",
                              (long long)scanned, tenant.slug, (long long)orphans,
                              (long long)tenant.tenantID]
              confirmTitle:@"Run GC"
                completion:^(BOOL confirmed) {
        if (!confirmed) {
            [weakSelf.statusField setStringValue:[NSString stringWithFormat:
                @"GC for tenant %@ not run — the dry run found %lld orphan(s); nothing was deleted.",
                tenant.slug, (long long)orphans]];
            return;
        }
        [weakSelf.cloudClient runGCForTenantID:tenant.tenantID
                                        dryRun:NO
                                    completion:^(NSDictionary *result, NSError *error) {
            if (result == nil) {
                [weakSelf reportFailure:@"Run GC" error:error];
                return;
            }
            int64_t deleted = [result[@"deleted"] isKindOfClass:[NSNumber class]]
                ? [result[@"deleted"] longLongValue] : 0;
            int64_t reclaimed = [result[@"bytes_reclaimed"] isKindOfClass:[NSNumber class]]
                ? [result[@"bytes_reclaimed"] longLongValue] : 0;
            int64_t swept = [result[@"scanned"] isKindOfClass:[NSNumber class]]
                ? [result[@"scanned"] longLongValue] : 0;
            [weakSelf.statusField setStringValue:[NSString stringWithFormat:
                @"GC for tenant %@: scanned %lld · deleted %lld orphan(s) · reclaimed %@.",
                tenant.slug, (long long)swept, (long long)deleted,
                [weakSelf bytesString:reclaimed]]];
            [weakSelf refreshContent];
        }];
    }];
}

@end
