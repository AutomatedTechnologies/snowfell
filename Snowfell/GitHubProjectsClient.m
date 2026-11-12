#import "GitHubProjectsClient.h"
#import "WriteBackQueue.h"
#import <Security/Security.h>

NSString * const GitHubProjectsClientErrorDomain = @"com.detroitautomationacademy.snowfell.GitHubProjectsClient";
NSString * const GitHubProjectsKeychainService = @"com.detroitautomationacademy.snowfell.github";

@implementation GitHubProjectsClient

+ (NSError *)errorWithCode:(GitHubProjectsClientError)code description:(NSString *)description {
    return [NSError errorWithDomain:GitHubProjectsClientErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

+ (NSString *)graphQLEndpoint {
    return @"https://api.github.com/graphql";
}

+ (BOOL)writeBackCompiledEnabled {
    return SNOWFELL_WRITEBACK_ENABLED != 0;
}

#pragma mark - GraphQL documents

+ (NSString *)statusFieldValueMutationDocument {
    return @"mutation SnowfellSetStatus($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {"
           @"  updateProjectV2ItemFieldValue(input: {projectId: $projectId, itemId: $itemId, fieldId: $fieldId, value: {singleSelectOptionId: $optionId}}) {"
           @"    projectV2Item { id }"
           @"  }"
           @"}";
}

+ (NSString *)createDraftIssueMutationDocument {
    return @"mutation SnowfellCreateDraftIssue($projectId: ID!, $title: String!, $body: String) {"
           @"  addProjectV2DraftIssue(input: {projectId: $projectId, title: $title, body: $body}) {"
           @"    projectItem { id }"
           @"  }"
           @"}";
}

+ (NSString *)addItemByIDMutationDocument {
    // The other half of Projects v2 item creation: attaching EXISTING
    // content (an Issue/PR node) to a board. Snowfell's create_item kind
    // makes new drafts (above); this document is provided for the SF-T5
    // orchestration surface, which enqueues against existing content.
    return @"mutation SnowfellAddItemById($projectId: ID!, $contentId: ID!) {"
           @"  addProjectV2ItemById(input: {projectId: $projectId, contentId: $contentId}) {"
           @"    item { id }"
           @"  }"
           @"}";
}

+ (NSString *)addCommentMutationDocument {
    return @"mutation SnowfellAddComment($subjectId: ID!, $body: String!) {"
           @"  addComment(input: {subjectId: $subjectId, body: $body}) {"
           @"    commentEdge { node { id url } }"
           @"  }"
           @"}";
}

+ (NSString *)issueIDQueryDocument {
    return @"query SnowfellIssueID($owner: String!, $name: String!, $number: Int!) {"
           @"  repository(owner: $owner, name: $name) {"
           @"    issue(number: $number) { id }"
           @"  }"
           @"}";
}

#pragma mark - Keychain (D4)

- (GitHubTokenStatus)tokenStatus {
    // Attributes only: kSecReturnData is NOT set, so the secret bytes are
    // never materialized for a state check.
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: GitHubProjectsKeychainService,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
        (__bridge id)kSecReturnAttributes: @YES,
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (result != NULL) {
        CFRelease(result);
    }
    return (status == errSecSuccess) ? GitHubTokenStatusAvailable : GitHubTokenStatusNotConfigured;
}

// Fetches the token for ONE request build. The result lives only in the
// caller's local scope; it is never assigned to a property or ivar, never
// logged, never persisted. Returns nil + error when absent or unreadable.
- (nullable NSString *)fetchTokenForRequestBuild:(NSError **)error {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: GitHubProjectsKeychainService,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
        (__bridge id)kSecReturnData: @YES,
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecItemNotFound) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:GitHubProjectsClientErrorNotConfigured
                                     description:@"No GitHub token in the Keychain (service com.detroitautomationacademy.snowfell.github). The queue stays pending."];
        }
        return nil;
    }
    if (status != errSecSuccess || result == NULL) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:GitHubProjectsClientErrorKeychainFailed
                                     description:[NSString stringWithFormat:
                                                  @"Keychain read failed (OSStatus %d). The queue stays pending.", (int)status]];
        }
        if (result != NULL) {
            CFRelease(result);
        }
        return nil;
    }
    NSData *data = (__bridge_transfer NSData *)result;
    NSString *token = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (token == nil || [token length] == 0) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:GitHubProjectsClientErrorKeychainFailed
                                     description:@"The Keychain token item is empty or not UTF-8. The queue stays pending."];
        }
        return nil;
    }
    return token;
}

