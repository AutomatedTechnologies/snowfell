#import "SnapshotSync.h"
#import "SnapshotStore.h"

NSString * const SnapshotSyncErrorDomain = @"com.detroitautomationacademy.snowfell.SnapshotSync";

static NSString * const SnapshotSyncStableManifestURL = @"https://detroitautomationacademy.com/registry/registry-manifest.json";
static NSString * const SnapshotSyncSiteBase = @"https://detroitautomationacademy.com";

@implementation SnapshotSync

+ (NSString *)stableManifestURLString {
    return SnapshotSyncStableManifestURL;
}

+ (NSError *)errorWithCode:(SnapshotSyncError)code description:(NSString *)description {
    return [NSError errorWithDomain:SnapshotSyncErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

+ (NSString *)snapshotsDirectoryPath {
    NSString *base = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                          NSUserDomainMask, YES) firstObject];
    if (base == nil) {
        base = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
    }
    return [[base stringByAppendingPathComponent:@"Snowfell"]
            stringByAppendingPathComponent:@"snapshots"];
}

+ (NSString *)stagedDirectoryPathForVersion:(NSString *)version {
    return [[self snapshotsDirectoryPath] stringByAppendingPathComponent:version];
}

#pragma mark - Transport

// Session discipline mirrors GitHubProjectsClient (SF-T4): default
// configuration, explicit request timeout, completions on the main
// queue — every caller is UI-side. GET-only: this class builds no
// request with a body and no request to any host but the Academy site.
- (NSURLSession *)sessionWithTimeout:(NSTimeInterval)timeout {
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    [configuration setTimeoutIntervalForRequest:timeout];
    return [NSURLSession sessionWithConfiguration:configuration
                                         delegate:nil
                                    delegateQueue:[NSOperationQueue mainQueue]];
}

- (void)fetchDataFromURL:(NSURL *)url
                 timeout:(NSTimeInterval)timeout
              completion:(void (^)(NSData * _Nullable data, NSError * _Nullable error))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"GET"];
    [request setValue:@"Snowfell/0.1.0" forHTTPHeaderField:@"User-Agent"];
    NSURLSessionDataTask *task = [[self sessionWithTimeout:timeout] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *transportError) {
        if (transportError != nil) {
            completion(nil, [[self class] errorWithCode:SnapshotSyncErrorTransport
                                            description:[NSString stringWithFormat:
                                                         @"Transport failed: %@", transportError.localizedDescription]]);
            return;
        }
        NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
        if (statusCode != 200) {
            completion(nil, [[self class] errorWithCode:SnapshotSyncErrorHTTP
                                            description:[NSString stringWithFormat:
                                                         @"%@ answered HTTP %ld.", [url host], (long)statusCode]]);
            return;
        }
        completion(data, nil);
    }];
    [task resume];
}

#pragma mark - Manifest fetch + comparison

- (void)fetchServedManifestWithCompletion:(void (^)(NSDictionary * _Nullable manifest,
                                                    NSData * _Nullable rawData,
                                                    NSError * _Nullable error))completion {
    NSURL *url = [NSURL URLWithString:[[self class] stableManifestURLString]];
    [self fetchDataFromURL:url timeout:30 completion:^(NSData *data, NSError *error) {
        if (data == nil) {
            completion(nil, nil, error);
            return;
        }
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if (![parsed isKindOfClass:[NSDictionary class]]
            || ![[parsed objectForKey:@"version"] isKindOfClass:[NSString class]]
            || ![[parsed objectForKey:@"sha256"] isKindOfClass:[NSString class]]
            || ![[parsed objectForKey:@"size_bytes"] isKindOfClass:[NSNumber class]]) {
            completion(nil, nil, [[self class] errorWithCode:SnapshotSyncErrorManifestMalformed
                                                  description:@"The served registry manifest lacks version / sha256 / size_bytes; refusing to act on it."]);
            return;
        }
        completion((NSDictionary *)parsed, data, nil);
    }];
}

