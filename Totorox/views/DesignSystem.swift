import SwiftUI
import UIKit
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

// MARK: - App Theme Mode & Window Style Synchronization

enum AppThemeMode: String, CaseIterable, Identifiable, Sendable {
    case light = "light"
    case dark = "dark"

    static let storageKey = "totorox.appearance.themeMode"

    var id: String { rawValue }

    var colorScheme: ColorScheme {
        switch self {
        case .light: return .light
        case .dark: return .dark
        }
    }

    var uiInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .light: return .light
        case .dark: return .dark
        }
    }

    var iconName: String {
        switch self {
        case .light: return "sun.max.fill"
        case .dark: return "moon.stars.fill"
        }
    }

    func displayTitle(for language: AppLanguage) -> String {
        switch self {
        case .light: return language.text("settings.theme_light")
        case .dark: return language.text("settings.theme_dark")
        }
    }
}

/// Quản lý giao diện Sáng / Tối đồng bộ trên toàn bộ `UIWindow` và SwiftUI view tree.
/// Chặn hoàn toàn lỗi iOS bật sẵn Dark Mode làm `TextField` / `Alert` / `Sheet` bị lệch màu chữ.
@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var mode: AppThemeMode {
        didSet {
            guard oldValue != mode else { return }
            defaults.set(mode.rawValue, forKey: AppThemeMode.storageKey)
            if applyToUIKitWindows {
                applyToAllWindows()
            }
        }
    }

    private let defaults: UserDefaults
    private let applyToUIKitWindows: Bool
    private var windowObservers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard, applyToUIKitWindows: Bool = true) {
        self.defaults = defaults
        self.applyToUIKitWindows = applyToUIKitWindows
        let raw = defaults.string(forKey: AppThemeMode.storageKey) ?? AppThemeMode.light.rawValue
        self.mode = AppThemeMode(rawValue: raw) ?? .light

        if applyToUIKitWindows {
            applyToAllWindows()
            registerWindowObservers()
        }
    }

    deinit {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func toggle() {
        withAnimation(.easeInOut(duration: 0.22)) {
            mode = (mode == .light) ? .dark : .light
        }
    }

    func applyToAllWindows() {
        let targetStyle = mode.uiInterfaceStyle
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.overrideUserInterfaceStyle != targetStyle {
                window.overrideUserInterfaceStyle = targetStyle
            }
        }
    }

    private func registerWindowObservers() {
        let names: [Notification.Name] = [
            UIScene.willConnectNotification,
            UIWindow.didBecomeVisibleNotification,
            UIWindow.didBecomeKeyNotification
        ]
        for name in names {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.applyToAllWindows()
                }
            }
            windowObservers.append(token)
        }
    }
}

// MARK: - Totorox Adaptive Design System (Light & Dark)

enum TotoroxTheme {
    private static func dynamicColor(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    /// Mint Green primary accent (#5BB9A8 light / #4EC9B5 dark)
    static let mintAccent = dynamicColor(
        light: UIColor(red: 0.357, green: 0.725, blue: 0.659, alpha: 1.0),
        dark: UIColor(red: 0.306, green: 0.788, blue: 0.710, alpha: 1.0)
    )

    /// Input / Search / Secondary container surface (#F4F3FD light / #212836 dark)
    static let searchBackground = dynamicColor(
        light: UIColor(red: 0.957, green: 0.953, blue: 0.992, alpha: 1.0),
        dark: UIColor(red: 0.129, green: 0.157, blue: 0.212, alpha: 1.0)
    )

    /// Root page canvas (#F9FAFC light / #0D1117 dark)
    static let pageBackground = dynamicColor(
        light: UIColor(red: 0.976, green: 0.980, blue: 0.988, alpha: 1.0),
        dark: UIColor(red: 0.051, green: 0.067, blue: 0.090, alpha: 1.0)
    )

    /// Elevated card surface (#FFFFFF light / #161B24 dark)
    static let cardBackground = dynamicColor(
        light: UIColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1.0),
        dark: UIColor(red: 0.086, green: 0.106, blue: 0.141, alpha: 1.0)
    )

    /// Peach badge background (#FFEFEA light / #3D211B dark)
    static let badgeBackground = dynamicColor(
        light: UIColor(red: 1.000, green: 0.937, blue: 0.918, alpha: 1.0),
        dark: UIColor(red: 0.239, green: 0.129, blue: 0.106, alpha: 1.0)
    )

    /// Salmon badge text (#FF7A59 light / #FF8F73 dark)
    static let badgeText = dynamicColor(
        light: UIColor(red: 1.000, green: 0.478, blue: 0.349, alpha: 1.0),
        dark: UIColor(red: 1.000, green: 0.561, blue: 0.451, alpha: 1.0)
    )

