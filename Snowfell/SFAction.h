// SFAction — one row of the sf_actions manifest (SF-T5; design record §3:
// "actions are data (sf_actions), not code"). SnapshotStore reads the rows
// from the verified snapshot; the Orchestration Center renders the
// manifest from them and generates the Dispatch Composer's form from
// payloadSchemaJSON. Nothing in this class names an action: a new
// manifest row in a future snapshot becomes composable with no rebuild,
// subject to the lane rules the build implements (see
// OrchestrationViewController and the README's SF-T5 section).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SFAction : NSObject

@property (nonatomic, copy) NSString *actionID;            // sf_actions.id, e.g. "media.convert.proxy"
@property (nonatomic, copy) NSString *name;                // sf_actions.name
@property (nonatomic, copy) NSString *kind;                // sf_actions.kind
@property (nonatomic, copy) NSString *target;              // sf_actions.target (destination/operator text, verbatim)
@property (nonatomic, copy) NSString *payloadSchemaJSON;   // sf_actions.payload_schema_json, verbatim
@property (nonatomic, copy) NSString *riskClass;           // sf_actions.risk_class
@property (nonatomic, assign) BOOL requiresConfirm;        // sf_actions.requires_confirm
@property (nonatomic, assign) BOOL enabled;                // sf_actions.enabled

// payload_schema_json parsed ({} when it does not parse — the composer
// then shows the verbatim schema and offers no form).
@property (nonatomic, copy, readonly) NSDictionary *payloadSchema;

// The schema's keys in MANIFEST order (the order they appear in the
// stored JSON text — NSJSONSerialization does not preserve order, so the
// keys are scanned from the verbatim string).
@property (nonatomic, copy, readonly) NSArray<NSString *> *schemaKeysInOrder;

@end

NS_ASSUME_NONNULL_END
