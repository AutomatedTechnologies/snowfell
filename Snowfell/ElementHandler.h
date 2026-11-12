// ElementHandler — one row of sf_element_handlers (design record §9.1):
// the element-kind → Academy-app routing table, stored as data so a new
// kind or handler is a DB row, never an app rebuild. SF-T3 renders these
// as display chips in V3 only — invocation is a later tranche (§9.1's
// open_app / url_scheme / dispatch_action paths land with SF-T5).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ElementHandler : NSObject

@property (nonatomic, copy) NSString *elementKind;       // sf_element_handlers.element_kind
@property (nonatomic, copy) NSString *handlerApp;        // sf_element_handlers.handler_app
@property (nonatomic, copy, nullable) NSString *handlerBundleID;
@property (nonatomic, copy) NSString *invocationKind;    // inline | open_app | url_scheme | dispatch_action

@property (nonatomic, readonly) NSString *chipDisplay;   // "markdown → MacDown"

@end

NS_ASSUME_NONNULL_END
