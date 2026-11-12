#import "CloudServiceClient.h"
#import "CloudModels.h"
#import <Security/Security.h>

NSString * const CloudServiceClientErrorDomain = @"com.detroitautomationacademy.snowfell.CloudServiceClient";
NSString * const CloudServicePortDefaultsKey = @"SnowfellCloudPort";
NSString * const CloudOperatorKeychainService = @"com.detroitautomationacademy.snowfell.cloud-operator";
NSString * const CloudOperatorKeychainAccount = @"operator";
NSString * const CloudServiceErrorCodeKey = @"CloudServiceAPICode";
NSString * const CloudServiceErrorDetailKey = @"CloudServiceAPIDetail";
NSString * const CloudServiceHTTPStatusKey = @"CloudServiceHTTPStatus";

// The service default port (design §2.1). The ONLY host this class
// will ever name sits beside it: the literal loopback string below.
static NSInteger const CloudServiceDefaultPort = 8471;
static NSString * const CloudServiceLoopbackHost = @"127.0.0.1";

@implementation CloudServiceClient

+ (NSError *)errorWithCode:(CloudServiceClientError)code description:(NSString *)description {
    return [NSError errorWithDomain:CloudServiceClientErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

#pragma mark - Base URL (loopback only — the hard rule)

+ (NSInteger)configuredPort {
    NSInteger port = [[NSUserDefaults standardUserDefaults] integerForKey:CloudServicePortDefaultsKey];
    if (port < 1 || port > 65535) {
        return CloudServiceDefaultPort;
    }
    return port;
}

+ (NSURL *)baseURL {
    // Built ONLY as http://127.0.0.1:<port> — components with the host
    // pinned to the literal loopback string. There is no other origin
    // anywhere in this class (design §9).
    NSURLComponents *components = [[NSURLComponents alloc] init];
    [components setScheme:@"http"];
    [components setHost:CloudServiceLoopbackHost];
    [components setPort:@([self configuredPort])];
    return [components URL];
}

// Assembles base + path + query and RE-VERIFIES the result's host
// before returning it. A path or query composed anywhere in this class
// can carry no authority component, so this can only fail if a future
// edit breaks the rule — in which case the request is refused in code
// (CloudServiceClientErrorNonLoopbackRefused), never sent.
- (nullable NSURL *)requestURLWithPath:(NSString *)path
                           queryItems:(nullable NSArray<NSURLQueryItem *> *)queryItems
                                error:(NSError **)error {
    NSURLComponents *components = [NSURLComponents componentsWithURL:[[self class] baseURL]
                                             resolvingAgainstBaseURL:NO];
    [components setPath:path];
    if ([queryItems count] > 0) {
        [components setQueryItems:queryItems];
    }
    NSURL *url = [components URL];
    if (url == nil || ![[url host] isEqualToString:CloudServiceLoopbackHost]) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:CloudServiceClientErrorNonLoopbackRefused
                                     description:@"Refused: the assembled request URL is not loopback (127.0.0.1). Nothing was sent."];
        }
        return nil;
    }
    return url;
}

#pragma mark - Keychain (operator token; D4 custody, §5.5)

+ (BOOL)hasOperatorToken {
    // Attributes only: kSecReturnData is NOT set, so the secret bytes
    // never materialize for a state check (the GitHubProjectsClient
    // tokenStatus discipline).
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: CloudOperatorKeychainService,
        (__bridge id)kSecAttrAccount: CloudOperatorKeychainAccount,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
        (__bridge id)kSecReturnAttributes: @YES,
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (result != NULL) {
        CFRelease(result);
    }
    return status == errSecSuccess;
}

- (BOOL)saveOperatorToken:(NSString *)token error:(NSError **)error {
    if ([token length] == 0) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:CloudServiceClientErrorInvalidArgument
                                     description:@"The operator token is empty; nothing was stored."];
        }
        return NO;
    }
    NSData *tokenData = [token dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *identity = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: CloudOperatorKeychainService,
        (__bridge id)kSecAttrAccount: CloudOperatorKeychainAccount,
    };
    NSDictionary *addItem = [identity mutableCopy];
    [(NSMutableDictionary *)addItem setObject:tokenData forKey:(__bridge id)kSecValueData];
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)addItem, NULL);
    if (status == errSecDuplicateItem) {
        NSDictionary *update = @{(__bridge id)kSecValueData: tokenData};
        status = SecItemUpdate((__bridge CFDictionaryRef)identity, (__bridge CFDictionaryRef)update);
    }
    if (status != errSecSuccess) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:CloudServiceClientErrorKeychainFailed
                                     description:[NSString stringWithFormat:
                                                  @"Keychain write failed (OSStatus %d). The token was not stored.", (int)status]];
        }
        return NO;
    }
    return YES;
}

