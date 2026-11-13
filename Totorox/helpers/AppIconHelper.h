#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns a dictionary mapping bundleID -> @{ @"name": NSString, @"icon": UIImage, @"container": NSString, @"bundlePath": NSString }.
/// Uses the private LSApplicationWorkspace API (stable across iOS 14+).
NSDictionary<NSString *, NSDictionary *> *installedAppInfo(void);

/// Fetches an icon for a single bundle ID via LSApplicationProxy, CoreUI, or Bundle PNG.
UIImage * _Nullable iconForBundleID(NSString *bundleID);

/// Extracts an application icon directly from a .app bundle path.
UIImage * _Nullable iconForBundlePath(NSString *bundlePath);

/// Returns @{ @"name": NSString, @"icon": UIImage, @"bundlePath": NSString, @"container": NSString } for a single bundle ID.
NSDictionary *appInfoForBundleID(NSString *bundleID);

/// Opens an installed app using LaunchServices. Returns NO when the private
/// selector is unavailable or the requested bundle cannot be opened.
BOOL openApplicationForBundleID(NSString *bundleID);

/// Builds a comprehensive dictionary mapping UUID (in lowercase, uppercase, and exact) to Bundle ID.
NSDictionary<NSString *, NSString *> *containerUUIDToBundleIDMap(void);

NS_ASSUME_NONNULL_END