#pragma mark - Variables

- (NSDictionary *)variablesForMutation:(WriteBackMutation *)mutation
                                 error:(NSError **)error {
    NSDictionary *payload = mutation.payload;
    if ([mutation.kind isEqualToString:WriteBackKindStatusMove]) {
        NSString *fieldID = payload[@"field_id"];
        NSString *optionID = payload[@"option_id"];
        if (mutation.itemID == nil || fieldID == nil || optionID == nil) {
            if (error != NULL) {
                *error = [[self class] errorWithCode:GitHubProjectsClientErrorMalformedPayload
                                         description:@"status_move payload lacks item / field_id / option_id."];
            }
            return nil;
        }
        return @{@"projectId": mutation.boardID,
                 @"itemId": mutation.itemID,
                 @"fieldId": fieldID,
                 @"optionId": optionID};
    }
    if ([mutation.kind isEqualToString:WriteBackKindCreateItem]) {
        NSString *title = payload[@"title"];
        if (title == nil || [title length] == 0) {
            if (error != NULL) {
                *error = [[self class] errorWithCode:GitHubProjectsClientErrorMalformedPayload
                                         description:@"create_item payload lacks a title."];
            }
            return nil;
        }
        return @{@"projectId": mutation.boardID,
                 @"title": title,
                 @"body": (payload[@"body"] != nil) ? payload[@"body"] : @""};
    }
    if ([mutation.kind isEqualToString:WriteBackKindComment]) {
        // First call is the issue-ID resolve query (see header note).
        NSString *repo = payload[@"content_repo"];
        NSNumber *number = payload[@"content_number"];
        NSArray<NSString *> *parts = [repo componentsSeparatedByString:@"/"];
        if (repo == nil || number == nil || [parts count] != 2) {
            if (error != NULL) {
                *error = [[self class] errorWithCode:GitHubProjectsClientErrorMalformedPayload
                                         description:@"comment payload lacks content_repo (owner/name) / content_number."];
            }
            return nil;
        }
        return @{@"owner": parts[0], @"name": parts[1], @"number": number};
    }
    if (error != NULL) {
        *error = [[self class] errorWithCode:GitHubProjectsClientErrorMalformedPayload
                                 description:[NSString stringWithFormat:@"Unknown mutation kind: %@", mutation.kind]];
    }
    return nil;
}

#pragma mark - Transport (unreachable while the lock is on)

- (NSURLSession *)session {
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    [configuration setTimeoutIntervalForRequest:30];
    // Completions land on the main queue: every caller is UI-side.
    return [NSURLSession sessionWithConfiguration:configuration
                                         delegate:nil
                                    delegateQueue:[NSOperationQueue mainQueue]];
}

