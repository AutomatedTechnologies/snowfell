// GitHubProjectsClient — the GraphQL write path for Snowfell's three D3
// operations (SF-T4; design record §3, D3, D4). BUILD-ONLY machinery: it
// is INERT BY DEFAULT and stays inert in this build, behind a double lock:
//
//   1. COMPILE-TIME: SNOWFELL_WRITEBACK_ENABLED is 0 below. sendMutation:
//      refuses with GitHubProjectsClientErrorWriteBackDisabled before any
//      Keychain read or network call. The build line flips this constant
//      to 1 only at the rig, with the owner's word — never in a commit
//      made away from the rig.
//   2. RUNTIME: even compiled on, sending requires (a) a GitHub token in
//      the macOS Keychain and (b) the owner's explicit in-app "Send
//      pending" action. No timers, no background send, no other caller.
//
// D4 token discipline: the token is a generic-password Keychain item,
// service "com.detroitautomationacademy.snowfell.github". It is fetched
// inside the single method that builds ONE HTTP request, used to set that
// request's Authorization header, and released when the method returns.
// It is never stored in a property or ivar, never written to the DB or a
// file, and never logged (errors carry HTTP status / GraphQL messages
// only). The status probe reads ATTRIBUTES ONLY — the secret bytes never
// materialize for a state check.
//
// The three D3 operations and their Projects v2 documents:
//   status_move → updateProjectV2ItemFieldValue (singleSelectOptionId)
//   create_item → addProjectV2DraftIssue, then — when the queue payload
//                 carries an initial Status — the same field-value
//                 mutation against the newly created item, in the same
//                 send attempt (the draft-issue mutation takes no field
//                 values, so creation + initial status is two calls)
//   comment     → addComment. Subjects are ISSUES: the snapshot stores
//                 the project item's node ID, not the issue's, so the
//                 client first resolves the issue ID from repo + number
//                 (a read query), then comments. DRAFT ISSUES CANNOT BE
//                 COMMENTED ON — GitHub exposes no comment mutation for
//                 them (their body is edited via
//                 updateProjectV2DraftIssue instead); a queued comment
//                 on a draft fails at send with
//                 GitHubProjectsClientErrorCommentUnsupportedForDraft
//                 rather than being faked. See README (SF-T4).
#import <Foundation/Foundation.h>

@class WriteBackMutation;

NS_ASSUME_NONNULL_BEGIN

// THE COMPILE-TIME LOCK. 0 = this build cannot send, whatever the UI or
// the Keychain says. Flip to 1 only in a rig build cut with the owner's
// explicit word (see README "Enable path").
#define SNOWFELL_WRITEBACK_ENABLED 0

extern NSString * const GitHubProjectsClientErrorDomain;
extern NSString * const GitHubProjectsKeychainService;

typedef NS_ENUM(NSInteger, GitHubProjectsClientError) {
    GitHubProjectsClientErrorWriteBackDisabled = 1,
    GitHubProjectsClientErrorNotConfigured = 2,
    GitHubProjectsClientErrorKeychainFailed = 3,
    GitHubProjectsClientErrorMalformedPayload = 4,
    GitHubProjectsClientErrorCommentUnsupportedForDraft = 5,
    GitHubProjectsClientErrorTransport = 6,
    GitHubProjectsClientErrorHTTP = 7,
    GitHubProjectsClientErrorGraphQL = 8,
    GitHubProjectsClientErrorMalformedResponse = 9,
};

typedef NS_ENUM(NSInteger, GitHubTokenStatus) {
    GitHubTokenStatusNotConfigured = 0,
    GitHubTokenStatusAvailable = 1,
};

@interface GitHubProjectsClient : NSObject

// The single destination every D3 operation talks to.
+ (NSString *)graphQLEndpoint;   // @"https://api.github.com/graphql"

// The compile-time lock, readable by the UI so disabled states are honest.
+ (BOOL)writeBackCompiledEnabled;

// Attribute-only Keychain probe: does a token item exist for the service?
// Never returns, copies, or logs the secret itself.
- (GitHubTokenStatus)tokenStatus;

// The GraphQL documents (constants; exposed so the confirm sheets and the
// README describe the exact mutations, and so they can be reviewed
// without running anything).
+ (NSString *)statusFieldValueMutationDocument;
+ (NSString *)createDraftIssueMutationDocument;
+ (NSString *)addItemByIDMutationDocument;
+ (NSString *)addCommentMutationDocument;
+ (NSString *)issueIDQueryDocument;

// Variables for one queued mutation's FIRST call, from its payload.
// Returns nil + error when the payload lacks what the operation needs.
- (nullable NSDictionary *)variablesForMutation:(WriteBackMutation *)mutation
                                          error:(NSError **)error;

// Sends ONE queued mutation (one attempt). Completion runs on the main
// queue: success + a result reference (the affected node ID / comment
// URL) or an error whose description is safe to store in the queue's
// last_error and show in the UI. In this build every call completes with
// GitHubProjectsClientErrorWriteBackDisabled and no network occurs.
- (void)sendMutation:(WriteBackMutation *)mutation
          completion:(void (^)(BOOL success,
                               NSString * _Nullable resultRef,
                               NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
