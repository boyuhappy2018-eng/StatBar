#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Reads Apple Silicon telemetry published through the HID event system.
/// The returned dictionary maps the hardware Product label to a numeric value.
NSDictionary<NSString *, NSNumber *> * _Nullable SBAppleSiliconSensors(
    int32_t usagePage,
    int32_t usage,
    int32_t eventType
);

NSDictionary<NSString *, NSNumber *> *SBHIDDiagnostics(int32_t usagePage, int32_t usage, int32_t eventType);

NS_ASSUME_NONNULL_END