// ONE POST to api.github.com/graphql. The token is fetched here, used to
// build this request's Authorization header, and released when this
// method's scope ends — it travels no further.
- (void)postDocument:(NSString *)document
           variables:(NSDictionary *)variables
          completion:(void (^)(NSDictionary * _Nullable json, NSError * _Nullable error))completion {
    if (![[self class] writeBackCompiledEnabled]) {
        completion(nil, [[self class] errorWithCode:GitHubProjectsClientErrorWriteBackDisabled
                                        description:@"Write-back is compiled OFF in this build (SNOWFELL_WRITEBACK_ENABLED = 0). Nothing was sent."]);
        return;
    }
    NSError *tokenError = nil;
    NSString *token = [self fetchTokenForRequestBuild:&tokenError];
    if (token == nil) {
        completion(nil, tokenError);
        return;
    }

    NSDictionary *bodyObject = @{@"query": document, @"variables": variables};
    NSData *body = [NSJSONSerialization dataWithJSONObject:bodyObject options:0 error:NULL];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[[self class] graphQLEndpoint]]];
    [request setHTTPMethod:@"POST"];
    [request setHTTPBody:body];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"Snowfell/0.1.0" forHTTPHeaderField:@"User-Agent"];
    token = nil;  // the header now carries the only copy the request needs

    NSURLSessionDataTask *task = [[self session] dataTaskWithRequest:request
                                                   completionHandler:^(NSData *data, NSURLResponse *response, NSError *transportError) {
        if (transportError != nil) {
            completion(nil, [[self class] errorWithCode:GitHubProjectsClientErrorTransport
                                            description:[NSString stringWithFormat:
                                                         @"Transport failed: %@", transportError.localizedDescription]]);
            return;
        }
        NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
        if (statusCode != 200) {
            completion(nil, [[self class] errorWithCode:GitHubProjectsClientErrorHTTP
                                            description:[NSString stringWithFormat:
                                                         @"GitHub answered HTTP %ld.", (long)statusCode]]);
            return;
        }
        NSDictionary *json = nil;
        if (data != nil) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if ([parsed isKindOfClass:[NSDictionary class]]) {
                json = parsed;
            }
        }
        if (json == nil) {
            completion(nil, [[self class] errorWithCode:GitHubProjectsClientErrorMalformedResponse
                                            description:@"GitHub's response was not a JSON object."]);
            return;
        }
        NSArray *graphQLErrors = json[@"errors"];
        if ([graphQLErrors isKindOfClass:[NSArray class]] && [graphQLErrors count] > 0) {
            NSString *message = graphQLErrors[0][@"message"];
            completion(nil, [[self class] errorWithCode:GitHubProjectsClientErrorGraphQL
                                            description:[NSString stringWithFormat:
                                                         @"GraphQL error: %@", (message != nil) ? message : @"unknown"]]);
            return;
        }
        completion(json, nil);
    }];
    [task resume];
}

#pragma mark - Send (one attempt per call)