// Fetches the token for ONE request build. The result lives only in
// the caller's local scope; it is never assigned to a property or
// ivar, never logged, never persisted. Returns nil + error when
// absent or unreadable.
- (nullable NSString *)fetchOperatorTokenForRequestBuild:(NSError **)error {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: CloudOperatorKeychainService,
        (__bridge id)kSecAttrAccount: CloudOperatorKeychainAccount,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
        (__bridge id)kSecReturnData: @YES,
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecItemNotFound) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:CloudServiceClientErrorNotConfigured
                                     description:@"No operator token in the Keychain (service com.detroitautomationacademy.snowfell.cloud-operator). Pair the Storage lens first — nothing was sent."];
        }
        return nil;
    }
    if (status != errSecSuccess || result == NULL) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:CloudServiceClientErrorKeychainFailed
                                     description:[NSString stringWithFormat:
                                                  @"Keychain read failed (OSStatus %d). Nothing was sent.", (int)status]];
        }
        if (result != NULL) {
            CFRelease(result);
        }
        return nil;
    }
    NSData *data = (__bridge_transfer NSData *)result;
    NSString *token = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if ([token length] == 0) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:CloudServiceClientErrorKeychainFailed
                                     description:@"The Keychain operator token item is empty or not UTF-8. Nothing was sent."];
        }
        return nil;
    }
    return token;
}

#pragma mark - Transport (the one request builder)

- (NSURLSession *)session {
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    [configuration setTimeoutIntervalForRequest:30];
    // Completions land on the main queue: every caller is UI-side.
    return [NSURLSession sessionWithConfiguration:configuration
                                         delegate:nil
                                    delegateQueue:[NSOperationQueue mainQueue]];
}

// Path-segment escaping for bucket names / object keys: escape each
// "/"-separated segment on its own so a key's slashes stay path
// structure (§7.2 grammar allows them) and nothing else can break out
// of the segment it arrived in.
- (NSString *)escapedPathSegments:(NSString *)raw {
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"._-"];
    NSMutableArray<NSString *> *escaped = [NSMutableArray array];
    for (NSString *segment in [raw componentsSeparatedByString:@"/"]) {
        [escaped addObject:[segment stringByAddingPercentEncodingWithAllowedCharacters:allowed]];
    }
    return [escaped componentsJoinedByString:@"/"];
}

// ONE request to the loopback service. The operator token (when the
// route requires auth) is fetched HERE, at call time, used to set this
// request's Authorization header, and released when this method's
// scope ends — it travels no further (§5.5 / D4). Completion runs on
// the main queue with the §8 envelope's "data" payload (dictionary,
// array, or NSNull for an empty success) or an error in this client's
// domain (API code preserved in userInfo, see header).
- (void)performRequestWithMethod:(NSString *)method
                            path:(NSString *)path
                      queryItems:(nullable NSArray<NSURLQueryItem *> *)queryItems
                      bodyObject:(nullable NSDictionary *)bodyObject
                    requiresAuth:(BOOL)requiresAuth
                      completion:(void (^)(id _Nullable data, NSError * _Nullable error))completion {
    NSError *urlError = nil;
    NSURL *url = [self requestURLWithPath:path queryItems:queryItems error:&urlError];
    if (url == nil) {
        completion(nil, urlError);
        return;
    }
    NSString *token = nil;
    if (requiresAuth) {
        NSError *tokenError = nil;
        token = [self fetchOperatorTokenForRequestBuild:&tokenError];
        if (token == nil) {
            completion(nil, tokenError);
            return;
        }
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:method];
    if (token != nil) {
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }
    token = nil;  // the header now carries the only copy the request needs
    if (bodyObject != nil) {
        NSData *body = [NSJSONSerialization dataWithJSONObject:bodyObject options:0 error:NULL];
        [request setHTTPBody:body];
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Snowfell/0.1.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [[self session] dataTaskWithRequest:request
                                                   completionHandler:^(NSData *data, NSURLResponse *response, NSError *transportError) {
        if (transportError != nil) {
            completion(nil, [[self class] errorWithCode:CloudServiceClientErrorTransport
                                            description:[NSString stringWithFormat:
                                                         @"Transport failed: %@", transportError.localizedDescription]]);
            return;
        }
        NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
        id parsed = nil;
        if (data != nil && [data length] > 0) {
            parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        }
        NSDictionary *envelope = [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
        // §8 error envelope, on ANY status: the API code is the fact.
        NSDictionary *apiError = [envelope[@"error"] isKindOfClass:[NSDictionary class]]
            ? envelope[@"error"] : nil;
        if (apiError != nil) {
            NSString *apiCode = [apiError[@"code"] isKindOfClass:[NSString class]]
                ? apiError[@"code"] : @"internal";
            NSString *message = [apiError[@"message"] isKindOfClass:[NSString class]]
                ? apiError[@"message"] : @"The service returned an error.";
            NSMutableDictionary *userInfo = [@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"%@ (%@)", message, apiCode]} mutableCopy];
            userInfo[CloudServiceErrorCodeKey] = apiCode;
            if ([apiError[@"detail"] isKindOfClass:[NSDictionary class]]) {
                userInfo[CloudServiceErrorDetailKey] = apiError[@"detail"];
            }
            userInfo[CloudServiceHTTPStatusKey] = @(statusCode);
            completion(nil, [NSError errorWithDomain:CloudServiceClientErrorDomain
                                                 code:CloudServiceClientErrorAPI
                                             userInfo:userInfo]);
            return;
        }
        if (statusCode < 200 || statusCode >= 300) {
            NSMutableDictionary *userInfo = [@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"The storage service answered HTTP %ld.", (long)statusCode]} mutableCopy];
            userInfo[CloudServiceHTTPStatusKey] = @(statusCode);
            completion(nil, [NSError errorWithDomain:CloudServiceClientErrorDomain
                                                 code:CloudServiceClientErrorHTTP
                                             userInfo:userInfo]);
            return;
        }
        if (envelope == nil) {
            // An empty success body (e.g. a bare 204) is a legitimate
            // payload for the DELETE routes; a NON-empty non-object
            // body is not.
            if (data != nil && [data length] > 0 && ![parsed isKindOfClass:[NSArray class]]) {
                completion(nil, [[self class] errorWithCode:CloudServiceClientErrorMalformedResponse
                                                description:@"The storage service's response was not a JSON envelope."]);
                return;
            }
            completion((parsed != nil) ? parsed : [NSNull null], nil);
            return;
        }
        id payload = envelope[@"data"];
        completion((payload != nil) ? payload : [NSNull null], nil);
    }];
    [task resume];
}

