#import "AppIconHelper.h"
#import "../exploit/mcm_bridge.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

static UIImage *iconFromData(NSData *data, CGFloat targetSize) {
    if (!data) return nil;
    UIImage *image = [UIImage imageWithData:data];
    if (!image) return nil;
    if (image.size.width <= targetSize && image.size.height <= targetSize) return image;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = image.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(targetSize, targetSize) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [image drawInRect:CGRectMake(0, 0, targetSize, targetSize)];
    }];
}

static NSData *iconDataFromProxy(id proxy) {
    SEL iconSel = NSSelectorFromString(@"iconDataForVariant:");
    if (![proxy respondsToSelector:iconSel]) return nil;

    // Variant availability differs between iOS releases and app types.
    // 2: 60x60 iPhone, 0: 29x29, 1: 40x40, 3: 76x76 iPad, 4: 83.5x83.5 iPad Pro
    const int variants[] = {2, 0, 1, 3, 4, 5, 6, 7, 15};
    for (NSUInteger index = 0; index < sizeof(variants) / sizeof(variants[0]); index++) {
        id data = ((id (*)(id, SEL, int))objc_msgSend)(proxy, iconSel, variants[index]);
        if ([data isKindOfClass:[NSData class]] && [data length] > 0) return data;
    }
    return nil;
}

static NSString *stringForFirstKey(NSDictionary *info, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        id value = info[key];
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
    }
    return nil;
}

static NSString *pathForFirstKey(NSDictionary *info, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        id value = info[key];
        if ([value isKindOfClass:[NSURL class]]) {
            NSString *path = [value path];
            if (path.length > 0) return path;
        }
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
    }
    return nil;
}

static void addApplicationInfo(NSMutableDictionary *result, NSString *fallbackBundleID, NSDictionary *info) {
    NSString *bundleID = stringForFirstKey(info, @[
        @"CFBundleIdentifier", @"BundleIdentifier", @"ApplicationIdentifier", @"MCMMetadataIdentifier"
    ]);
    if (bundleID.length == 0) bundleID = fallbackBundleID;
    if (bundleID.length == 0) return;

    NSString *name = stringForFirstKey(info, @[
        @"CFBundleDisplayName", @"CFBundleName", @"LocalizedName", @"Name"
    ]);
    NSString *container = pathForFirstKey(info, @[
        @"Container", @"DataContainer", @"DataContainerURL", @"ContainerPath", @"SandboxPath"
    ]);
    NSString *version = stringForFirstKey(info, @[
        @"CFBundleShortVersionString", @"BundleShortVersionString"
    ]);

    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"name"] = name.length > 0 ? name : bundleID;
    if (container.length > 0) entry[@"container"] = container;
    if (version.length > 0) entry[@"version"] = version;
    result[bundleID] = entry;
}

static void *mobileInstallationHandle(void) {
    static void *handle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_LAZY | RTLD_LOCAL);
    });
    return handle;
}

static NSDictionary *appsFromMobileInstallation(void) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    void *frameworkHandle = mobileInstallationHandle();

    // Legacy path for older releases where the original symbol is still exported.
    void *lookupFn = dlsym(RTLD_DEFAULT, "MobileInstallationLookup");
    if (!lookupFn && frameworkHandle) {
        lookupFn = dlsym(frameworkHandle, "MobileInstallationLookup");
    }
    if (!lookupFn) return result;

    NSDictionary *apps = nil;
    NSArray *optionSets = @[
        @{@"ApplicationType": @"Any"},
        @{@"ApplicationType": @"User"},
        @{@"ApplicationType": @"System"},
        @{},
    ];
    for (NSDictionary *options in optionSets) {
        apps = ((NSDictionary *(*)(NSDictionary *, void *))lookupFn)(options, NULL);
        if (apps && [apps isKindOfClass:[NSDictionary class]] && apps.count > 0) break;
    }
    if (!apps || apps.count == 0) return result;

    for (NSString *bundleID in apps) {
        @autoreleasepool {
            id rawInfo = apps[bundleID];
            if (![rawInfo isKindOfClass:[NSDictionary class]]) continue;
            addApplicationInfo(result, bundleID, rawInfo);
        }
    }
    return result;
}