- (void)sendMutation:(WriteBackMutation *)mutation
          completion:(void (^)(BOOL success,
                               NSString * _Nullable resultRef,
                               NSError * _Nullable error))completion {
    // LOCK 1 (compile-time): refuse before Keychain, before network.
    if (![[self class] writeBackCompiledEnabled]) {
        completion(NO, nil, [[self class] errorWithCode:GitHubProjectsClientErrorWriteBackDisabled
                                            description:@"Write-back is compiled OFF in this build (SNOWFELL_WRITEBACK_ENABLED = 0). Nothing was sent; the queue row stays pending for an armed build."]);
        return;
    }

    if ([mutation.kind isEqualToString:WriteBackKindStatusMove]) {
        NSError *error = nil;
        NSDictionary *variables = [self variablesForMutation:mutation error:&error];
        if (variables == nil) {
            completion(NO, nil, error);
            return;
        }
        [self postDocument:[[self class] statusFieldValueMutationDocument]
                 variables:variables
                completion:^(NSDictionary *json, NSError *postError) {
            if (postError != nil) {
                completion(NO, nil, postError);
                return;
            }
            NSString *itemID = json[@"data"][@"updateProjectV2ItemFieldValue"][@"projectV2Item"][@"id"];
            if (itemID == nil) {
                completion(NO, nil, [[self class] errorWithCode:GitHubProjectsClientErrorMalformedResponse
                                                    description:@"Status mutation response carried no projectV2Item.id."]);
                return;
            }
            completion(YES, itemID, nil);
        }];
        return;
    }

    if ([mutation.kind isEqualToString:WriteBackKindCreateItem]) {
        NSError *error = nil;
        NSDictionary *variables = [self variablesForMutation:mutation error:&error];
        if (variables == nil) {
            completion(NO, nil, error);
            return;
        }
        [self postDocument:[[self class] createDraftIssueMutationDocument]
                 variables:variables
                completion:^(NSDictionary *json, NSError *postError) {
            if (postError != nil) {
                completion(NO, nil, postError);
                return;
            }
            NSString *newItemID = json[@"data"][@"addProjectV2DraftIssue"][@"projectItem"][@"id"];
            if (newItemID == nil) {
                completion(NO, nil, [[self class] errorWithCode:GitHubProjectsClientErrorMalformedResponse
                                                    description:@"Create response carried no projectItem.id."]);
                return;
            }
            // Same attempt, second call: apply the queued initial Status —
            // addProjectV2DraftIssue itself accepts no field values.
            NSString *fieldID = mutation.payload[@"field_id"];
            NSString *optionID = mutation.payload[@"option_id"];
            if (fieldID == nil || optionID == nil) {
                completion(YES, newItemID, nil);
                return;
            }
            NSDictionary *statusVariables = @{@"projectId": mutation.boardID,
                                              @"itemId": newItemID,
                                              @"fieldId": fieldID,
                                              @"optionId": optionID};
            [self postDocument:[[self class] statusFieldValueMutationDocument]
                     variables:statusVariables
                    completion:^(NSDictionary *statusJSON, NSError *statusError) {
                if (statusError != nil) {
                    completion(NO, nil, [[self class] errorWithCode:GitHubProjectsClientErrorGraphQL
                                                        description:[NSString stringWithFormat:
                                                                     @"Draft issue created (%@) but its initial Status failed: %@",
                                                                     newItemID, statusError.localizedDescription]]);
                    return;
                }
                completion(YES, newItemID, nil);
            }];
        }];
        return;
    }

    if ([mutation.kind isEqualToString:WriteBackKindComment]) {
        // Draft issues have no comment surface in the GitHub API — fail
        // the row honestly instead of inventing an effect.
        if ([mutation.payload[@"content_kind"] isEqualToString:@"DraftIssue"]) {
            completion(NO, nil, [[self class] errorWithCode:GitHubProjectsClientErrorCommentUnsupportedForDraft
                                                description:@"GitHub exposes no comment mutation for draft issues (addComment subjects are Issues/PRs). Edit the draft's body instead; this row can never send as a comment."]);
            return;
        }
        NSError *error = nil;
        NSDictionary *resolveVariables = [self variablesForMutation:mutation error:&error];
        if (resolveVariables == nil) {
            completion(NO, nil, error);
            return;
        }
        [self postDocument:[[self class] issueIDQueryDocument]
                 variables:resolveVariables
                completion:^(NSDictionary *json, NSError *postError) {
            if (postError != nil) {
                completion(NO, nil, postError);
                return;
            }
            NSString *subjectID = json[@"data"][@"repository"][@"issue"][@"id"];
            if (subjectID == nil) {
                completion(NO, nil, [[self class] errorWithCode:GitHubProjectsClientErrorMalformedResponse
                                                    description:@"Issue resolve query returned no issue id (issue not found?)."]);
                return;
            }
            NSDictionary *commentVariables = @{@"subjectId": subjectID,
                                               @"body": mutation.payload[@"body"]};
            [self postDocument:[[self class] addCommentMutationDocument]
                     variables:commentVariables
                    completion:^(NSDictionary *commentJSON, NSError *commentError) {
                if (commentError != nil) {
                    completion(NO, nil, commentError);
                    return;
                }
                NSDictionary *node = commentJSON[@"data"][@"addComment"][@"commentEdge"][@"node"];
                NSString *resultRef = node[@"url"] ? node[@"url"] : node[@"id"];
                if (resultRef == nil) {
                    completion(NO, nil, [[self class] errorWithCode:GitHubProjectsClientErrorMalformedResponse
                                                        description:@"Comment response carried no comment node."]);
                    return;
                }
                completion(YES, resultRef, nil);
            }];
        }];
        return;
    }

    completion(NO, nil, [[self class] errorWithCode:GitHubProjectsClientErrorMalformedPayload
                                            description:[NSString stringWithFormat:@"Unknown mutation kind: %@", mutation.kind]]);
}

@end