#pragma mark - Model mapping helpers

- (NSArray *)modelsFromData:(id)data factory:(id (^)(NSDictionary *))factory {
    if (![data isKindOfClass:[NSArray class]]) {
        return nil;
    }
    NSMutableArray *models = [NSMutableArray array];
    for (id row in (NSArray *)data) {
        if ([row isKindOfClass:[NSDictionary class]]) {
            [models addObject:factory(row)];
        }
    }
    return models;
}

- (NSError *)malformedErrorWithWhat:(NSString *)what {
    return [[self class] errorWithCode:CloudServiceClientErrorMalformedResponse
                           description:[NSString stringWithFormat:
                                        @"The storage service's %@ payload had an unexpected shape.", what]];
}

#pragma mark - Health

- (void)fetchHealthWithCompletion:(void (^)(CloudServiceHealth * _Nullable, NSError * _Nullable))completion {
    [self performRequestWithMethod:@"GET"
                              path:@"/v1/health"
                        queryItems:nil
                        bodyObject:nil
                      requiresAuth:NO
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        if (![data isKindOfClass:[NSDictionary class]]) {
            completion(nil, [self malformedErrorWithWhat:@"health"]);
            return;
        }
        completion([CloudServiceHealth fromJSONDictionary:data], nil);
    }];
}

#pragma mark - Tenants

- (void)fetchTenantsWithCompletion:(void (^)(NSArray<CloudTenant *> * _Nullable, NSError * _Nullable))completion {
    [self performRequestWithMethod:@"GET"
                              path:@"/v1/tenants"
                        queryItems:@[[NSURLQueryItem queryItemWithName:@"limit" value:@"200"]]
                        bodyObject:nil
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        NSArray *tenants = [self modelsFromData:data factory:^id(NSDictionary *row) {
            return [CloudTenant fromJSONDictionary:row];
        }];
        completion(tenants, (tenants != nil) ? nil : [self malformedErrorWithWhat:@"tenants list"]);
    }];
}

- (void)fetchTenantWithID:(int64_t)tenantID
               completion:(void (^)(CloudTenant * _Nullable, NSError * _Nullable))completion {
    [self performRequestWithMethod:@"GET"
                              path:[NSString stringWithFormat:@"/v1/tenants/%lld", (long long)tenantID]
                        queryItems:nil
                        bodyObject:nil
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        if (![data isKindOfClass:[NSDictionary class]]) {
            completion(nil, [self malformedErrorWithWhat:@"tenant"]);
            return;
        }
        completion([CloudTenant fromJSONDictionary:data], nil);
    }];
}