    /// High-contrast primary text (WCAG AAA)
    static let textPrimary = dynamicColor(
        light: UIColor(red: 0.118, green: 0.141, blue: 0.188, alpha: 1.0),
        dark: UIColor(red: 0.945, green: 0.961, blue: 0.976, alpha: 1.0)
    )

    /// Readable secondary text (WCAG AA+)
    static let textSecondary = dynamicColor(
        light: UIColor(red: 0.431, green: 0.467, blue: 0.529, alpha: 1.0),
        dark: UIColor(red: 0.580, green: 0.639, blue: 0.722, alpha: 1.0)
    )

    /// Hairline divider
    static let dividerColor = dynamicColor(
        light: UIColor(red: 0.918, green: 0.925, blue: 0.949, alpha: 1.0),
        dark: UIColor(red: 0.145, green: 0.180, blue: 0.243, alpha: 1.0)
    )

    /// Subtle card border (crisp edge definition in Dark Mode)
    static let cardBorderColor = dynamicColor(
        light: UIColor(white: 0.0, alpha: 0.04),
        dark: UIColor(red: 0.196, green: 0.247, blue: 0.337, alpha: 0.72)
    )

    /// Disabled CTA button fill & foreground
    static let disabledBackground = dynamicColor(
        light: UIColor(red: 0.906, green: 0.918, blue: 0.949, alpha: 1.0),
        dark: UIColor(red: 0.157, green: 0.192, blue: 0.255, alpha: 1.0)
    )

    static let disabledText = dynamicColor(
        light: UIColor(red: 0.520, green: 0.557, blue: 0.624, alpha: 1.0),
        dark: UIColor(red: 0.451, green: 0.510, blue: 0.600, alpha: 1.0)
    )

    /// Card elevation shadow
    static let shadowColor = dynamicColor(
        light: UIColor(white: 0.0, alpha: 0.04),
        dark: UIColor(white: 0.0, alpha: 0.26)
    )

    /// Translucent card surface used when a custom wallpaper is active so the
    /// wallpaper shines through gently while preserving full WCAG text contrast.
    static let translucentCardBackground = dynamicColor(
        light: UIColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 0.84),
        dark: UIColor(red: 0.086, green: 0.106, blue: 0.141, alpha: 0.82)
    )

    static var tabCanvasBackground: Color {
        WallpaperManager.hasActiveWallpaper ? .clear : pageBackground
    }

    static var activeCardBackground: Color {
        WallpaperManager.hasActiveWallpaper ? translucentCardBackground : cardBackground
    }
}

// MARK: - Wallpaper Crop Geometry & Custom App Wallpaper Manager

enum WallpaperCropGeometry {
    static let minZoom: CGFloat = 1.0
    static let maxZoom: CGFloat = 5.0

    static func baseFillScale(imageSize: CGSize, viewportSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else {
            return 1.0
        }
        return max(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height)
    }

    static func clampedZoom(_ rawZoom: CGFloat) -> CGFloat {
        min(max(rawZoom, minZoom), maxZoom)
    }

    static func clampedOffset(
        _ rawOffset: CGSize,
        imageSize: CGSize,
        viewportSize: CGSize,
        zoomScale: CGFloat
    ) -> CGSize {
        let zoom = clampedZoom(zoomScale)
        let fill = baseFillScale(imageSize: imageSize, viewportSize: viewportSize)
        let dispW = imageSize.width * fill * zoom
        let dispH = imageSize.height * fill * zoom
        let maxOffsetX = max(0, (dispW - viewportSize.width) * 0.5)
        let maxOffsetY = max(0, (dispH - viewportSize.height) * 0.5)
        return CGSize(
            width: min(max(rawOffset.width, -maxOffsetX), maxOffsetX),
            height: min(max(rawOffset.height, -maxOffsetY), maxOffsetY)
        )
    }

