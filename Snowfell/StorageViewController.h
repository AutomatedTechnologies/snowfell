// StorageViewController — V12 Storage (SF-T12f; cloud storage design
// record 03, §9): the operator console for the SnowfellStorageService
// companion service, in the V11 Incidents lens pattern (programmatic
// AppKit, ≥1100×680, structure left / evidence right). Left: the
// service state line (from GET /v1/health polls — Stopped, or Running
// on 127.0.0.1:<port> — v<version>), Start/Stop Service buttons over
// the bundled helper, and the tenant table. Right: the selected
// tenant's buckets (name, objects, bytes, quota), logins (username,
// role, state, lock), and audit tail (time, actor, action, result).
// SF-T12j adds the Content section under that arrangement (§13.5/§13.7):
// collections (name, slug, parent), content items (slug, title, kind,
// state, current version, size), the selected item's versions
// (version, SHA-256 short, size, note, created), and the §13.6 dedup
// figures line (logical / physical / saved / ratio) from the usage
// payload. Content mutations reference already-uploaded blob ids —
// the lens uploads nothing and downloads nothing (no file handling).
//
// ALL data arrives over REST through CloudServiceClient — this lens
// contains no SQL and never opens cloud.db (§9 dogfooding). Mutations
// (new tenant / login / bucket, password set, reset issue, closes and
// deletes) go through confirm sheets naming the target, in the
// estate's access-review habit: destination (the loopback base URL),
// operator (the Keychain operator token), the exact effect, and what
// declining does (nothing).
//
// PAIRING (§5.5): when no operator token is in the Keychain, the lens
// shows the pairing pane instead of data — a token field, Save to
// Keychain, and the bootstrap instructions. The token is handed to
// CloudServiceClient.saveOperatorToken: and kept nowhere else.
//
// SERVICE CONTROL: Start launches the bundled helper
// (SnowfellStorageService, via -[NSBundle pathForAuxiliaryExecutable:])
// with NSTask; Stop terminates OUR task. A service already answering
// health (e.g. run standalone from a terminal) makes Start a no-op
// success and is never terminated by this lens — the state line says
// whose it is. When the helper is absent from the bundle (source
// builds may lack it until the full bundle assembles at packaging,
// SF-T8), the buttons disable and the state line states the reason —
// stated, not faked.
#import <AppKit/AppKit.h>

@class CloudServiceClient;

NS_ASSUME_NONNULL_BEGIN

@interface StorageViewController : NSViewController

@property (nonatomic, strong, readonly) CloudServiceClient *cloudClient;

- (instancetype)initWithCloudServiceClient:(CloudServiceClient *)client;

// Re-evaluates pairing (Keychain probe), polls health, and — when
// paired — reloads tenants + the selected tenant's detail. Safe in
// every state: unpaired shows the pairing pane; a stopped service
// shows the stopped line and an empty tenant table, never stale data.
- (void)reloadStorage;

@end

NS_ASSUME_NONNULL_END