- (void)createTenantWithSlug:(NSString *)slug
                 displayName:(NSString *)displayName
                  completion:(void (^)(CloudTenant * _Nullable, NSError * _Nullable))completion {
    [self performRequestWithMethod:@"POST"
                              path:@"/v1/tenants"
                        queryItems:nil
                        bodyObject:@{@"slug": slug, @"display_name": displayName}
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        if (![data isKindOfClass:[NSDictionary class]]) {
            completion(nil, [self malformedErrorWithWhat:@"created tenant"]);
            return;
        }
        completion([CloudTenant fromJSONDictionary:data], nil);
    }];
}

- (void)patchTenantWithID:(int64_t)tenantID
                   fields:(NSDictionary *)fields
               completion:(void (^)(CloudTenant * _Nullable, NSError * _Nullable))completion {
    [self performRequestWithMethod:@"PATCH"
                              path:[NSString stringWithFormat:@"/v1/tenants/%lld", (long long)tenantID]
                        queryItems:nil
                        bodyObject:fields
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        if (![data isKindOfClass:[NSDictionary class]]) {
            completion(nil, [self malformedErrorWithWhat:@"patched tenant"]);
            return;
        }
        completion([CloudTenant fromJSONDictionary:data], nil);
    }];
}

- (void)closeTenantWithID:(int64_t)tenantID
               completion:(void (^)(BOOL, NSError * _Nullable))completion {
    [self performRequestWithMethod:@"DELETE"
                              path:[NSString stringWithFormat:@"/v1/tenants/%lld", (long long)tenantID]
                        queryItems:nil
                        bodyObject:nil
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        completion(error == nil, error);
    }];
}

- (void)fetchUsageForTenantID:(int64_t)tenantID
                   completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    [self performRequestWithMethod:@"GET"
                              path:[NSString stringWithFormat:@"/v1/tenants/%lld/usage", (long long)tenantID]
                        queryItems:nil
                        bodyObject:nil
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        if (![data isKindOfClass:[NSDictionary class]]) {
            completion(nil, [self malformedErrorWithWhat:@"usage"]);
            return;
        }
        completion(data, nil);
    }];
}

#pragma mark - Logins

- (NSString *)loginsPathForTenantID:(int64_t)tenantID {
    return [NSString stringWithFormat:@"/v1/tenants/%lld/logins", (long long)tenantID];
}

- (void)fetchLoginsForTenantID:(int64_t)tenantID
                    completion:(void (^)(NSArray<CloudLogin *> * _Nullable, NSError * _Nullable))completion {
    [self performRequestWithMethod:@"GET"
                              path:[self loginsPathForTenantID:tenantID]
                        queryItems:@[[NSURLQueryItem queryItemWithName:@"limit" value:@"200"]]
                        bodyObject:nil
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        NSArray *logins = [self modelsFromData:data factory:^id(NSDictionary *row) {
            return [CloudLogin fromJSONDictionary:row];
        }];
        completion(logins, (logins != nil) ? nil : [self malformedErrorWithWhat:@"logins list"]);
    }];
}

- (void)createLoginForTenantID:(int64_t)tenantID
                      username:(NSString *)username
                   displayName:(NSString *)displayName
                          role:(NSString *)role
                      password:(NSString *)password
                    completion:(void (^)(CloudLogin * _Nullable, NSError * _Nullable))completion {
    NSDictionary *body = @{@"username": username,
                           @"display_name": displayName,
                           @"role": role,
                           @"password": password};
    [self performRequestWithMethod:@"POST"
                              path:[self loginsPathForTenantID:tenantID]
                        queryItems:nil
                        bodyObject:body
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        if (![data isKindOfClass:[NSDictionary class]]) {
            completion(nil, [self malformedErrorWithWhat:@"created login"]);
            return;
        }
        completion([CloudLogin fromJSONDictionary:data], nil);
    }];
}

- (void)patchLoginForTenantID:(int64_t)tenantID
                      loginID:(int64_t)loginID
                       fields:(NSDictionary *)fields
                   completion:(void (^)(CloudLogin * _Nullable, NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"%@/%lld", [self loginsPathForTenantID:tenantID], (long long)loginID];
    [self performRequestWithMethod:@"PATCH"
                              path:path
                        queryItems:nil
                        bodyObject:fields
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        if (![data isKindOfClass:[NSDictionary class]]) {
            completion(nil, [self malformedErrorWithWhat:@"patched login"]);
            return;
        }
        completion([CloudLogin fromJSONDictionary:data], nil);
    }];
}

- (void)deleteLoginForTenantID:(int64_t)tenantID
                       loginID:(int64_t)loginID
                    completion:(void (^)(BOOL, NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"%@/%lld", [self loginsPathForTenantID:tenantID], (long long)loginID];
    [self performRequestWithMethod:@"DELETE"
                              path:path
                        queryItems:nil
                        bodyObject:nil
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        completion(error == nil, error);
    }];
}