    static func outputPixelSize(
        for viewportSize: CGSize,
        screenScale: CGFloat,
        maxDimension: CGFloat = 2160
    ) -> CGSize {
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            return CGSize(width: 1170, height: 2532)
        }
        let scale = max(screenScale, 1.0)
        var outW = viewportSize.width * scale
        var outH = viewportSize.height * scale
        let longest = max(outW, outH)
        if longest > maxDimension {
            let factor = maxDimension / longest
            outW *= factor
            outH *= factor
        }
        return CGSize(width: max(1, round(outW)), height: max(1, round(outH)))
    }

    static func drawRect(
        imageSize: CGSize,
        viewportSize: CGSize,
        outputSize: CGSize,
        zoomScale: CGFloat,
        offset: CGSize
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0,
              outputSize.width > 0, outputSize.height > 0 else {
            return CGRect(origin: .zero, size: outputSize)
        }
        let zoom = clampedZoom(zoomScale)
        let safeOffset = clampedOffset(
            offset,
            imageSize: imageSize,
            viewportSize: viewportSize,
            zoomScale: zoom
        )
        let fill = baseFillScale(imageSize: imageSize, viewportSize: viewportSize)
        let dispW = imageSize.width * fill * zoom
        let dispH = imageSize.height * fill * zoom
        let originX = (viewportSize.width - dispW) * 0.5 + safeOffset.width
        let originY = (viewportSize.height - dispH) * 0.5 + safeOffset.height
        let ratioX = outputSize.width / viewportSize.width
        let ratioY = outputSize.height / viewportSize.height
        return CGRect(
            x: originX * ratioX,
            y: originY * ratioY,
            width: dispW * ratioX,
            height: dispH * ratioY
        )
    }
}

struct WallpaperCropDraft: Identifiable {
    let id = UUID()
    let image: UIImage
    let rawSourceData: Data?
}

@MainActor
final class WallpaperManager: ObservableObject {
    static let shared = WallpaperManager()
    nonisolated(unsafe) private(set) static var hasActiveWallpaper: Bool = false

    @Published private(set) var image: UIImage? = nil {
        didSet {
            Self.hasActiveWallpaper = (image != nil)
        }
    }

    var hasWallpaper: Bool { image != nil }

    private let fileURL: URL
    private let originalFileURL: URL

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        var dir = base.appendingPathComponent("TotoroxWallpaper", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? dir.setResourceValues(rv)
        self.fileURL = dir.appendingPathComponent("custom_wallpaper.jpg", isDirectory: false)
        self.originalFileURL = dir.appendingPathComponent("original_wallpaper.jpg", isDirectory: false)

        if let data = try? Data(contentsOf: fileURL),
           let loaded = UIImage(data: data) {
            self.image = loaded
            Self.hasActiveWallpaper = true
        }
    }

    /// Decodes a picked photo off the main thread into a normalized `.up` `UIImage`
    /// (`<= 2560px`) suitable for interactive pan/zoom framing without spiking RAM.
    func prepareDraftImage(from rawData: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            Self.downsampleImage(data: rawData, maxPixelSize: 2560)
        }.value
    }

    /// Loads the stored full-frame source photo so the user can re-adjust position
    /// and crop later without picking from Photos again.
    func loadOriginalForRecrop() async -> UIImage? {
        let origURL = originalFileURL
        let fallback = image
        return await Task.detached(priority: .userInitiated) {
            if let data = try? Data(contentsOf: origURL),
               let decoded = Self.downsampleImage(data: data, maxPixelSize: 2560) {
                return decoded
            }
            return fallback
        }.value
    }

    /// Renders the exact user-chosen viewport crop at high resolution off the main
    /// thread and persists both the cropped wallpaper and the full source image.
    func saveCroppedWallpaper(
        sourceImage: UIImage,
        isNewSource: Bool,
        viewportSize: CGSize,
        zoomScale: CGFloat,
        offset: CGSize,
        screenScale: CGFloat
    ) async {
        let destURL = fileURL
        let origURL = originalFileURL
        let processed: UIImage? = await Task.detached(priority: .userInitiated) {
            let outSize = WallpaperCropGeometry.outputPixelSize(
                for: viewportSize,
                screenScale: screenScale,
                maxDimension: 2160
            )
            let drawRect = WallpaperCropGeometry.drawRect(
                imageSize: sourceImage.size,
                viewportSize: viewportSize,
                outputSize: outSize,
                zoomScale: zoomScale,
                offset: offset
            )
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1.0
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: outSize, format: format)
            let cropped = renderer.image { ctx in
                UIColor.black.setFill()
                ctx.fill(CGRect(origin: .zero, size: outSize))
                sourceImage.draw(in: drawRect)
            }
            guard let jpegData = cropped.jpegData(compressionQuality: 0.88) else {
                return nil
            }
            try? jpegData.write(to: destURL, options: .atomic)
            if isNewSource || !FileManager.default.fileExists(atPath: origURL.path) {
                if let origJPEG = sourceImage.jpegData(compressionQuality: 0.88) {
                    try? origJPEG.write(to: origURL, options: .atomic)
                }
            }
            return UIImage(data: jpegData) ?? cropped
        }.value

        guard let processed else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            self.image = processed
        }
    }

    func resetToDefault() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: originalFileURL)
        withAnimation(.easeInOut(duration: 0.22)) {
            self.image = nil
        }
    }

    /// Uses ImageIO thumbnailing (`kCGImageSourceCreateThumbnailWithTransform`) so even
    /// a 48MP photo is decoded directly at `<= maxPixelSize` with `.up` orientation.
    nonisolated private static func downsampleImage(data: Data, maxPixelSize: Int) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) {
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
                return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
            }
        }
        guard let fallback = UIImage(data: data) else { return nil }
        if fallback.imageOrientation == .up { return fallback }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        return UIGraphicsImageRenderer(size: fallback.size, format: format).image { _ in
            fallback.draw(in: CGRect(origin: .zero, size: fallback.size))
        }
    }
}