static void ensureLaunchServicesLoaded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *candidates[] = {
            "/System/Library/Frameworks/CoreServices.framework/CoreServices",
            "/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices",
            "/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
        };
        for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
            if (dlopen(candidates[i], RTLD_LAZY | RTLD_GLOBAL)) {
                NSLog(@"[Totorox] ls: loaded %s", candidates[i]);
                return;
            }
        }
        NSLog(@"[Totorox] ls: CoreServices/MobileCoreServices dlopen failed");
    });
}

static NSDictionary *appsFromWorkspace(void) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    ensureLaunchServicesLoaded();

    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!workspaceClass) {
        NSLog(@"[Totorox] ls: LSApplicationWorkspace class unavailable");
        return result;
    }
    SEL defaultWorkspaceSel = NSSelectorFromString(@"defaultWorkspace");
    if (![workspaceClass respondsToSelector:defaultWorkspaceSel]) {
        NSLog(@"[Totorox] ls: defaultWorkspace selector missing");
        return result;
    }
    id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultWorkspaceSel);
    if (!workspace) {
        NSLog(@"[Totorox] ls: defaultWorkspace returned nil");
        return result;
    }

    NSArray *apps = nil;
    NSString *usedSelector = nil;
    for (NSString *selectorName in @[@"allApplications", @"allInstalledApplications"]) {
        SEL allAppsSel = NSSelectorFromString(selectorName);
        if (![workspace respondsToSelector:allAppsSel]) continue;
        id candidate = ((id (*)(id, SEL))objc_msgSend)(workspace, allAppsSel);
        if ([candidate isKindOfClass:[NSArray class]] && [candidate count] > 0) {
            apps = candidate;
            usedSelector = selectorName;
            break;
        }
        NSLog(@"[Totorox] ls: %@ returned %lu", selectorName,
              (unsigned long)([candidate isKindOfClass:[NSArray class]] ? [candidate count] : 0));
    }
    if (!apps || apps.count == 0) {
        NSLog(@"[Totorox] ls: workspace enumeration empty");
        return result;
    }
    NSLog(@"[Totorox] ls: %@ returned %lu proxies", usedSelector, (unsigned long)apps.count);

    NSUInteger withContainer = 0;
    for (id app in apps) {
        @autoreleasepool {
            NSString *bundleID = nil;
            for (NSString *selectorName in @[@"bundleIdentifier", @"applicationIdentifier"]) {
                SEL bundleSel = NSSelectorFromString(selectorName);
                if (![app respondsToSelector:bundleSel]) continue;
                id value = ((id (*)(id, SEL))objc_msgSend)(app, bundleSel);
                if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                    bundleID = value;
                    break;
                }
            }
            if (bundleID.length == 0) continue;

            NSString *name = nil;
            for (NSString *selectorName in @[@"localizedName", @"localizedShortName"]) {
                SEL nameSel = NSSelectorFromString(selectorName);
                if (![app respondsToSelector:nameSel]) continue;
                id value = ((id (*)(id, SEL))objc_msgSend)(app, nameSel);
                if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                    name = value;
                    break;
                }
            }
            if (name.length == 0) name = bundleID;

            NSMutableDictionary *entry = [NSMutableDictionary dictionary];
            entry[@"name"] = name;
            for (NSString *selectorName in @[@"bundleURL"]) {
                SEL bSel = NSSelectorFromString(selectorName);
                if (![app respondsToSelector:bSel]) continue;
                id bVal = ((id (*)(id, SEL))objc_msgSend)(app, bSel);
                NSString *bPath = [bVal isKindOfClass:[NSURL class]] ? [bVal path] : bVal;
                if ([bPath isKindOfClass:[NSString class]] && bPath.length > 0) {
                    entry[@"bundlePath"] = bPath;
                    break;
                }
            }
            for (NSString *selectorName in @[@"dataContainerURL", @"containerURL"]) {
                SEL containerSel = NSSelectorFromString(selectorName);
                if (![app respondsToSelector:containerSel]) continue;
                id containerValue = ((id (*)(id, SEL))objc_msgSend)(app, containerSel);
                NSString *containerPath = [containerValue isKindOfClass:[NSURL class]] ? [containerValue path] : containerValue;
                if ([containerPath isKindOfClass:[NSString class]] && containerPath.length > 0) {
                    entry[@"container"] = containerPath;
                    withContainer++;
                    break;
                }
            }
            result[bundleID] = entry;
        }
    }
    NSLog(@"[Totorox] ls: extracted %lu apps (%lu with container)",
          (unsigned long)result.count, (unsigned long)withContainer);
    return result;
}

