// SnapshotSync — SF-T6 in-app snapshot refresh: fetch the Academy's OWN
// published registry snapshot and stage it, verified, for an owner-pressed
// swap. Design record §2 (snapshot contract) + §6 SF-T6.
//
// This class is the app's SECOND deliberate NSURLSession exception (the
// first is GitHubProjectsClient.m, SF-T4, inert behind its compile-time
// lock): sync is a read-only public-HTTPS GET of the published snapshot —
// the stable manifest and the versioned registry.db on
// detroitautomationacademy.com. NO auth, NO token, NO POST, no other
// destination. The class never swaps the running snapshot itself: it
// stages bytes on disk; AppDelegate hands a verified staged pair to the
// existing SnapshotStore load path only when the owner presses Apply.
//
// Discipline (the §2 contract, unchanged):
//   - Verify BEFORE swap: the staged database's size + SHA-256 must match
//     the served manifest (checked with SnapshotStore's own verifier)
//     before anything is offered to the UI as applicable.
//   - A failed download or verification deletes the staged files and
//     reports; the RUNNING snapshot is never touched by a failed sync.
//   - No timers, no background fetch: every network call in this class
//     is downstream of the owner's Check Now action.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const SnapshotSyncErrorDomain;

typedef NS_ENUM(NSInteger, SnapshotSyncError) {
    SnapshotSyncErrorTransport = 1,
    SnapshotSyncErrorHTTP = 2,
    SnapshotSyncErrorManifestMalformed = 3,
    SnapshotSyncErrorNoSnapshotLoaded = 4,
    SnapshotSyncErrorStageWriteFailed = 5,
    SnapshotSyncErrorVerificationFailed = 6,
};

typedef NS_ENUM(NSInteger, SnapshotSyncCheckState) {
    SnapshotSyncCheckStateUpToDate = 0,
    SnapshotSyncCheckStateUpdateAvailable = 1,
    SnapshotSyncCheckStateError = 2,
};

@interface SnapshotSync : NSObject

// The one manifest this class ever fetches.
+ (NSString *)stableManifestURLString;

// Application Support/Snowfell/snapshots[/<version>] — where verified
// staged pairs live until the owner applies or a newer stage replaces
// them.
+ (NSString *)snapshotsDirectoryPath;
+ (NSString *)stagedDirectoryPathForVersion:(NSString *)version;

// GET the stable manifest (30s timeout, mirroring GitHubProjectsClient's
// session discipline). Completion runs on the main queue with the parsed
// manifest plus its raw bytes (the raw bytes are what gets staged beside
// a downloaded database, so the staged pair is byte-exact what was
// served).
- (void)fetchServedManifestWithCompletion:(void (^)(NSDictionary * _Nullable manifest,
                                                    NSData * _Nullable rawData,
                                                    NSError * _Nullable error))completion;

// Pure comparison: served manifest vs the manifest of the snapshot the
// store has loaded. Equal version AND sha256 → up to date; anything else
// (including no loaded snapshot) is reported, never guessed.
+ (SnapshotSyncCheckState)checkStateForServedManifest:(NSDictionary *)servedManifest
                                       loadedManifest:(nullable NSDictionary *)loadedManifest
                                      updateVersion:(NSString * _Nullable * _Nullable)updateVersion;

// GET the versioned database named by the served manifest (its
// snapshot_url when present, else the canonical registry/<version>/
// registry.db), stage it at snapshots/<version>/registry.db with the
// manifest bytes beside it as snapshot-manifest.json, and VERIFY the
// staged bytes (size + SHA-256 via SnapshotStore) before completing.
// On any failure the staged directory is deleted and the error names
// the stage that failed. Completion runs on the main queue.
- (void)downloadAndStageServedManifest:(NSDictionary *)servedManifest
                             rawManifestData:(NSData *)rawManifestData
                                  completion:(void (^)(NSString * _Nullable stagedDatabasePath,
                                                       NSString * _Nullable stagedManifestPath,
                                                       NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