+ (SnapshotSyncCheckState)checkStateForServedManifest:(NSDictionary *)servedManifest
                                       loadedManifest:(NSDictionary *)loadedManifest
                                      updateVersion:(NSString * _Nullable * _Nullable)updateVersion {
    if (updateVersion != NULL) {
        *updateVersion = nil;
    }
    if (loadedManifest == nil) {
        return SnapshotSyncCheckStateError;
    }
    NSString *servedVersion = servedManifest[@"version"];
    NSString *servedSHA = servedManifest[@"sha256"];
    if ([servedVersion isEqualToString:loadedManifest[@"version"]]
        && [servedSHA isEqualToString:loadedManifest[@"sha256"]]) {
        return SnapshotSyncCheckStateUpToDate;
    }
    if (updateVersion != NULL) {
        *updateVersion = servedVersion;
    }
    return SnapshotSyncCheckStateUpdateAvailable;
}

#pragma mark - Download + stage + verify

- (void)downloadAndStageServedManifest:(NSDictionary *)servedManifest
                     rawManifestData:(NSData *)rawManifestData
                          completion:(void (^)(NSString * _Nullable stagedDatabasePath,
                                               NSString * _Nullable stagedManifestPath,
                                               NSError * _Nullable error))completion {
    NSString *version = servedManifest[@"version"];
    NSString *databaseURLString = servedManifest[@"snapshot_url"];
    if (![databaseURLString isKindOfClass:[NSString class]] || [databaseURLString length] == 0) {
        databaseURLString = [NSString stringWithFormat:@"%@/registry/%@/registry.db",
                             SnapshotSyncSiteBase, version];
    }
    NSURL *databaseURL = [NSURL URLWithString:databaseURLString];
    // The snapshot is ~2 MB today; the download gets a longer leash than
    // the manifest fetch, still owner-pressed and foreground.
    [self fetchDataFromURL:databaseURL timeout:120 completion:^(NSData *data, NSError *error) {
        if (data == nil) {
            completion(nil, nil, error);
            return;
        }
        NSString *stageDir = [[self class] stagedDirectoryPathForVersion:version];
        NSString *databasePath = [stageDir stringByAppendingPathComponent:@"registry.db"];
        NSString *manifestPath = [stageDir stringByAppendingPathComponent:@"snapshot-manifest.json"];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        // A re-stage of the same version starts clean.
        [fileManager removeItemAtPath:stageDir error:NULL];
        NSError *ioError = nil;
        BOOL staged = [fileManager createDirectoryAtPath:stageDir
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:&ioError]
            && [data writeToFile:databasePath options:NSDataWritingAtomic error:&ioError]
            && [rawManifestData writeToFile:manifestPath options:NSDataWritingAtomic error:&ioError];
        if (!staged) {
            [fileManager removeItemAtPath:stageDir error:NULL];
            completion(nil, nil, [[self class] errorWithCode:SnapshotSyncErrorStageWriteFailed
                                                  description:[NSString stringWithFormat:
                                                               @"Staging %@ failed: %@ The running snapshot was not touched.",
                                                               version, ioError.localizedDescription]]);
            return;
        }
        // Verify BEFORE the pair is ever offered for a swap — the same
        // SnapshotStore contract the load path enforces. Mismatch: the
        // staged files are deleted and the running snapshot stands.
        NSError *verifyError = nil;
        if (![SnapshotStore verifyDatabaseAtPath:databasePath
                                 againstManifest:servedManifest
                                           error:&verifyError]) {
            [fileManager removeItemAtPath:stageDir error:NULL];
            completion(nil, nil, [[self class] errorWithCode:SnapshotSyncErrorVerificationFailed
                                                  description:[NSString stringWithFormat:
                                                               @"Staged %@ failed verification and was discarded: %@ The running snapshot was not touched.",
                                                               version, verifyError.localizedDescription]]);
            return;
        }
        completion(databasePath, manifestPath, nil);
    }];
}

@end