- (void)setPasswordForTenantID:(int64_t)tenantID
                       loginID:(int64_t)loginID
                   newPassword:(NSString *)newPassword
                    completion:(void (^)(BOOL, NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"%@/%lld/password", [self loginsPathForTenantID:tenantID], (long long)loginID];
    [self performRequestWithMethod:@"POST"
                              path:path
                        queryItems:nil
                        bodyObject:@{@"new_password": newPassword}
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        completion(error == nil, error);
    }];
}

- (void)issuePasswordResetForTenantID:(int64_t)tenantID
                              loginID:(int64_t)loginID
                           completion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"%@/%lld/password-resets", [self loginsPathForTenantID:tenantID], (long long)loginID];
    [self performRequestWithMethod:@"POST"
                              path:path
                        queryItems:nil
                        bodyObject:nil
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        // §5.4: the plaintext token rides this ONE response. Accept the
        // token as the data string itself or under "token".
        if ([data isKindOfClass:[NSString class]] && [data length] > 0) {
            completion(data, nil);
            return;
        }
        if ([data isKindOfClass:[NSDictionary class]]) {
            id token = data[@"token"];
            if ([token isKindOfClass:[NSString class]] && [token length] > 0) {
                completion(token, nil);
                return;
            }
        }
        completion(nil, [self malformedErrorWithWhat:@"password reset"]);
    }];
}

#pragma mark - Backends

- (void)fetchBackendsWithCompletion:(void (^)(NSArray<NSDictionary *> * _Nullable, NSError * _Nullable))completion {
    [self performRequestWithMethod:@"GET"
                              path:@"/v1/backends"
                        queryItems:@[[NSURLQueryItem queryItemWithName:@"limit" value:@"200"]]
                        bodyObject:nil
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        if (![data isKindOfClass:[NSArray class]]) {
            completion(nil, [self malformedErrorWithWhat:@"backends list"]);
            return;
        }
        NSMutableArray<NSDictionary *> *backends = [NSMutableArray array];
        for (id row in (NSArray *)data) {
            if ([row isKindOfClass:[NSDictionary class]]) {
                [backends addObject:row];
            }
        }
        completion(backends, nil);
    }];
}

#pragma mark - Buckets & objects

- (NSArray<NSURLQueryItem *> *)tenantScopeQueryItemsForTenantID:(int64_t)tenantID {
    return @[[NSURLQueryItem queryItemWithName:@"tenant"
                                         value:[NSString stringWithFormat:@"%lld", (long long)tenantID]]];
}

- (void)fetchBucketsForTenantID:(int64_t)tenantID
                     completion:(void (^)(NSArray<CloudBucket *> * _Nullable, NSError * _Nullable))completion {
    NSMutableArray<NSURLQueryItem *> *query = [[self tenantScopeQueryItemsForTenantID:tenantID] mutableCopy];
    [query addObject:[NSURLQueryItem queryItemWithName:@"limit" value:@"200"]];
    [self performRequestWithMethod:@"GET"
                              path:@"/v1/buckets"
                        queryItems:query
                        bodyObject:nil
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        NSArray *buckets = [self modelsFromData:data factory:^id(NSDictionary *row) {
            return [CloudBucket fromJSONDictionary:row];
        }];
        completion(buckets, (buckets != nil) ? nil : [self malformedErrorWithWhat:@"buckets list"]);
    }];
}

- (void)createBucketForTenantID:(int64_t)tenantID
                           name:(NSString *)name
                      backendID:(int64_t)backendID
                     completion:(void (^)(CloudBucket * _Nullable, NSError * _Nullable))completion {
    NSMutableDictionary *body = [@{@"name": name} mutableCopy];
    if (backendID > 0) {
        body[@"backend_id"] = @(backendID);
    }
    [self performRequestWithMethod:@"POST"
                              path:@"/v1/buckets"
                        queryItems:[self tenantScopeQueryItemsForTenantID:tenantID]
                        bodyObject:body
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        if (![data isKindOfClass:[NSDictionary class]]) {
            completion(nil, [self malformedErrorWithWhat:@"created bucket"]);
            return;
        }
        completion([CloudBucket fromJSONDictionary:data], nil);
    }];
}

- (void)deleteBucketForTenantID:(int64_t)tenantID
                           name:(NSString *)name
                     completion:(void (^)(BOOL, NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"/v1/buckets/%@", [self escapedPathSegments:name]];
    [self performRequestWithMethod:@"DELETE"
                              path:path
                        queryItems:[self tenantScopeQueryItemsForTenantID:tenantID]
                        bodyObject:nil
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        completion(error == nil, error);
    }];
}