struct TotoroxWallpaperLayer: View {
    @ObservedObject private var wallpaper = WallpaperManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        GeometryReader { geo in
            ZStack {
                TotoroxTheme.pageBackground

                if let uiImage = wallpaper.image {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()

                    // Subtle adaptive contrast veil so header & text stay legible on any photo
                    (themeManager.mode == .dark
                        ? Color.black.opacity(0.32)
                        : Color.white.opacity(0.14))
                }
            }
        }
        .ignoresSafeArea(.all)
    }
}

// MARK: - Interactive Facebook-Style Wallpaper Position & Crop Editor

struct WallpaperCropEditorView: View {
    let draft: WallpaperCropDraft
    let onCancel: () -> Void
    let onConfirm: (_ viewportSize: CGSize, _ zoomScale: CGFloat, _ offset: CGSize) async -> Void

    @Environment(\.appLanguage) private var language
    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var steadyScale: CGFloat = 1.0
    @State private var gestureScale: CGFloat = 1.0
    @State private var steadyOffset: CGSize = .zero
    @State private var gestureOffset: CGSize = .zero
    @State private var isInteracting: Bool = false
    @State private var showAppFramePreview: Bool = true
    @State private var isSaving: Bool = false

    private var windowSafeAreaInsets: UIEdgeInsets {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            if let key = ws.windows.first(where: \.isKeyWindow) ?? ws.windows.first {
                return key.safeAreaInsets
            }
        }
        return UIEdgeInsets(top: 50, left: 0, bottom: 34, right: 0)
    }

    var body: some View {
        GeometryReader { geo in
            let viewportSize = geo.size
            let insets = windowSafeAreaInsets
            let liveZoom = WallpaperCropGeometry.clampedZoom(steadyScale * gestureScale)
            let scaledSteadyOffset = CGSize(
                width: steadyOffset.width * (liveZoom / max(steadyScale, 1.0)),
                height: steadyOffset.height * (liveZoom / max(steadyScale, 1.0))
            )
            let rawOffset = CGSize(
                width: scaledSteadyOffset.width + gestureOffset.width,
                height: scaledSteadyOffset.height + gestureOffset.height
            )
            let liveOffset = WallpaperCropGeometry.clampedOffset(
                rawOffset,
                imageSize: draft.image.size,
                viewportSize: viewportSize,
                zoomScale: liveZoom
            )
            let fillScale = WallpaperCropGeometry.baseFillScale(
                imageSize: draft.image.size,
                viewportSize: viewportSize
            )
            let dispW = draft.image.size.width * fillScale * liveZoom
            let dispH = draft.image.size.height * fillScale * liveZoom

            ZStack {
                Color.black

                // Interactive Pan + Pinch-to-Zoom Photo Layer
                Image(uiImage: draft.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: dispW, height: dispH)
                    .position(
                        x: viewportSize.width * 0.5 + liveOffset.width,
                        y: viewportSize.height * 0.5 + liveOffset.height
                    )
                    .clipped()

                // Same subtle contrast veil used in the live app when previewing App Frame
                if showAppFramePreview {
                    (themeManager.mode == .dark
                        ? Color.black.opacity(0.32)
                        : Color.white.opacity(0.14))
                        .allowsHitTesting(false)
                }

                // Rule-of-thirds crop grid (brightens smoothly during pan/zoom)
                cropGridOverlay(size: viewportSize)
                    .opacity(isInteracting ? 0.65 : 0.22)
                    .animation(.easeOut(duration: 0.18), value: isInteracting)
                    .allowsHitTesting(false)

                // Live translucent Totorox UI silhouette so user can frame faces cleanly
                if showAppFramePreview {
                    appSilhouetteOverlay(insets: insets)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }

                // Gesture capture surface
                Color.white.opacity(0.001)
                    .contentShape(Rectangle())
                    .gesture(panAndZoomGesture(viewportSize: viewportSize))
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            steadyScale = 1.0
                            gestureScale = 1.0
                            steadyOffset = .zero
                            gestureOffset = .zero
                        }
                    }

                // Top & Bottom Control Bars
                VStack(spacing: 0) {
                    topControlBar(
                        insets: insets,
                        canReset: liveZoom > 1.005 || abs(liveOffset.width) > 1 || abs(liveOffset.height) > 1
                    )

                    Spacer()

                    bottomActionBar(
                        insets: insets,
                        viewportSize: viewportSize,
                        liveZoom: liveZoom,
                        liveOffset: liveOffset
                    )
                }
            }
            .frame(width: viewportSize.width, height: viewportSize.height)
            .clipped()
        }
        .ignoresSafeArea(.all)
        .statusBarHidden(false)
    }

    private func panAndZoomGesture(viewportSize: CGSize) -> some Gesture {
        let drag = DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isInteracting { isInteracting = true }
                gestureOffset = value.translation
            }
            .onEnded { value in
                let finalZoom = WallpaperCropGeometry.clampedZoom(steadyScale * gestureScale)
                let scaledBase = CGSize(
                    width: steadyOffset.width * (finalZoom / max(steadyScale, 1.0)),
                    height: steadyOffset.height * (finalZoom / max(steadyScale, 1.0))
                )
                let combined = CGSize(
                    width: scaledBase.width + value.translation.width,
                    height: scaledBase.height + value.translation.height
                )
                steadyScale = finalZoom
                gestureScale = 1.0
                steadyOffset = WallpaperCropGeometry.clampedOffset(
                    combined,
                    imageSize: draft.image.size,
                    viewportSize: viewportSize,
                    zoomScale: finalZoom
                )
                gestureOffset = .zero
                isInteracting = false
            }

        let magnify = MagnificationGesture()
            .onChanged { value in
                if !isInteracting { isInteracting = true }
                gestureScale = value
            }
            .onEnded { value in
                let finalZoom = WallpaperCropGeometry.clampedZoom(steadyScale * value)
                let scaledBase = CGSize(
                    width: steadyOffset.width * (finalZoom / max(steadyScale, 1.0)),
                    height: steadyOffset.height * (finalZoom / max(steadyScale, 1.0))
                )
                let combined = CGSize(
                    width: scaledBase.width + gestureOffset.width,
                    height: scaledBase.height + gestureOffset.height
                )
                withAnimation(.easeOut(duration: 0.16)) {
                    steadyScale = finalZoom
                    gestureScale = 1.0
                    steadyOffset = WallpaperCropGeometry.clampedOffset(
                        combined,
                        imageSize: draft.image.size,
                        viewportSize: viewportSize,
                        zoomScale: finalZoom
                    )
                    gestureOffset = .zero
                }
                isInteracting = false
            }

        return SimultaneousGesture(drag, magnify)
    }

    private func cropGridOverlay(size: CGSize) -> some View {
        Path { path in
            let thirdW = size.width / 3.0
            let thirdH = size.height / 3.0
            for i in 1...2 {
                let x = thirdW * CGFloat(i)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                let y = thirdH * CGFloat(i)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        .stroke(Color.white.opacity(0.75), lineWidth: 0.7)
        .shadow(color: Color.black.opacity(0.45), radius: 1, x: 0, y: 0.5)
    }

    private func appSilhouetteOverlay(insets: UIEdgeInsets) -> some View {
        VStack(spacing: 12) {
            // Simulated Header area
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.28))
                    .frame(width: 40, height: 40)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.28))
                    .frame(width: 96, height: 20)
                Spacer()
                Circle()
                    .fill(Color.white.opacity(0.24))
                    .frame(width: 38, height: 38)
                Circle()
                    .fill(Color.white.opacity(0.24))
                    .frame(width: 38, height: 38)
            }
            .padding(.horizontal, 16)
            .padding(.top, max(insets.top, 44) + 54)

            // Simulated Cards outline so user sees where cards sit without hiding photo
            VStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 74)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(
                                    Color.white.opacity(0.38),
                                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                                )
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 28)

            Spacer()
        }
    }

    private func topControlBar(insets: UIEdgeInsets, canReset: Bool) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(language.text("wallpaper.crop_title"))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.black.opacity(0.52))
                    .clipShape(Capsule())

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAppFramePreview.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showAppFramePreview ? "eye.fill" : "eye.slash")
                            .font(.system(size: 12, weight: .semibold))
                        Text(language.text("wallpaper.preview_ui"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(
                        showAppFramePreview
                            ? TotoroxTheme.mintAccent.opacity(0.88)
                            : Color.black.opacity(0.52)
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                if canReset {
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            steadyScale = 1.0
                            gestureScale = 1.0
                            steadyOffset = .zero
                            gestureOffset = .zero
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 12, weight: .semibold))
                            Text(language.text("wallpaper.crop_reset"))
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(Color.black.opacity(0.52))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)

            Text(language.text("wallpaper.crop_hint"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.45))
                .clipShape(Capsule())
        }
        .padding(.top, max(insets.top, 44) + 6)
    }

    private func bottomActionBar(
        insets: UIEdgeInsets,
        viewportSize: CGSize,
        liveZoom: CGFloat,
        liveOffset: CGSize
    ) -> some View {
        HStack(spacing: 12) {
            Button {
                guard !isSaving else { return }
                onCancel()
            } label: {
                Text(language.text("wallpaper.cancel"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.black.opacity(0.60))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isSaving)

            Button {
                guard !isSaving else { return }
                isSaving = true
                Task {
                    await onConfirm(viewportSize, liveZoom, liveOffset)
                    await MainActor.run {
                        isSaving = false
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.85)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    Text(language.text(isSaving ? "wallpaper.saving" : "wallpaper.confirm"))
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(TotoroxTheme.mintAccent)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: TotoroxTheme.mintAccent.opacity(0.38), radius: 8, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, max(insets.bottom, 20) + 8)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.0), Color.black.opacity(0.68)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

// MARK: - Card Styling Modifier

struct TotoroxCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16
    var padding: CGFloat = 16
    @ObservedObject private var wallpaper = WallpaperManager.shared

    func body(content: Content) -> some View {
        let _ = wallpaper.hasWallpaper
        content
            .padding(padding)
            .background(TotoroxTheme.activeCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(TotoroxTheme.cardBorderColor, lineWidth: 0.8)
            )
            .shadow(color: TotoroxTheme.shadowColor, radius: 8, x: 0, y: 3)
    }
}

extension View {
    func totoroxCard(cornerRadius: CGFloat = 16, padding: CGFloat = 16) -> some View {
        modifier(TotoroxCardModifier(cornerRadius: cornerRadius, padding: padding))
    }
}

// MARK: - Reusable Header Component

struct TotoroxTopHeader: View {
    var onSettingsTapped: () -> Void
    @ObservedObject private var wallpaper = WallpaperManager.shared
    @Environment(\.appLanguage) private var language
    @Environment(\.displayScale) private var displayScale
    @State private var showPhotoPicker: Bool = false
    @State private var pickedPhotoItem: PhotosPickerItem? = nil
    @State private var cropDraft: WallpaperCropDraft? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Official App Logo with standard iOS squircle corner radius
            AppLogo(size: 42)
                .overlay(
                    RoundedRectangle(cornerRadius: 42 * 0.22, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)

            // App Title
            VStack(alignment: .leading, spacing: 2) {
                Text("Totorox")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(TotoroxTheme.textPrimary)
            }

            Spacer()

            HStack(spacing: 10) {
                // Wallpaper Edit / Reposition / Reset Button (right next to Settings gear)
                if wallpaper.hasWallpaper {
                    Menu {
                        Button {
                            Task {
                                if let orig = await wallpaper.loadOriginalForRecrop() {
                                    await MainActor.run {
                                        cropDraft = WallpaperCropDraft(image: orig, rawSourceData: nil)
                                    }
                                }
                            }
                        } label: {
                            Label(language.text("wallpaper.reposition"), systemImage: "crop")
                        }

                        Button {
                            showPhotoPicker = true
                        } label: {
                            Label(language.text("wallpaper.change"), systemImage: "photo.on.rectangle")
                        }

                        Button(role: .destructive) {
                            wallpaper.resetToDefault()
                        } label: {
                            Label(language.text("wallpaper.reset_default"), systemImage: "trash")
                        }
                    } label: {
                        wallpaperButtonCircle(isActive: true)
                    }
                    .accessibilityLabel(language.text("wallpaper.edit_a11y"))
                } else {
                    Button {
                        showPhotoPicker = true
                    } label: {
                        wallpaperButtonCircle(isActive: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(language.text("wallpaper.edit_a11y"))
                }

                // Settings Gear Button
                Button(action: onSettingsTapped) {
                    ZStack {
                        Circle()
                            .fill(TotoroxTheme.searchBackground.opacity(wallpaper.hasWallpaper ? 0.88 : 1.0))
                            .frame(width: 40, height: 40)
                        Image(systemName: "gearshape")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $pickedPhotoItem,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: pickedPhotoItem) { newItem in
            guard let newItem else { return }
            Task {
                var prepared: UIImage? = nil
                var rawBytes: Data? = nil
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    rawBytes = data
                    prepared = await wallpaper.prepareDraftImage(from: data)
                }
                await MainActor.run {
                    pickedPhotoItem = nil
                    if let prepared {
                        cropDraft = WallpaperCropDraft(image: prepared, rawSourceData: rawBytes)
                    }
                }
            }
        }
        .fullScreenCover(item: $cropDraft) { draft in
            WallpaperCropEditorView(
                draft: draft,
                onCancel: {
                    cropDraft = nil
                },
                onConfirm: { viewportSize, zoomScale, offset in
                    await wallpaper.saveCroppedWallpaper(
                        sourceImage: draft.image,
                        isNewSource: draft.rawSourceData != nil,
                        viewportSize: viewportSize,
                        zoomScale: zoomScale,
                        offset: offset,
                        screenScale: displayScale
                    )
                    await MainActor.run {
                        cropDraft = nil
                    }
                }
            )
        }
    }

    private func wallpaperButtonCircle(isActive: Bool) -> some View {
        ZStack {
            Circle()
                .fill(
                    isActive
                        ? TotoroxTheme.mintAccent.opacity(0.20)
                        : TotoroxTheme.searchBackground
                )
                .frame(width: 40, height: 40)
                .overlay(
                    Circle()
                        .stroke(isActive ? TotoroxTheme.mintAccent.opacity(0.55) : Color.clear, lineWidth: 1)
                )
            Image(systemName: isActive ? "photo.fill.on.rectangle.fill" : "photo.badge.plus")
                .font(.system(size: 16.5, weight: .medium))
                .foregroundStyle(isActive ? TotoroxTheme.mintAccent : TotoroxTheme.textPrimary)
        }
    }
}

// MARK: - Account Status Strip

struct AccountStatusBar: View {
    @ObservedObject private var license = LicenseManager.shared
    @Environment(\.appLanguage) private var language

    var onRedeemTapped: () -> Void
    var onLogoutTapped: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Username + Expiry + Quota
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(license.hasActivePlan ? TotoroxTheme.mintAccent : Color.orange)

                Text(license.username.isEmpty ? "—" : license.username)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(TotoroxTheme.textPrimary)
                    .lineLimit(1)

                Text("•")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.6))

                Text(license.formattedExpiry(language: language, short: true))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(license.hasActivePlan ? TotoroxTheme.textSecondary : Color.orange)
                    .lineLimit(1)

                Text(license.formattedRemainingUses(language: language))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(license.hasActivePlan ? TotoroxTheme.mintAccent : Color.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background((license.hasActivePlan ? TotoroxTheme.mintAccent : Color.orange).opacity(0.12))
                    .clipShape(Capsule())
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button(action: onRedeemTapped) {
                HStack(spacing: 3) {
                    Image(systemName: "ticket.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(language.text("account.status_redeem"))
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(TotoroxTheme.mintAccent)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: onLogoutTapped) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .padding(6)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("account.logout_button"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(TotoroxTheme.activeCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(TotoroxTheme.dividerColor, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
}

// MARK: - Hardware UDID Verification Card

struct DeviceVerificationCard: View {
    @ObservedObject private var license = LicenseManager.shared
    @Environment(\.appLanguage) private var language
    @Environment(\.openURL) private var openURL

    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: compact ? 18 : 20, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .frame(width: compact ? 34 : 38, height: compact ? 34 : 38)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("udid.verify.title"))
                        .font(.system(size: compact ? 13 : 14, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                    Text(language.text("udid.verify.subtitle"))
                        .font(.system(size: compact ? 11 : 12))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !compact {
                VStack(alignment: .leading, spacing: 5) {
                    stepRow(number: "1", text: language.text("udid.verify.step1"))
                    stepRow(number: "2", text: language.text("udid.verify.step2"))
                    stepRow(number: "3", text: language.text("udid.verify.step3"))
                }
                .padding(10)
                .background(TotoroxTheme.pageBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Button {
                guard let url = license.prepareDeviceProfileURL() else { return }
                openURL(url)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "safari.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text(language.text("udid.verify.button"))
                        .font(.system(size: compact ? 13 : 14, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: compact ? 38 : 44)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.15, green: 0.39, blue: 0.92), Color(red: 0.23, green: 0.51, blue: 0.96)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(license.deviceProfileURL() == nil)
        }
        .padding(compact ? 12 : 16)
        .background(TotoroxTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 6, x: 0, y: 2)
    }

    private func stepRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.orange)
                .frame(width: 18, height: 18)
                .background(Color.orange.opacity(0.14))
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(TotoroxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Reusable Search Bar Component

struct TotoroxSearchBar: View {
    @Binding var text: String
    var placeholder: String? = nil
    var onFilterTapped: (() -> Void)? = nil
    @Environment(\.appLanguage) private var language

    var body: some View {
        let promptText = placeholder ?? language.text("search.default_placeholder")
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(TotoroxTheme.textSecondary)

            TextField(
                "",
                text: $text,
                prompt: Text(promptText).foregroundColor(TotoroxTheme.textSecondary)
            )
            .font(.system(size: 15))
            .foregroundStyle(TotoroxTheme.textPrimary)
            .tint(TotoroxTheme.mintAccent)

            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                }
            }

            if let onFilter = onFilterTapped {
                Button(action: onFilter) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(TotoroxTheme.searchBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }
}

// MARK: - Reusable Pill Badge Component

struct TotoroxBadge: View {
    let title: String
    var isAccent: Bool = false

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isAccent ? .white : TotoroxTheme.badgeText)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isAccent ? TotoroxTheme.mintAccent : TotoroxTheme.badgeBackground)
            .clipShape(Capsule())
    }
}

// MARK: - Reusable Primary Button

struct TotoroxPrimaryButton: View {
    let title: String
    var icon: String? = nil
    var isLoading: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        let activeAppearance = isEnabled || isLoading
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.9)
                } else if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(activeAppearance ? TotoroxTheme.mintAccent : TotoroxTheme.disabledBackground)
            .foregroundColor(activeAppearance ? .white : TotoroxTheme.disabledText)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: activeAppearance ? TotoroxTheme.mintAccent.opacity(0.3) : Color.clear, radius: 8, x: 0, y: 4)
        }
        .disabled(!isEnabled || isLoading)
        .buttonStyle(.plain)
    }
}

// MARK: - Reusable Pill Selector

struct TotoroxPillSelector<T: Hashable>: View {
    let items: [T]
    @Binding var selected: T
    let titleProvider: (T) -> String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.self) { item in
                let isSelected = (item == selected)
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selected = item
                    }
                }) {
                    Text(titleProvider(item))
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? .white : TotoroxTheme.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(isSelected ? TotoroxTheme.mintAccent : TotoroxTheme.searchBackground)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Legacy Compatibility Shims (AppTheme, AppCardBorder, AppRowIcon, AppSearchField, AppLogo)

enum AppTheme {
    static var accent: Color { TotoroxTheme.mintAccent }
    static var pageBackground: Color { TotoroxTheme.pageBackground }
    static var consoleBackground: Color { TotoroxTheme.pageBackground }
    static let pageInset: CGFloat = 16
    static let rowIconSize: CGFloat = 17
    static let rowIconFrame: CGFloat = 28
    static let fileRowIconSize: CGFloat = 17
    static let fileRowIconFrame: CGFloat = 30
    static let fileRowHeight: CGFloat = 60
    static let appIconSize: CGFloat = 32
    static let emptyIconSize: CGFloat = 30
    static let selectionIconSize: CGFloat = 18
    static let contentCardCornerRadius: CGFloat = 20
    static let contentCardInset: CGFloat = 16
    static let contentCardPadding: CGFloat = 16
}

struct AppCardBorder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: AppTheme.contentCardCornerRadius, style: .continuous)
            .strokeBorder(Color(uiColor: .separator).opacity(0.22), lineWidth: 0.5)
            .accessibilityHidden(true)
    }
}

