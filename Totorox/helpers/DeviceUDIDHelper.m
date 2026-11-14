#import "DeviceUDIDHelper.h"
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>

typedef CFTypeRef (*TotoroxMGCopyAnswerFn)(CFStringRef property);

NSString * _Nullable TotoroxCopyHardwareUDID(void) {
    void *gestalt = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    if (!gestalt) {
        return nil;
    }
    TotoroxMGCopyAnswerFn mgCopyAnswer = (TotoroxMGCopyAnswerFn)dlsym(gestalt, "MGCopyAnswer");
    if (!mgCopyAnswer) {
        return nil;
    }
    CFTypeRef rawValue = mgCopyAnswer(CFSTR("UniqueDeviceID"));
    if (!rawValue) {
        return nil;
    }
    if (CFGetTypeID(rawValue) != CFStringGetTypeID()) {
        CFRelease(rawValue);
        return nil;
    }
    NSString *udid = CFBridgingRelease(rawValue);
    NSString *trimmed = [udid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length > 0 ? trimmed : nil;
}
