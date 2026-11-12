// ItemFieldValue — one EAV row of the V3 Item Detail: a single
// sf_item_values record joined to its sf_fields definition, with the raw
// parts kept separate and displayValue composing the one rendering rule
// per value_kind (single-select → option_name; date → date_value; labels →
// the JSON array joined; everything else → text / number as stored).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ItemFieldValue : NSObject

@property (nonatomic, copy) NSString *fieldName;         // sf_fields.name
@property (nonatomic, copy, nullable) NSString *dataType;   // sf_fields.data_type
@property (nonatomic, copy) NSString *valueKind;         // sf_item_values.value_kind
@property (nonatomic, copy, nullable) NSString *textValue;
@property (nonatomic, strong, nullable) NSNumber *numberValue;
@property (nonatomic, copy, nullable) NSString *dateValue;
@property (nonatomic, copy, nullable) NSString *optionName; // single-select, as stored
@property (nonatomic, copy, nullable) NSString *jsonValue;  // labels / repository payloads

@property (nonatomic, readonly) NSString *displayValue;

@end

NS_ASSUME_NONNULL_END