- (void)fetchObjectsForTenantID:(int64_t)tenantID
                     bucketName:(NSString *)bucketName
                     completion:(void (^)(NSArray<CloudObject *> * _Nullable, NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"/v1/buckets/%@/objects",
                      [self escapedPathSegments:bucketName]];
    NSMutableArray<NSURLQueryItem *> *query = [[self tenantScopeQueryItemsForTenantID:tenantID] mutableCopy];
    [query addObject:[NSURLQueryItem queryItemWithName:@"limit" value:@"200"]];
    [self performRequestWithMethod:@"GET"
                              path:path
                        queryItems:query
                        bodyObject:nil
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        NSArray *objects = [self modelsFromData:data factory:^id(NSDictionary *row) {
            return [CloudObject fromJSONDictionary:row];
        }];
        completion(objects, (objects != nil) ? nil : [self malformedErrorWithWhat:@"objects list"]);
    }];
}

- (void)deleteObjectForTenantID:(int64_t)tenantID
                     bucketName:(NSString *)bucketName
                            key:(NSString *)key
                     completion:(void (^)(BOOL, NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"/v1/buckets/%@/objects/%@",
                      [self escapedPathSegments:bucketName],
                      [self escapedPathSegments:key]];
    [self performRequestWithMethod:@"DELETE"
                              path:path
                        queryItems:[self tenantScopeQueryItemsForTenantID:tenantID]
                        bodyObject:nil
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        completion(error == nil, error);
    }];
}

#pragma mark - Audit

- (void)fetchAuditForTenantID:(int64_t)tenantID
                   completion:(void (^)(NSArray<CloudAuditEntry *> * _Nullable, NSError * _Nullable))completion {
    NSMutableArray<NSURLQueryItem *> *query = [NSMutableArray array];
    if (tenantID > 0) {
        [query addObject:[NSURLQueryItem queryItemWithName:@"tenant"
                                                     value:[NSString stringWithFormat:@"%lld", (long long)tenantID]]];
    }
    [query addObject:[NSURLQueryItem queryItemWithName:@"limit" value:@"100"]];
    [self performRequestWithMethod:@"GET"
                              path:@"/v1/audit"
                        queryItems:query
                        bodyObject:nil
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        NSArray *entries = [self modelsFromData:data factory:^id(NSDictionary *row) {
            return [CloudAuditEntry fromJSONDictionary:row];
        }];
        completion(entries, (entries != nil) ? nil : [self malformedErrorWithWhat:@"audit list"]);
    }];
}

#pragma mark - CMS: collections (§13.7)

- (void)fetchCollectionsForTenantID:(int64_t)tenantID
                         completion:(void (^)(NSArray<CloudCollection *> * _Nullable, NSError * _Nullable))completion {
    NSMutableArray<NSURLQueryItem *> *query = [[self tenantScopeQueryItemsForTenantID:tenantID] mutableCopy];
    [query addObject:[NSURLQueryItem queryItemWithName:@"limit" value:@"200"]];
    [self performRequestWithMethod:@"GET"
                              path:@"/v1/collections"
                        queryItems:query
                        bodyObject:nil
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        NSArray *collections = [self modelsFromData:data factory:^id(NSDictionary *row) {
            return [CloudCollection fromJSONDictionary:row];
        }];
        completion(collections, (collections != nil) ? nil : [self malformedErrorWithWhat:@"collections list"]);
    }];
}

- (void)createCollectionForTenantID:(int64_t)tenantID
                               name:(NSString *)name
                               slug:(NSString *)slug
                           parentID:(int64_t)parentID
                         completion:(void (^)(CloudCollection * _Nullable, NSError * _Nullable))completion {
    NSMutableDictionary *body = [@{@"name": name, @"slug": slug} mutableCopy];
    if (parentID > 0) {
        body[@"parent_id"] = @(parentID);
    }
    [self performRequestWithMethod:@"POST"
                              path:@"/v1/collections"
                        queryItems:[self tenantScopeQueryItemsForTenantID:tenantID]
                        bodyObject:body
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        if (![data isKindOfClass:[NSDictionary class]]) {
            completion(nil, [self malformedErrorWithWhat:@"created collection"]);
            return;
        }
        completion([CloudCollection fromJSONDictionary:data], nil);
    }];
}

- (void)deleteCollectionForTenantID:(int64_t)tenantID
                       collectionID:(int64_t)collectionID
                         completion:(void (^)(BOOL, NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"/v1/collections/%lld", (long long)collectionID];
    [self performRequestWithMethod:@"DELETE"
                              path:path
                        queryItems:[self tenantScopeQueryItemsForTenantID:tenantID]
                        bodyObject:nil
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        completion(error == nil, error);
    }];
}

#pragma mark - CMS: content items (§13.7)

