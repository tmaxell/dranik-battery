// Independently authored from observed runtime interfaces; no third-party implementation.
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <notify.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include "dranik_native.h"

// Declaration only, used to give ARC the correct init-family ownership rules.
// The selector and full ABI are checked before this message is ever sent.
@interface NSObject (DNRuntimeClientInitialization)
- (instancetype)initWithClientName:(NSString *)name;
@end

static NSString *const DNDomain = @"com.dranik.native";
static CFStringRef const DNPreferences = CFSTR("com.apple.smartcharging.topoffprotection");

static NSError *DNError(NSString *message) {
    return [NSError errorWithDomain:DNDomain code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static void DNSetError(char **out, NSError *error) {
    if (out) *out = strdup([[NSString stringWithFormat:@"%@: %ld: %@", error.domain,
                            (long)error.code, error.localizedDescription] UTF8String]);
}
static const char *DNUnqualified(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type;
}
static BOOL DNCheck(Class cls, const char *name, const char *result,
                    unsigned count, const char *arg2, const char *arg3, NSError **error) {
    Method method = class_getInstanceMethod(cls, sel_registerName(name));
    if (!method) { *error = DNError([NSString stringWithFormat:@"Missing PowerUI method %s", name]); return NO; }
    char *type = method_copyReturnType(method);
    BOOL valid = type && strcmp(DNUnqualified(type), result) == 0 && method_getNumberOfArguments(method) == count;
    free(type);
    const char *expected[] = {"@", ":", arg2, arg3};
    for (unsigned index = 0; valid && index < count; index++) {
        type = method_copyArgumentType(method, index);
        valid = type && expected[index] && strcmp(DNUnqualified(type), expected[index]) == 0;
        free(type);
    }
    if (!valid) *error = DNError([NSString stringWithFormat:@"Unexpected PowerUI ABI for %s", name]);
    return valid;
}
static id DNClient(NSError **error) {
    // Intentionally retain the framework handle for process lifetime: its classes
    // and method implementations must not be unloaded while registered with ObjC.
    if (!dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI", RTLD_NOW | RTLD_LOCAL)) {
        const char *reason = dlerror();
        *error = DNError([NSString stringWithFormat:@"PowerUI unavailable: %s", reason ?: "unknown error"]);
        return nil;
    }
    Class cls = NSClassFromString(@"PowerUISmartChargeClient");
    if (!cls) { *error = DNError(@"PowerUISmartChargeClient unavailable"); return nil; }
    if (!DNCheck(cls, "initWithClientName:", "@", 3, "@", NULL, error) ||
        !DNCheck(cls, "isMCLSupported", "B", 2, NULL, NULL, error) ||
        !DNCheck(cls, "getMCLLimitWithError:", "C", 3, "^@", NULL, error) ||
        !DNCheck(cls, "isMCLCurrentlyEnabled:", "Q", 3, "^@", NULL, error) ||
        !DNCheck(cls, "availableChargeLimitsWithError:", "@", 3, "^@", NULL, error) ||
        !DNCheck(cls, "setMCLLimit:error:", "B", 4, "C", "^@", error) ||
        !DNCheck(cls, "enableMCL:", "B", 3, "^@", NULL, error) ||
        !DNCheck(cls, "disableMCL:", "B", 3, "^@", NULL, error)) return nil;
    id client = [[cls alloc] initWithClientName:@"com.dranik.native"];
    if (!client) *error = DNError(@"PowerUI client initialization returned nil");
#if !__has_feature(objc_arc)
    return [client autorelease];
#else
    return client;
#endif
}
static BOOL DNSupported(id client) {
    return ((BOOL (*)(id, SEL))objc_msgSend)(client, sel_registerName("isMCLSupported"));
}
static unsigned long long DNEnabled(id client, NSError **error) {
    return ((unsigned long long (*)(id, SEL, NSError **))objc_msgSend)(client, sel_registerName("isMCLCurrentlyEnabled:"), error);
}
static NSArray *DNAvailable(id client, NSError **error) {
    id value = ((id (*)(id, SEL, NSError **))objc_msgSend)(client, sel_registerName("availableChargeLimitsWithError:"), error);
    if (*error) return nil;
    if (![value isKindOfClass:[NSArray class]]) { *error = DNError(@"PowerUI returned invalid available limits"); return nil; }
    for (id item in value) {
        if (![item isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)item) == CFBooleanGetTypeID() ||
            [item doubleValue] != [item intValue] || [item intValue] < 1 || [item intValue] > 100) {
            *error = DNError(@"PowerUI returned an invalid available limit"); return nil;
        }
    }
    return value;
}
static BOOL DNChangeEnabled(id client, BOOL enabled, NSError **error) {
    BOOL ok = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(client,
                    sel_registerName(enabled ? "enableMCL:" : "disableMCL:"), error);
    if (!ok && !*error) *error = DNError(@"PowerUI rejected enable/disable without an error");
    return ok && !*error;
}
static BOOL DNOverride(BOOL *active, NSError **error) {
    int token = 0;
    uint32_t status = notify_register_check("com.apple.system.powersources.chargingtofulloverride", &token);
    if (status != NOTIFY_STATUS_OK) { *error = DNError(@"Cannot register full-charge override observation"); return NO; }
    uint64_t state = 0;
    status = notify_get_state(token, &state);
    uint32_t cancelStatus = notify_cancel(token);
    if (status != NOTIFY_STATUS_OK || cancelStatus != NOTIFY_STATUS_OK) {
        *error = DNError(@"Cannot read/cancel full-charge override observation"); return NO;
    }
    *active = state != 0;
    return YES;
}
static BOOL DNRoot(NSError **error) {
    if (geteuid() != 0) { *error = DNError(@"Native charge mutations require effective UID 0"); return NO; }
    return YES;
}
static BOOL DNRequest(int limit, NSError **error) {
    if (!DNRoot(error)) return NO;
    if (limit < 50 || limit > 100) { *error = DNError(@"Native limit must be an integer in 50...100"); return NO; }
    id client = DNClient(error);
    if (!client) return NO;
    if (!DNSupported(client)) { *error = DNError(@"Native charge limiting is unsupported"); return NO; }
    if (limit == 100) return DNChangeEnabled(client, NO, error);
    NSArray *available = DNAvailable(client, error);
    if (!available) return NO;
    BOOL useSlider = [available containsObject:@(limit)];
    if (!useSlider && [NSProcessInfo processInfo].operatingSystemVersion.majorVersion != 27) {
        *error = DNError(@"Non-slider exact native limits are supported only on macOS 27"); return NO;
    }
    unsigned long long enabled = DNEnabled(client, error);
    if (*error) return NO;
    // Enabling can reset the native target. Always enable before assigning it.
    if (!enabled && !DNChangeEnabled(client, YES, error)) return NO;
    if (useSlider) {
        BOOL ok = ((BOOL (*)(id, SEL, unsigned char, NSError **))objc_msgSend)(client,
                    sel_registerName("setMCLLimit:error:"), (unsigned char)limit, error);
        if (!ok || *error) { if (!*error) *error = DNError(@"PowerUI rejected limit without an error; enable may already have changed policy"); return NO; }
    }
    if (!useSlider) {
        // Effective UID 0 makes currentUser the root domain, never the GUI user.
        // CFPreferences is not transactional. On failure parent must inspect and
        // restore the previously persisted effective policy; never claim rollback.
        CFPreferencesSetValue(CFSTR("MCLFeatureState"), (__bridge CFNumberRef)@1,
                              DNPreferences, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesSetValue(CFSTR("mclLimitValue"), (__bridge CFNumberRef)@(limit),
                              DNPreferences, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (!CFPreferencesSynchronize(DNPreferences, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)) {
            *error = DNError(@"Root charge preferences synchronization failed; policy may be partially changed"); return NO;
        }
        uint32_t status = notify_post("com.apple.smartcharging.defaultschanged");
        if (status != NOTIFY_STATUS_OK) {
            *error = DNError(@"Root charge preferences saved but change notification failed"); return NO;
        }
    }
    return YES;
}

int dn_native_snapshot(char **json, char **error) {
    if (json) *json = NULL;
    if (error) *error = NULL;
    if (!json || !error) return 0;
    @autoreleasepool {
        @try {
            NSError *failure = nil;
            id client = DNClient(&failure);
            if (!client) { DNSetError(error, failure); return 0; }
            BOOL supported = DNSupported(client);
            unsigned char limit = 0;
            unsigned long long enabled = 0;
            NSArray *available = @[];
            if (supported) {
                limit = ((unsigned char (*)(id, SEL, NSError **))objc_msgSend)(client, sel_registerName("getMCLLimitWithError:"), &failure);
                if (failure) { DNSetError(error, failure); return 0; }
                if (limit == 0 || limit > 100) { DNSetError(error, DNError(@"PowerUI returned an invalid limit")); return 0; }
                enabled = DNEnabled(client, &failure);
                if (failure) { DNSetError(error, failure); return 0; }
                available = DNAvailable(client, &failure);
                if (!available) { DNSetError(error, failure); return 0; }
            }
            BOOL override = NO;
            if (!DNOverride(&override, &failure)) { DNSetError(error, failure); return 0; }
            // Box explicit BOOL literals: a C comparison boxes as NSNumber(int),
            // which JSON serializes as 0/1 rather than the required false/true.
            NSDictionary *value = @{ @"supported":supported ? @YES : @NO, @"limit":@(limit),
                                      @"enabled":enabled ? @YES : @NO, @"availableLimits":available,
                                      @"fullChargeOverride":override ? @YES : @NO };
            NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:&failure];
            if (!data) { DNSetError(error, failure ?: DNError(@"Snapshot serialization failed")); return 0; }
            *json = malloc(data.length + 1);
            if (!*json) { DNSetError(error, DNError(@"Snapshot allocation failed")); return 0; }
            memcpy(*json, data.bytes, data.length);
            (*json)[data.length] = '\0';
            return 1;
        } @catch (NSException *exception) {
            DNSetError(error, DNError([NSString stringWithFormat:@"Objective-C exception %@: %@", exception.name, exception.reason]));
            return 0;
        }
    }
}
int dn_native_request_limit(int limit, char **error) {
    if (!error) return 0;
    *error = NULL;
    @autoreleasepool {
        @try {
            NSError *failure = nil;
            if (!DNRequest(limit, &failure)) { DNSetError(error, failure ?: DNError(@"Native mutation failed")); return 0; }
            return 1;
        } @catch (NSException *exception) {
            DNSetError(error, DNError([NSString stringWithFormat:@"Objective-C exception %@: %@; policy may be partially changed", exception.name, exception.reason]));
            return 0;
        }
    }
}
int dn_native_disable_limit(char **error) { return dn_native_request_limit(100, error); }
void dn_native_free(char *value) { free(value); }