NSDictionary<NSString *, NSDictionary *> *installedAppInfo(void) {
    NSDictionary *workspace = appsFromWorkspace();
    if (workspace.count > 0) return workspace;
    NSDictionary *mobileInstallation = appsFromMobileInstallation();
    NSLog(@"[Totorox] ls: workspace empty; MobileInstallation=%lu",
          (unsigned long)mobileInstallation.count);
    return mobileInstallation;
}

// Direct extraction of icon from application bundle (.app)
UIImage *iconForBundlePath(NSString *bundlePath) {
    if (!bundlePath || bundlePath.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    
    // 1. Try Info.plist
    NSString *infoPlistPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
    if (infoPlist) {
        NSDictionary *iconsDict = infoPlist[@"CFBundleIcons"];
        if ([iconsDict isKindOfClass:[NSDictionary class]]) {
            NSDictionary *primaryIcon = iconsDict[@"CFBundlePrimaryIcon"];
            if ([primaryIcon isKindOfClass:[NSDictionary class]]) {
                NSArray *files = primaryIcon[@"CFBundleIconFiles"];
                if ([files isKindOfClass:[NSArray class]] && files.count > 0) {
                    for (NSInteger i = (NSInteger)files.count - 1; i >= 0; i--) {
                        NSString *filename = files[i];
                        if (![filename isKindOfClass:[NSString class]]) continue;
                        NSArray *extensions = @[@"", @".png", @"@2x.png", @"@3x.png", @"~ipad.png", @"@2x~ipad.png"];
                        for (NSString *ext in extensions) {
                            NSString *candidate = [bundlePath stringByAppendingPathComponent:[filename stringByAppendingString:ext]];
                            if ([fm fileExistsAtPath:candidate]) {
                                UIImage *img = [UIImage imageWithContentsOfFile:candidate];
                                if (img && img.size.width > 0) return img;
                            }
                        }
                    }
                }
            }
        }
        NSString *iconFile = infoPlist[@"CFBundleIconFile"];
        if ([iconFile isKindOfClass:[NSString class]] && iconFile.length > 0) {
            NSArray *extensions = @[@"", @".png", @"@2x.png", @"@3x.png"];
            for (NSString *ext in extensions) {
                NSString *candidate = [bundlePath stringByAppendingPathComponent:[iconFile stringByAppendingString:ext]];
                if ([fm fileExistsAtPath:candidate]) {
                    UIImage *img = [UIImage imageWithContentsOfFile:candidate];
                    if (img && img.size.width > 0) return img;
                }
            }
        }
    }
    
    // 2. Scan bundle directory for AppIcon*.png or *.png
    NSArray *contents = [fm contentsOfDirectoryAtPath:bundlePath error:nil];
    if (contents) {
        for (NSString *filename in contents) {
            if ([filename hasPrefix:@"AppIcon"] && [filename hasSuffix:@".png"]) {
                NSString *full = [bundlePath stringByAppendingPathComponent:filename];
                UIImage *img = [UIImage imageWithContentsOfFile:full];
                if (img && img.size.width > 0) return img;
            }
        }
    }
    
    // 3. Try CoreUI on Assets.car
    NSString *carPath = [bundlePath stringByAppendingPathComponent:@"Assets.car"];
    if ([fm fileExistsAtPath:carPath]) {
        void *coreUI = dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_LAZY | RTLD_LOCAL);
        if (coreUI) {
            Class catalogClass = NSClassFromString(@"CUICatalog");
            if (catalogClass) {
                SEL initURL = NSSelectorFromString(@"initWithURL:error:");
                if ([catalogClass instancesRespondToSelector:initURL]) {
                    id catalog = ((id (*)(id, SEL, id, id*))objc_msgSend)([catalogClass alloc], initURL, [NSURL fileURLWithPath:carPath], NULL);
                    if (catalog) {
                        SEL imageWithName = NSSelectorFromString(@"imageWithName:scaleFactor:");
                        if ([catalog respondsToSelector:imageWithName]) {
                            NSArray *iconNames = @[@"AppIcon60x60", @"AppIcon76x76", @"AppIcon", @"AppIcon-1"];
                            for (NSString *name in iconNames) {
                                id cuiImage = ((id (*)(id, SEL, id, CGFloat))objc_msgSend)(catalog, imageWithName, name, 2.0);
                                if (cuiImage) {
                                    SEL cgImageSel = NSSelectorFromString(@"_CGImage");
                                    if ([cuiImage respondsToSelector:cgImageSel]) {
                                        CGImageRef cgImg = ((CGImageRef (*)(id, SEL))objc_msgSend)(cuiImage, cgImageSel);
                                        if (cgImg) {
                                            return [UIImage imageWithCGImage:cgImg];
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    return nil;
}

// Icon via LSApplicationProxy / CoreUI / Bundle PNG (per bundle ID)
UIImage *iconForBundleID(NSString *bundleID) {
    if (!bundleID || bundleID.length == 0) return nil;
    ensureLaunchServicesLoaded();
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 256;
    });
    UIImage *cached = [cache objectForKey:bundleID];
    if (cached) return cached;

    // 1. Try LSApplicationProxy iconDataForVariant: and bundleURL (thread-safe on background queues)
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if (proxyClass) {
        SEL appProxySel = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if ([proxyClass respondsToSelector:appProxySel]) {
            id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, appProxySel, bundleID);
            if (proxy) {
                NSData *data = iconDataFromProxy(proxy);
                if (data) {
                    UIImage *icon = iconFromData(data, 60.0);
                    if (icon) {
                        [cache setObject:icon forKey:bundleID];
                        return icon;
                    }
                }

                SEL bundleURLSel = NSSelectorFromString(@"bundleURL");
                if ([proxy respondsToSelector:bundleURLSel]) {
                    id bVal = ((id (*)(id, SEL))objc_msgSend)(proxy, bundleURLSel);
                    NSString *bPath = [bVal isKindOfClass:[NSURL class]] ? [bVal path] : bVal;
                    if ([bPath isKindOfClass:[NSString class]] && bPath.length > 0) {
                        UIImage *bundleIcon = iconForBundlePath(bPath);
                        if (bundleIcon) {
                            [cache setObject:bundleIcon forKey:bundleID];
                            return bundleIcon;
                        }
                    }
                }
            }
        }
    }

    // 2. Fallback to private UIKit API with fixed scale (avoids main-thread-only UIScreen.mainScreen)
    SEL privateIconSel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if ([UIImage respondsToSelector:privateIconSel]) {
        const CGFloat scale = 2.0;
        const int formats[] = {2, 0, 1, 3};
        for (int i = 0; i < 4; i++) {
            UIImage *img = ((UIImage *(*)(id, SEL, id, int, CGFloat))objc_msgSend)([UIImage class], privateIconSel, bundleID, formats[i], scale);
            if (img && img.size.width > 0 && img.size.height > 0) {
                [cache setObject:img forKey:bundleID];
                return img;
            }
        }
    }
    return nil;
}

// Name + icon for a single bundle ID via LSApplicationProxy
NSDictionary *appInfoForBundleID(NSString *bundleID) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"name"] = bundleID;
    if (!bundleID || bundleID.length == 0) return result;
    ensureLaunchServicesLoaded();

    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if (!proxyClass) return result;
    SEL appProxySel = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (![proxyClass respondsToSelector:appProxySel]) return result;
    id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, appProxySel, bundleID);
    if (!proxy) return result;

    BOOL matchesRequestedIdentifier = NO;
    for (NSString *selectorName in @[@"applicationIdentifier", @"bundleIdentifier"]) {
        SEL identifierSel = NSSelectorFromString(selectorName);
        if (![proxy respondsToSelector:identifierSel]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(proxy, identifierSel);
        if ([value isKindOfClass:[NSString class]]) {
            NSString *valStr = (NSString *)value;
            if ([valStr isEqualToString:bundleID] || [valStr hasSuffix:[@"." stringByAppendingString:bundleID]]) {
                matchesRequestedIdentifier = YES;
                break;
            }
        }
    }
    if (!matchesRequestedIdentifier) return result;
    result[@"found"] = @YES;

    NSURL *bundleURL = nil;
    SEL bundleURLSel = NSSelectorFromString(@"bundleURL");
    if ([proxy respondsToSelector:bundleURLSel]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(proxy, bundleURLSel);
        if ([value isKindOfClass:[NSURL class]]) bundleURL = value;
    }

    NSBundle *applicationBundle = bundleURL ? [NSBundle bundleWithURL:bundleURL] : nil;
    NSDictionary *localizedInfo = applicationBundle.localizedInfoDictionary;
    NSDictionary *bundleInfo = applicationBundle.infoDictionary;
    NSString *bundleName = stringForFirstKey(localizedInfo, @[
        @"CFBundleDisplayName", @"CFBundleName"
    ]);
    if (bundleName.length == 0) {
        bundleName = stringForFirstKey(bundleInfo, @[
            @"CFBundleDisplayName", @"CFBundleName"
        ]);
    }
    if (bundleName.length > 0) result[@"name"] = bundleName;

    if ([result[@"name"] isEqualToString:bundleID]) {
        for (NSString *selectorName in @[@"localizedName", @"localizedShortName"]) {
            SEL nameSel = NSSelectorFromString(selectorName);
            if (![proxy respondsToSelector:nameSel]) continue;
            NSString *name = ((id (*)(id, SEL))objc_msgSend)(proxy, nameSel);
            if ([name isKindOfClass:[NSString class]] && name.length > 0) {
                result[@"name"] = name;
                break;
            }
        }
    }

    NSString *bundleVersion = stringForFirstKey(bundleInfo, @[
        @"CFBundleShortVersionString"
    ]);
    if (bundleVersion.length > 0) result[@"version"] = bundleVersion;
    if (!result[@"version"]) {
        SEL versionSel = NSSelectorFromString(@"shortVersionString");
        if ([proxy respondsToSelector:versionSel]) {
            NSString *version = ((id (*)(id, SEL))objc_msgSend)(proxy, versionSel);
            if ([version isKindOfClass:[NSString class]] && version.length > 0) {
                result[@"version"] = version;
            }
        }
    }

    if (bundleURL && [bundleURL path].length > 0) {
        result[@"bundlePath"] = [bundleURL path];
    }

    for (NSString *selectorName in @[@"dataContainerURL", @"containerURL"]) {
        SEL containerSel = NSSelectorFromString(selectorName);
        if (![proxy respondsToSelector:containerSel]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(proxy, containerSel);
        NSString *path = [value isKindOfClass:[NSURL class]] ? [value path] : value;
        if ([path isKindOfClass:[NSString class]] && path.length > 0) {
            result[@"container"] = path;
            break;
        }
    }

    UIImage *icon = iconForBundleID(bundleID);
    if (icon) result[@"icon"] = icon;

    return result;
}

BOOL openApplicationForBundleID(NSString *bundleID) {
    if (bundleID.length == 0) return NO;
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultWorkspaceSelector = NSSelectorFromString(@"defaultWorkspace");
    if (!workspaceClass || ![workspaceClass respondsToSelector:defaultWorkspaceSelector]) {
        return NO;
    }
    id workspace = ((id (*)(id, SEL))objc_msgSend)(
        workspaceClass,
        defaultWorkspaceSelector
    );
    if (!workspace) return NO;
    SEL openSelector = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (![workspace respondsToSelector:openSelector]) return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, openSelector, bundleID);
}

// Builds a comprehensive dictionary mapping UUID (in lowercase, uppercase, and exact) to Bundle ID.
NSDictionary<NSString *, NSString *> *containerUUIDToBundleIDMap(void) {
    static NSMutableDictionary<NSString *, NSString *> *cachedMap;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cachedMap = [NSMutableDictionary dictionary];
    });

    // 1. From LaunchServices allApplications
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultWorkspaceSel = NSSelectorFromString(@"defaultWorkspace");
    if (workspaceClass && [workspaceClass respondsToSelector:defaultWorkspaceSel]) {
        id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultWorkspaceSel);
        if (workspace) {
            for (NSString *selName in @[@"allApplications", @"allInstalledApplications"]) {
                SEL allAppsSel = NSSelectorFromString(selName);
                if (![workspace respondsToSelector:allAppsSel]) continue;
                id apps = ((id (*)(id, SEL))objc_msgSend)(workspace, allAppsSel);
                if ([apps isKindOfClass:[NSArray class]]) {
                    for (id proxy in apps) {
                        @autoreleasepool {
                            NSString *bid = nil;
                            for (NSString *bSel in @[@"bundleIdentifier", @"applicationIdentifier"]) {
                                SEL s = NSSelectorFromString(bSel);
                                if ([proxy respondsToSelector:s]) {
                                    id v = ((id (*)(id, SEL))objc_msgSend)(proxy, s);
                                    if ([v isKindOfClass:[NSString class]] && [v length] > 0) {
                                        bid = v;
                                        break;
                                    }
                                }
                            }
                            if (bid.length == 0) continue;
                            
                            for (NSString *cSel in @[@"dataContainerURL", @"containerURL"]) {
                                SEL s = NSSelectorFromString(cSel);
                                if (![proxy respondsToSelector:s]) continue;
                                id v = ((id (*)(id, SEL))objc_msgSend)(proxy, s);
                                NSString *p = [v isKindOfClass:[NSURL class]] ? [v path] : v;
                                if ([p isKindOfClass:[NSString class]] && p.length > 0) {
                                    NSString *uuid = [p lastPathComponent];
                                    if (uuid.length >= 8) {
                                        cachedMap[uuid.uppercaseString] = bid;
                                        cachedMap[uuid.lowercaseString] = bid;
                                        cachedMap[uuid] = bid;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    // 2. From MCM Class 2 Enumeration & Direct Query
    if (MCMBridgeAvailable()) {
        NSString *err = nil;
        NSArray<NSString *> *identifiers = MCMEnumerateIdentifiersForClass(2, 500, &err);
        for (NSString *ident in identifiers) {
            if (ident.length == 0) continue;
            NSString *path = MCMContainerPathForIdentifier(2, ident, NO, nil);
            if (path.length > 0) {
                NSString *uuid = [path lastPathComponent];
                if (uuid.length >= 8) {
                    cachedMap[uuid.uppercaseString] = ident;
                    cachedMap[uuid.lowercaseString] = ident;
                    cachedMap[uuid] = ident;
                }
            }
        }
    }
    
    return [cachedMap copy];
}