- (void)fetchContentForTenantID:(int64_t)tenantID
                   collectionID:(int64_t)collectionID
                           kind:(nullable NSString *)kind
                          state:(nullable NSString *)state
                          query:(nullable NSString *)query
                     completion:(void (^)(NSArray<CloudContentItem *> * _Nullable, NSError * _Nullable))completion {
    NSMutableArray<NSURLQueryItem *> *queryItems = [[self tenantScopeQueryItemsForTenantID:tenantID] mutableCopy];
    [queryItems addObject:[NSURLQueryItem queryItemWithName:@"limit" value:@"200"]];
    if (collectionID > 0) {
        [queryItems addObject:[NSURLQueryItem queryItemWithName:@"collection_id"
                                                          value:[NSString stringWithFormat:@"%lld", (long long)collectionID]]];
    }
    if ([kind length] > 0) {
        [queryItems addObject:[NSURLQueryItem queryItemWithName:@"kind" value:kind]];
    }
    if ([state length] > 0) {
        [queryItems addObject:[NSURLQueryItem queryItemWithName:@"state" value:state]];
    }
    // q is defined by the §13.5 search route; the plain list route
    // carries the structural filters alone.
    NSString *path = @"/v1/content";
    if ([query length] > 0) {
        path = @"/v1/search/content";
        [queryItems addObject:[NSURLQueryItem queryItemWithName:@"q" value:query]];
    }
    [self performRequestWithMethod:@"GET"
                              path:path
                        queryItems:queryItems
                        bodyObject:nil
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        NSArray *items = [self modelsFromData:data factory:^id(NSDictionary *row) {
            return [CloudContentItem fromJSONDictionary:row];
        }];
        completion(items, (items != nil) ? nil : [self malformedErrorWithWhat:@"content list"]);
    }];
}

- (NSString *)contentPathForTenantID:(int64_t)tenantID contentID:(int64_t)contentID {
    return [NSString stringWithFormat:@"/v1/content/%lld", (long long)contentID];
}

- (void)fetchContentItemForTenantID:(int64_t)tenantID
                          contentID:(int64_t)contentID
                         completion:(void (^)(CloudContentItem * _Nullable, NSError * _Nullable))completion {
    [self performRequestWithMethod:@"GET"
                              path:[self contentPathForTenantID:tenantID contentID:contentID]
                        queryItems:[self tenantScopeQueryItemsForTenantID:tenantID]
                        bodyObject:nil
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        if (![data isKindOfClass:[NSDictionary class]]) {
            completion(nil, [self malformedErrorWithWhat:@"content item"]);
            return;
        }
        completion([CloudContentItem fromJSONDictionary:data], nil);
    }];
}

- (void)createContentForTenantID:(int64_t)tenantID
                            slug:(NSString *)slug
                           title:(NSString *)title
                            kind:(NSString *)kind
                    collectionID:(int64_t)collectionID
                          blobID:(int64_t)blobID
                      completion:(void (^)(CloudContentItem * _Nullable, NSError * _Nullable))completion {
    NSMutableDictionary *body = [@{@"slug": slug,
                                   @"title": title,
                                   @"kind": kind,
                                   @"blob_id": @(blobID)} mutableCopy];
    if (collectionID > 0) {
        body[@"collection_id"] = @(collectionID);
    }
    [self performRequestWithMethod:@"POST"
                              path:@"/v1/content"
                        queryItems:[self tenantScopeQueryItemsForTenantID:tenantID]
                        bodyObject:body
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        if (![data isKindOfClass:[NSDictionary class]]) {
            completion(nil, [self malformedErrorWithWhat:@"created content item"]);
            return;
        }
        completion([CloudContentItem fromJSONDictionary:data], nil);
    }];
}

- (void)patchContentForTenantID:(int64_t)tenantID
                      contentID:(int64_t)contentID
                         fields:(NSDictionary *)fields
                     completion:(void (^)(CloudContentItem * _Nullable, NSError * _Nullable))completion {
    [self performRequestWithMethod:@"PATCH"
                              path:[self contentPathForTenantID:tenantID contentID:contentID]
                        queryItems:[self tenantScopeQueryItemsForTenantID:tenantID]
                        bodyObject:fields
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        if (![data isKindOfClass:[NSDictionary class]]) {
            completion(nil, [self malformedErrorWithWhat:@"patched content item"]);
            return;
        }
        completion([CloudContentItem fromJSONDictionary:data], nil);
    }];
}

- (void)deleteContentForTenantID:(int64_t)tenantID
                       contentID:(int64_t)contentID
                      completion:(void (^)(BOOL, NSError * _Nullable))completion {
    [self performRequestWithMethod:@"DELETE"
                              path:[self contentPathForTenantID:tenantID contentID:contentID]
                        queryItems:[self tenantScopeQueryItemsForTenantID:tenantID]
                        bodyObject:nil
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        completion(error == nil, error);
    }];
}

#pragma mark - CMS: versions, rollback, state (§13.7)

