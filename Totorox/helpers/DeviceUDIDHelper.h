#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Đọc UDID phần cứng (`UniqueDeviceID`) qua `libMobileGestalt.dylib` nếu môi trường cho phép.
/// Trả về `nil` trên Simulator hoặc thiết bị không có quyền truy cập MobileGestalt.
FOUNDATION_EXPORT NSString * _Nullable TotoroxCopyHardwareUDID(void);

NS_ASSUME_NONNULL_END