struct AppRowIcon: View {
    let systemName: String
    var tint: Color = AppTheme.accent
    var symbolSize: CGFloat = AppTheme.rowIconSize
    var frameSize: CGFloat = AppTheme.rowIconFrame

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.12))
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: frameSize, height: frameSize)
        .accessibilityHidden(true)
    }
}

struct AppSearchField: View {
    @Binding var text: String
    var placeholder: String = "Search"
    var clearLabel: String = "Clear search"

    init(text: Binding<String>, placeholder: String = "Search", clearLabel: String = "Clear search") {
        self._text = text
        self.placeholder = placeholder
        self.clearLabel = clearLabel
    }

    init(text: Binding<String>, prompt: String, clearLabel: String = "Clear search") {
        self._text = text
        self.placeholder = prompt
        self.clearLabel = clearLabel
    }

    var body: some View {
        TotoroxSearchBar(text: $text, placeholder: placeholder)
    }
}

struct AppLogo: View {
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let icon = UIImage(named: "AppAvatar") ?? UIImage(named: "AppIcon") {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "app.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Share Sheet Helper

struct ActivityViewControllerWrapper: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Document Picker Helper

struct DocumentPickerWrapper: UIViewControllerRepresentable {
    var allowedContentTypes: [UTType] = [.data, .item]
    var asCopy: Bool = true
    var onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // iOS requires `asCopy: false` when picking `.folder` (security-scoped directory access).
        let effectiveAsCopy = allowedContentTypes.contains(.folder) ? false : asCopy
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: allowedContentTypes,
            asCopy: effectiveAsCopy
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let first = urls.first {
                onPick(first)
            }
        }
    }
}