- (void)fetchVersionsForTenantID:(int64_t)tenantID
                       contentID:(int64_t)contentID
                      completion:(void (^)(NSArray<CloudContentVersion *> * _Nullable, NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"%@/versions",
                      [self contentPathForTenantID:tenantID contentID:contentID]];
    NSMutableArray<NSURLQueryItem *> *query = [[self tenantScopeQueryItemsForTenantID:tenantID] mutableCopy];
    [query addObject:[NSURLQueryItem queryItemWithName:@"limit" value:@"200"]];
    [self performRequestWithMethod:@"GET"
                              path:path
                        queryItems:query
                        bodyObject:nil
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        NSArray *versions = [self modelsFromData:data factory:^id(NSDictionary *row) {
            return [CloudContentVersion fromJSONDictionary:row];
        }];
        completion(versions, (versions != nil) ? nil : [self malformedErrorWithWhat:@"content versions list"]);
    }];
}

- (void)createVersionForTenantID:(int64_t)tenantID
                       contentID:(int64_t)contentID
                          blobID:(int64_t)blobID
                            note:(nullable NSString *)note
                      completion:(void (^)(CloudContentVersion * _Nullable, NSError * _Nullable))completion {
    NSMutableDictionary *body = [@{@"blob_id": @(blobID)} mutableCopy];
    if ([note length] > 0) {
        body[@"note"] = note;
    }
    NSString *path = [NSString stringWithFormat:@"%@/versions",
                      [self contentPathForTenantID:tenantID contentID:contentID]];
    [self performRequestWithMethod:@"POST"
                              path:path
                        queryItems:[self tenantScopeQueryItemsForTenantID:tenantID]
                        bodyObject:body
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        if (![data isKindOfClass:[NSDictionary class]]) {
            completion(nil, [self malformedErrorWithWhat:@"created content version"]);
            return;
        }
        completion([CloudContentVersion fromJSONDictionary:data], nil);
    }];
}

- (void)rollbackContentForTenantID:(int64_t)tenantID
                         contentID:(int64_t)contentID
                       toVersionNo:(int64_t)versionNo
                        completion:(void (^)(CloudContentVersion * _Nullable, NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"%@/rollback",
                      [self contentPathForTenantID:tenantID contentID:contentID]];
    [self performRequestWithMethod:@"POST"
                              path:path
                        queryItems:[self tenantScopeQueryItemsForTenantID:tenantID]
                        bodyObject:@{@"version_no": @(versionNo)}
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        if (![data isKindOfClass:[NSDictionary class]]) {
            completion(nil, [self malformedErrorWithWhat:@"rollback version"]);
            return;
        }
        completion([CloudContentVersion fromJSONDictionary:data], nil);
    }];
}

- (void)setStateForContentForTenantID:(int64_t)tenantID
                            contentID:(int64_t)contentID
                                state:(NSString *)state
                           completion:(void (^)(CloudContentItem * _Nullable, NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"%@/state",
                      [self contentPathForTenantID:tenantID contentID:contentID]];
    [self performRequestWithMethod:@"POST"
                              path:path
                        queryItems:[self tenantScopeQueryItemsForTenantID:tenantID]
                        bodyObject:@{@"state": state}
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        if (![data isKindOfClass:[NSDictionary class]]) {
            completion(nil, [self malformedErrorWithWhat:@"content state change"]);
            return;
        }
        completion([CloudContentItem fromJSONDictionary:data], nil);
    }];
}

#pragma mark - Dedup accounting + GC (§13.6 / §13.3)

- (void)fetchDedupForTenantID:(int64_t)tenantID
                   completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    [self fetchUsageForTenantID:tenantID
                     completion:^(NSDictionary *usage, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        id dedup = usage[@"dedup"];
        if (![dedup isKindOfClass:[NSDictionary class]]) {
            completion(nil, [self malformedErrorWithWhat:@"usage dedup block"]);
            return;
        }
        completion(dedup, nil);
    }];
}

- (void)runGCForTenantID:(int64_t)tenantID
                  dryRun:(BOOL)dryRun
              completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    // The operator route (§13.3): /v1/admin/gc with the scope named
    // in the body. Aggregates only come back (§13.8) — the dictionary
    // is returned verbatim, figures uncompressed.
    NSDictionary *body = @{@"tenant_id": @(tenantID), @"dry_run": @(dryRun)};
    [self performRequestWithMethod:@"POST"
                              path:@"/v1/admin/gc"
                        queryItems:nil
                        bodyObject:body
                      requiresAuth:YES
                        completion:^(id data, NSError *error) {
        if (error != nil) {
            completion(nil, error);
            return;
        }
        if (![data isKindOfClass:[NSDictionary class]]) {
            completion(nil, [self malformedErrorWithWhat:@"GC result"]);
            return;
        }
        completion(data, nil);
    }];
}

@end
