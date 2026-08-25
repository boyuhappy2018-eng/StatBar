// Adapted from the MIT-licensed exelban/Stats Apple Silicon sensor reader.
// Original copyright (c) 2019 Serhiy Mytrovtsiy.

#import "CHIDBridge.h"
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <IOKit/hidsystem/IOHIDServiceClient.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef double IOHIDFloat;

#define SB_IOHID_EVENT_FIELD_BASE(type) (type << 16)

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
extern IOHIDFloat IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

NSDictionary<NSString *, NSNumber *> *SBAppleSiliconSensors(int32_t page, int32_t usage, int32_t type) {
    static NSMutableDictionary<NSString *, NSArray *> *serviceCache;
    static NSMutableDictionary<NSString *, NSValue *> *clientCache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        serviceCache = [NSMutableDictionary dictionary];
        clientCache = [NSMutableDictionary dictionary];
    });
    NSString *cacheKey = [NSString stringWithFormat:@"%d:%d", page, usage];
    NSArray *cachedServices;
    @synchronized (serviceCache) {
        cachedServices = serviceCache[cacheKey];
        if (!cachedServices) {
            IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
            if (!client) return nil;
            NSDictionary *matching = @{ @"PrimaryUsagePage": @(page), @"PrimaryUsage": @(usage) };
            IOHIDEventSystemClientSetMatching(client, (__bridge CFDictionaryRef)matching);
            CFArrayRef discovered = IOHIDEventSystemClientCopyServices(client);
            if (!discovered) { CFRelease(client); return nil; }
            cachedServices = CFBridgingRelease(discovered);
            serviceCache[cacheKey] = cachedServices;
            // IOHIDServiceClient objects depend on their event-system client.
            // Keep one retained client per matching tuple for the process lifetime.
            clientCache[cacheKey] = [NSValue valueWithPointer:client];
        }
    }
    CFArrayRef services = (__bridge CFArrayRef)cachedServices;

    NSMutableDictionary<NSString *, NSNumber *> *result = [NSMutableDictionary dictionary];
    for (CFIndex index = 0; index < CFArrayGetCount(services); index++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, index);
        CFTypeRef property = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        NSString *name = property ? CFBridgingRelease(property) : nil;
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, type, 0, 0);
        if (!name || !event) continue;
        double value = IOHIDEventGetFloatValue(event, SB_IOHID_EVENT_FIELD_BASE(type));
        CFRelease(event);
        if (isfinite(value)) result[name] = @(value);
    }
    return result;
}

NSDictionary<NSString *, NSNumber *> *SBHIDDiagnostics(int32_t page, int32_t usage, int32_t type) {
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) return @{ @"client": @0 };
    NSDictionary *matchingDictionary = @{ @"PrimaryUsagePage": @(page), @"PrimaryUsage": @(usage) };
    IOHIDEventSystemClientSetMatching(client, (__bridge CFDictionaryRef)matchingDictionary);
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) { CFRelease(client); return @{ @"client": @1, @"services": @0 }; }
    NSInteger matching = 0, names = 0, events = 0;
    for (CFIndex index = 0; index < CFArrayGetCount(services); index++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, index);
        matching++;
        CFTypeRef name = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (name) { names++; CFRelease(name); }
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, type, 0, 0);
        if (event) { events++; CFRelease(event); }
    }
    NSDictionary *result = @{ @"client": @1, @"services": @(CFArrayGetCount(services)), @"matching": @(matching), @"names": @(names), @"events": @(events) };
    CFRelease(services);
    CFRelease(client);
    return result;
}
