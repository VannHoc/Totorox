import Foundation
import Darwin

/// Kết quả giải mã một file LaunchServices `*.csstore`, port từ
/// WQFiles 0.9.19 (`WQLaunchServices.m`).
///
/// Khác với bộ lọc byte cũ trong `LaunchServicesCandidateExtractor` (chỉ tìm
/// chuỗi bundle-id), snapshot này đọc đúng cấu trúc record/string của store:
///  - `bundleIDByContainerPath`: `<private container> -> bundle id` (map trực tiếp UUID → app)
///  - `displayNameByBundleID` / `bundleNameByBundleID`: tên app đã lọc ký tự điều khiển
///  - `bundlePathByBundleID`: đường dẫn `.app`
///  - `groupIDByContainerPath`: `<private AppGroup UUID> -> group id`
///
/// Không có tác dụng phụ lên UI; caller quyết định dùng map hay fallback.
struct LSStoreSnapshot {
    let identifiers: [String]
    let bundleIDByContainerPath: [String: String]
    let pathByBundleID: [String: String]
    let displayNameByBundleID: [String: String]
    let bundleNameByBundleID: [String: String]
    let bundlePathByBundleID: [String: String]
    let groupIDByContainerPath: [String: String]
    let layout: String
    let containerPathCount: Int
}

enum LaunchServicesStoreParser {

    // MARK: - Giới hạn (theo reference, tránh store lỗi làm treo/tốn RAM)
    private static let minStoreBytes = 0x1000
    private static let maxStoreBytes = 64 * 1024 * 1024
    private static let maxStringID: UInt32 = 0x0100_0000
    private static let maxBundleRecords = 100_000
    private static let maxDecodedStrings = 200_000
    private static let maxDecodedStringBytes = 8 * 1024 * 1024
    private static let maxRecordSize = 0x25c
    private static let maxVoteMatches = 32_768
    private static let maxVoteSteps = 1 << 23
    private static let maxVoteKeys = 1 << 16
    private static let autoLayoutDefaultsKey = "WQLaunchServicesWorkedOutLayout"

    private struct Layout {
        let label: String
        let bundleSize: UInt32
        let bundleID: UInt32
        let container: UInt32
        let name: UInt32
        let displayName: UInt32
        let bundlePath: UInt32
        let pluginSize: UInt32
        let pluginBundleID: UInt32
        let pluginContainer: UInt32
    }

    /// Bảng layout của reference (offset tính từ thân record, sau header 8 byte).
    private static let layouts: [Layout] = [
        Layout(label: "27.0",  bundleSize: 0x250, bundleID: 0x0c, container: 0x68, name: 0x6c, displayName: 0x74, bundlePath: 0x00, pluginSize: 0x118, pluginBundleID: 0x00, pluginContainer: 0x54),
        Layout(label: "26",    bundleSize: 0x23c, bundleID: 0x0c, container: 0x64, name: 0x68, displayName: 0x70, bundlePath: 0x00, pluginSize: 0x104, pluginBundleID: 0x00, pluginContainer: 0x50),
        Layout(label: "26.5",  bundleSize: 0x23c, bundleID: 0x0c, container: 0x60, name: 0x64, displayName: 0x6c, bundlePath: 0x00, pluginSize: 0x104, pluginBundleID: 0x00, pluginContainer: 0x4c),
        Layout(label: "26.5b", bundleSize: 0x23c, bundleID: 0x08, container: 0x60, name: 0x64, displayName: 0x6c, bundlePath: 0x00, pluginSize: 0x104, pluginBundleID: 0x00, pluginContainer: 0x4c),
        Layout(label: "27.2",  bundleSize: 0x25c, bundleID: 0x0c, container: 0x6c, name: 0x70, displayName: 0x78, bundlePath: 0x00, pluginSize: 0x120, pluginBundleID: 0x00, pluginContainer: 0x58),
        Layout(label: "27.2b", bundleSize: 0x25c, bundleID: 0x10, container: 0x6c, name: 0x70, displayName: 0x78, bundlePath: 0x00, pluginSize: 0x120, pluginBundleID: 0x04, pluginContainer: 0x58),
        Layout(label: "27.2c", bundleSize: 0x25c, bundleID: 0x0c, container: 0x6c, name: 0x70, displayName: 0x78, bundlePath: 0x00, pluginSize: 0x120, pluginBundleID: 0x04, pluginContainer: 0x58),
        Layout(label: "27.2d", bundleSize: 0x25c, bundleID: 0x10, container: 0x6c, name: 0x70, displayName: 0x78, bundlePath: 0x00, pluginSize: 0x120, pluginBundleID: 0x00, pluginContainer: 0x58),
        Layout(label: "27.3",  bundleSize: 0x25c, bundleID: 0x0c, container: 0x6c, name: 0x70, displayName: 0x78, bundlePath: 0x00, pluginSize: 0x134, pluginBundleID: 0x00, pluginContainer: 0x58),
        Layout(label: "27.3b", bundleSize: 0x25c, bundleID: 0x0c, container: 0x6c, name: 0x70, displayName: 0x78, bundlePath: 0x00, pluginSize: 0x134, pluginBundleID: 0x04, pluginContainer: 0x58),
        Layout(label: "27.3c", bundleSize: 0x25c, bundleID: 0x0c, container: 0x6c, name: 0x70, displayName: 0x78, bundlePath: 0x00, pluginSize: 0x0f0, pluginBundleID: 0x00, pluginContainer: 0x6c),
        Layout(label: "27.3d", bundleSize: 0x25c, bundleID: 0x0c, container: 0x6c, name: 0x70, displayName: 0x78, bundlePath: 0x00, pluginSize: 0x0f0, pluginBundleID: 0x04, pluginContainer: 0x6c),
    ]

    private struct Record {
        let bid: UInt32
        let name: UInt32
        let display: UInt32
        let container: UInt32
        let bundlePath: UInt32
    }

    // MARK: - Primitive helpers

    private static func u32(_ b: [UInt8], _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= b.count else { return nil }
        return UInt32(b[offset])
            | (UInt32(b[offset + 1]) << 8)
            | (UInt32(b[offset + 2]) << 16)
            | (UInt32(b[offset + 3]) << 24)
    }

    private static func be64(_ b: [UInt8], _ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= b.count else { return nil }
        var value: UInt64 = 0
        for i in 0..<8 { value = (value << 8) | UInt64(b[offset + i]) }
        return value
    }

    /// Chuỗi chiều dài 4 byte, padding về bội của 4 — đúng `wq_cs_string`.
    private static func csString(_ b: [UInt8], _ offset: Int) -> String? {
        guard offset >= 0, offset + 8 <= b.count else { return nil }
        guard let length32 = u32(b, offset + 4) else { return nil }
        let length = Int(length32)
        guard length > 0, length < 0x800, length < b.count - offset - 8 else { return nil }
        if length % 4 != 0 && b[offset + 8 + length] != 0 { return nil }
        let start = offset + 8
        for i in start..<(start + length) where b[i] == 0 { return nil }
        return String(bytes: b[start..<(start + length)], encoding: .utf8)
    }

    private static func looksLikeBundleID(_ value: String?) -> Bool {
        guard let s = value, s.count > 2, s.contains("."), !s.hasPrefix(".") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isDataContainerPath(_ path: String) -> Bool {
        let prefixes = [
            "/private/var/mobile/Containers/Data/Application/",
            "/private/var/mobile/Containers/Data/PluginKitPlugin/"
        ]
        for prefix in prefixes where path.hasPrefix(prefix) && path.count == prefix.count + 36 {
            if UUID(uuidString: String(path.dropFirst(prefix.count))) != nil { return true }
        }
        return false
    }

    private static func cleanPath(_ raw: String) -> String {
        var path = raw
        if path.hasSuffix("/") { path.removeLast() }
        if path.hasPrefix("/var/") { path = "/private" + path }
        return path
    }

    /// Lọc scalar ẩn và scalar đảo chiều ở đầu/cuối tên — `wq_safe_name`.
    private static func safeName(_ value: String?) -> String? {
        guard let s = value, !s.isEmpty else { return nil }
        var scalars: [UInt32] = []
        for scalar in s.unicodeScalars {
            let c = scalar.value
            if c == 0x00ad || (c >= 0x0600 && c <= 0x0605) || c == 0x061c || c == 0x06dd ||
               c == 0x070f || (c >= 0x0890 && c <= 0x0891) || c == 0x08e2 || c == 0x180e ||
               c == 0x200b || c == 0x200e || c == 0x200f || (c >= 0x2060 && c <= 0x2064) ||
               (c >= 0x206a && c <= 0x206f) || c == 0xfeff {
                continue
            }
            scalars.append(c)
        }
        func reordering(_ c: UInt32) -> Bool {
            return (c >= 0x202a && c <= 0x202e) || (c >= 0x2066 && c <= 0x2069)
        }
        var first = 0
        var end = scalars.count
        while first < end && reordering(scalars[first]) { first += 1 }
        while end > first && reordering(scalars[end - 1]) { end -= 1 }
        guard end > first else { return nil }
        var out = ""
        for i in first..<end {
            guard let scalar = UnicodeScalar(scalars[i]) else { return nil }
            out.unicodeScalars.append(scalar)
        }
        return out.isEmpty ? nil : out
    }

    /// Tên Apple tối thiểu để nhận diện offset của field tên trong auto-layout.
    private static let builtinNames: [String: String] = [
        "com.apple.mobilesafari": "Safari",
        "com.apple.Preferences": "Settings",
        "com.apple.camera": "Camera",
        "com.apple.mobilenotes": "Notes",
        "com.apple.MobileSMS": "Messages",
        "com.apple.mobilemail": "Mail",
        "com.apple.weather": "Weather",
        "com.apple.calculator": "Calculator",
        "com.apple.Photos": "Photos",
        "com.apple.AppStore": "App Store",
        "com.apple.Music": "Music",
        "com.apple.Clock": "Clock"
    ]

    // MARK: - Entry point

    static func parse(_ data: Data) -> LSStoreSnapshot? {
        guard data.count >= minStoreBytes, data.count <= maxStoreBytes else { return nil }
        let b = [UInt8](data)
        let n = b.count
        guard n >= 4, b[0] == 0x62, b[1] == 0x64, b[2] == 0x73, b[3] == 0x6c else { return nil } // "bdsl"

        let heapRange = data.range(of: Data("<string>".utf8))
        let heap = heapRange?.lowerBound ?? 0

        let pass = passOne(b, n)
        let decoded = passTwo(b, n, pass.need, heap)
        let refs = containerPathRefs(data, b, n)
        let storePathCount = refs.count

        // Pass 3: chọn layout map được nhiều container nhất.
        var bestContainers: [String: String] = [:]
        var bestDisplay: [String: String] = [:]
        var bestBundleName: [String: String] = [:]
        var bestBundlePaths: [String: String] = [:]
        var bestLayout = layouts[0].label

        for (index, layout) in layouts.enumerated() {
            var containers: [String: String] = [:]
            var display: [String: String] = [:]
            var bundleName: [String: String] = [:]
            var bundlePaths: [String: String] = [:]

            for pair in pass.plugins[index] {
                guard let path = pathFor(pair.container,
                                         strings: decoded.strings,
                                         pathStrings: decoded.pathStrings,
                                         appPathStrings: decoded.appPathStrings),
                      let bid = decoded.strings[NSNumber(value: pair.bid >> 2)] else { continue }
                claim(path: path, bid: bid, kind: "/Data/PluginKitPlugin/", into: &containers)
            }

            for record in pass.records[index] {
                guard let bid = decoded.strings[NSNumber(value: record.bid >> 2)],
                      looksLikeBundleID(bid) else { continue }
                var containerPath: String?
                if record.container != 0, record.container & 3 == 0 {
                    containerPath = pathFor(record.container,
                                            strings: decoded.strings,
                                            pathStrings: decoded.pathStrings,
                                            appPathStrings: decoded.appPathStrings)
                }
                if let path = containerPath {
                    claim(path: path, bid: bid, kind: "/Data/Application/", into: &containers)
                }
                let appPath = record.bundlePath != 0 && record.bundlePath & 3 == 0
                    ? decoded.appPathStrings[NSNumber(value: record.bundlePath >> 2)] as? String
                    : nil
                let cleanContainer = containerPath.map(cleanPath)
                let isAppRecord = (cleanContainer.map { isDataContainerPath($0) && $0.contains("/Data/Application/") } ?? false)
                    || (appPath.map { ($0 as NSString).pathExtension == "app" } ?? false)
                if isAppRecord {
                    if record.name & 3 == 0,
                       let name = safeName(decoded.strings[NSNumber(value: record.name >> 2)]),
                       bundleName[bid] == nil { bundleName[bid] = name }
                    if record.display & 3 == 0,
                       let displayName = safeName(decoded.strings[NSNumber(value: record.display >> 2)]),
                       display[bid] == nil { display[bid] = displayName }
                }
                if let path = appPath, bundlePaths[bid] == nil {
                    bundlePaths[bid] = cleanPath(path)
                }
            }

            containers = containers.filter { $0.value != "__CONFLICT__" }

            if containers.count > bestContainers.count ||
                (containers.count == bestContainers.count && display.count > bestDisplay.count) {
                bestContainers = containers
                bestDisplay = display
                bestBundleName = bundleName
                bestBundlePaths = bundlePaths
                bestLayout = layout.label
            }
        }

        // Layout biết mà chỉ map được ít path → iOS mới; thử tự giải mã layout.
        let knownFails = storePathCount >= 20 && bestContainers.count * 2 < storePathCount
        var finalContainers = bestContainers
        var finalDisplay = bestDisplay
        let finalBundleName = bestBundleName
        let finalBundlePaths = bestBundlePaths
        var finalLayout = bestLayout
        if bestContainers.isEmpty || knownFails {
            if let auto = autoLayout(data, b, n, heap, refs) {
                finalContainers = auto.containers
                finalDisplay = auto.display
                finalLayout = auto.layout
            } else if bestContainers.isEmpty {
                return nil
            }
        }

        var identifiersSet = Set<String>(finalContainers.values)
        identifiersSet.formUnion(finalDisplay.keys)
        let identifiers = identifiersSet.sorted()

        var pathByBundleID: [String: String] = [:]
        for (path, bid) in finalContainers where pathByBundleID[bid] == nil {
            pathByBundleID[bid] = path
        }

        let groupIDs = groupIDsFromStore(data)
        logOnce("launchservices: layout=\(finalLayout) paths=\(storePathCount) mapped=\(finalContainers.count) " +
                "names=\(finalDisplay.count) groups=\(groupIDs.count)")

        return LSStoreSnapshot(
            identifiers: identifiers,
            bundleIDByContainerPath: finalContainers,
            pathByBundleID: pathByBundleID,
            displayNameByBundleID: finalDisplay,
            bundleNameByBundleID: finalBundleName,
            bundlePathByBundleID: finalBundlePaths,
            groupIDByContainerPath: groupIDs,
            layout: finalLayout,
            containerPathCount: storePathCount
        )
    }

    // MARK: - Pass 1: records

    private static func passOne(_ b: [UInt8], _ n: Int)
        -> (records: [[Record]], plugins: [[(bid: UInt32, container: UInt32)]], need: [Bool]) {
        var records = [[Record]](repeating: [], count: layouts.count)
        var plugins = [[(bid: UInt32, container: UInt32)]](repeating: [], count: layouts.count)
        var need = [Bool](repeating: false, count: Int(maxStringID / 8))
        var tooMany = false

        var offset = 0
        while offset + 8 + maxRecordSize <= n, !tooMany {
            guard let size = u32(b, offset + 4) else { break }
            let body = offset + 8
            for (index, layout) in layouts.enumerated() {
                if size == layout.pluginSize {
                    guard let rawBid = u32(b, body + Int(layout.pluginBundleID)),
                          let rawContainer = u32(b, body + Int(layout.pluginContainer)) else { continue }
                    let valid = { (v: UInt32) -> Bool in v != 0 && v & 3 == 0 && (v >> 2) < maxStringID }
                    if valid(rawBid), valid(rawContainer),
                       plugins[index].count < maxBundleRecords {
                        plugins[index].append((rawBid, rawContainer))
                        markNeed(rawBid, &need)
                        markNeed(rawContainer, &need)
                    }
                }
                guard size == layout.bundleSize else { continue }
                if records[index].count >= maxBundleRecords {
                    tooMany = true
                    break
                }
                guard let refBid = u32(b, body + Int(layout.bundleID)),
                      let refName = u32(b, body + Int(layout.name)),
                      let refDisplay = u32(b, body + Int(layout.displayName)),
                      let refContainer = u32(b, body + Int(layout.container)),
                      let refBundlePath = u32(b, body + Int(layout.bundlePath)) else { continue }
                guard refBid != 0, refBid & 3 == 0, (refBid >> 2) < maxStringID else { continue }
                records[index].append(Record(bid: refBid, name: refName,
                                             display: refDisplay, container: refContainer,
                                             bundlePath: refBundlePath))
                markNeed(refBid, &need)
                markNeed(refName, &need)
                markNeed(refDisplay, &need)
                markNeed(refContainer, &need)
                markNeed(refBundlePath, &need)
            }
            offset += 4
        }
        return (records, plugins, need)
    }

    private static func markNeed(_ ref: UInt32, _ need: inout [Bool]) {
        guard ref != 0, ref & 3 == 0 else { return }
        let id = Int(ref >> 2)
        guard id < need.count else { return }
        need[id] = true
    }

    // MARK: - Pass 2: strings

    private static func passTwo(_ b: [UInt8], _ n: Int, _ need: [Bool], _ heap: Int)
        -> (strings: [NSNumber: String],
            pathStrings: [NSNumber: Any],
            appPathStrings: [NSNumber: Any]) {
        var strings: [NSNumber: String] = [:]
        var pathStrings: [NSNumber: Any] = [:]
        var appPathStrings: [NSNumber: Any] = [:]
        var inHeap = [Bool](repeating: false, count: need.count)
        var decodedBytes = 0
        var tooMany = false

        var offset = 0
        while offset <= n - 8, !tooMany {
            guard let sid = u32(b, offset), sid != 0, sid < maxStringID else {
                offset += 4
                continue
            }
            let id = Int(sid)
            guard need[id] else {
                offset += 4
                continue
            }
            let here = offset >= heap
            let had = strings[NSNumber(value: id)] != nil
            let keepGeneral = !had || (here && !inHeap[id])
            let peek = u32(b, offset + 4) ?? 0
            let maybePath = peek >= 6 && peek < 0x400 && offset + 8 < n && b[offset + 8] == 0x2f
            if !keepGeneral && !maybePath {
                offset += 4
                continue
            }
            guard let string = csString(b, offset) else {
                offset += 4
                continue
            }
            if maybePath {
                let table: Bool = string.contains("/mobile/Containers/Data/")
                let appTable: Bool = string.hasSuffix(".app") || string.hasSuffix(".app/")
                if table || appTable {
                    let key = NSNumber(value: id)
                    if table {
                        storePath(string, key: key, in: &pathStrings)
                    } else if appTable {
                        storePath(string, key: key, in: &appPathStrings)
                    }
                }
            }
            if keepGeneral {
                let key = NSNumber(value: id)
                if !had {
                    guard strings.count < maxDecodedStrings,
                          string.utf8.count <= maxDecodedStringBytes - decodedBytes else {
                        tooMany = true
                        break
                    }
                    decodedBytes += string.utf8.count
                }
                strings[key] = string
                if here { inHeap[id] = true }
            }
            offset += 4
        }
        return (strings, pathStrings, appPathStrings)
    }

    /// Một id mà trỏ tới hai path khác nhau thì không dùng được (đánh dấu NSNull).
    private static func storePath(_ string: String, key: NSNumber, in table: inout [NSNumber: Any]) {
        if let previous = table[key] as? String {
            if previous != string { table[key] = NSNull() }
        } else if table[key] == nil {
            table[key] = string
        }
    }

    private static func pathFor(_ ref: UInt32,
                                strings: [NSNumber: String],
                                pathStrings: [NSNumber: Any],
                                appPathStrings: [NSNumber: Any]) -> String? {
        guard ref != 0, ref & 3 == 0 else { return nil }
        let key = NSNumber(value: ref >> 2)
        if let path = pathStrings[key] as? String { return path }
        if pathStrings[key] is NSNull { return nil }
        return strings[key]
    }

    private static func claim(path raw: String?, bid: String, kind: String,
                              into containers: inout [String: String]) {
        guard let raw else { return }
        let path = cleanPath(raw)
        guard isDataContainerPath(path), path.contains(kind), looksLikeBundleID(bid) else { return }
        if let known = containers[path] {
            if known != bid { containers[path] = "__CONFLICT__" }
        } else {
            containers[path] = bid
        }
    }

    // MARK: - Layout-independent path refs

    private static func containerPathRefs(_ data: Data, _ b: [UInt8], _ n: Int) -> [UInt32] {
        let needle = Data("/var/mobile/Containers/Data/".utf8)
        var refs: Set<UInt32> = []
        var searchStart = data.startIndex
        while let range = data.range(of: needle, options: [], in: searchStart..<data.endIndex) {
            searchStart = range.upperBound
            let hit = range.lowerBound
            var start = hit
            if hit >= 8, Data(b[hit - 8..<hit]) == Data("/private".utf8) { start = hit - 8 }
            let offset = start
            guard offset >= 8, offset % 4 == 0 else { continue }
            guard let length = u32(b, offset - 4) else { continue }
            guard length >= UInt32(needle.count), length <= 0x100, Int(length) <= n - offset else { continue }
            guard let sid = u32(b, offset - 8) else { continue }
            let ref = sid << 2
            if ref != 0, refs.count < 20_000 { refs.insert(ref) }
        }
        return refs.sorted()
    }

    // MARK: - Auto layout (iOS mới, layout chưa biết)

    private struct AutoResult {
        let containers: [String: String]
        let display: [String: String]
        let layout: String
    }

    private static func autoLayout(_ data: Data, _ b: [UInt8], _ n: Int, _ heap: Int,
                                   _ refs: [UInt32]) -> AutoResult? {
        let pathCount = refs.count
        guard pathCount >= 20 else { return nil }
        let minVotes = max(10, pathCount / 50)
        let refSet = Set(refs)

        let build = osBuild()
        let defaults = UserDefaults.standard
        var rememberedTypes: [[String: Any]]?
        if let saved = defaults.dictionary(forKey: autoLayoutDefaultsKey),
           saved["build"] as? String == build,
           let types = saved["types"] as? [[String: Any]], !types.isEmpty {
            rememberedTypes = types
        }

        var ranked: [UInt64] = []
        if let types = rememberedTypes {
            ranked = types.compactMap { type in
                guard let size = type["size"] as? NSNumber, let container = type["container"] as? NSNumber else { return nil }
                return size.uint64Value << 16 | container.uint64Value
            }
        } else {
            var votes: [UInt64: Int] = [:]
            var matches = 0
            var steps = 0
            var cutOff = false
            var q = 0
            outer: while q + 4 <= n, !cutOff {
                defer { q += 4 }
                guard let value = u32(b, q), value != 0, value & 3 == 0, refSet.contains(value) else { continue }
                matches += 1
                if matches > maxVoteMatches { cutOff = true; break }
                var k = 0
                while k < 0x400 && q >= 8 + k {
                    steps += 1
                    if steps > maxVoteSteps { cutOff = true; break outer }
                    guard let size = u32(b, q - 8 - k + 4) else { break }
                    if size >= 0x40, size <= 0x800, size % 4 == 0, UInt32(k) < size {
                        let key = UInt64(size) << 16 | UInt64(k)
                        let count = (votes[key] ?? 0) + 1
                        if votes.count < maxVoteKeys || votes[key] != nil { votes[key] = count }
                    }
                    k += 4
                }
            }
            ranked = votes.filter { $0.value >= minVotes }
                .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key > $1.key) }
                .map { $0.key }
            if ranked.count > 10 { ranked = Array(ranked.prefix(10)) }
        }
        guard !ranked.isEmpty else { return nil }

        let types = ranked.map { (size: UInt32($0 >> 16), container: UInt32($0 & 0xffff)) }
        let collected = autoCollect(b, n, heap, refSet, types)
        guard collected.count == types.count else { return nil }

        var needed = [Bool](repeating: false, count: Int(maxStringID / 8))
        for (offsets, type) in zip(collected, types) where !offsets.isEmpty {
            for body in offsets {
                var k: UInt32 = 0
                while k + 4 <= type.size, body + Int(k) + 4 <= n {
                    if let ref = u32(b, body + Int(k)) { markNeed(ref, &needed) }
                    k += 4
                }
            }
        }
        let decoded = passTwo(b, n, needed, heap)
        let strings = decoded.strings
        let paths = decoded.pathStrings

        func containerPath(_ ref: UInt32) -> String? {
            guard let value = paths[NSNumber(value: ref >> 2)] as? String else { return nil }
            let clean = cleanPath(value)
            return isDataContainerPath(clean) ? clean : nil
        }

        func mapFor(_ typeIndex: Int, _ containerOffset: UInt32, _ bundleOffset: UInt32) -> [String: String] {
            var map: [String: String] = [:]
            for body in collected[typeIndex] {
                guard body + Int(containerOffset) + 4 <= n, body + Int(bundleOffset) + 4 <= n else { continue }
                guard let bref = u32(b, body + Int(bundleOffset)),
                      let cref = u32(b, body + Int(containerOffset)) else { continue }
                guard bref != 0, bref & 3 == 0 else { continue }
                guard let bid = strings[NSNumber(value: bref >> 2)],
                      let path = containerPath(cref), looksLikeBundleID(bid) else { continue }
                if let known = map[path] {
                    if known != bid { map[path] = "__CONFLICT__" }
                } else {
                    map[path] = bid
                }
            }
            return map.filter { $0.value != "__CONFLICT__" }
        }

        struct Candidate {
            let map: [String: String]
            let distinct: Int
            let size: UInt32
            let containerOffset: UInt32
            let bundleOffset: UInt32
            let index: Int
        }
        var results: [Candidate] = []
        for (index, type) in types.enumerated() {
            var best: Candidate?
            if let rememberedTypes {
                let match = rememberedTypes[index]
                guard let bundleOffset = match["bundle"] as? NSNumber,
                      bundleOffset.uint64Value + 4 <= UInt64(type.size) else { continue }
                let map = mapFor(index, type.container, bundleOffset.uint32Value)
                best = Candidate(map: map, distinct: Set(map.values).count, size: type.size,
                                 containerOffset: type.container, bundleOffset: bundleOffset.uint32Value, index: index)
            } else {
                var bundleOffset: UInt32 = 0
                while bundleOffset + 4 <= type.size {
                    defer { bundleOffset += 4 }
                    if bundleOffset == type.container { continue }
                    let map = mapFor(index, type.container, bundleOffset)
                    let distinct = Set(map.values).count
                    if distinct * 10 < map.count * 9 { continue }
                    if best == nil || distinct > best!.distinct {
                        best = Candidate(map: map, distinct: distinct, size: type.size,
                                         containerOffset: type.container, bundleOffset: bundleOffset, index: index)
                    }
                }
            }
            if let best, best.map.count >= minVotes { results.append(best) }
        }
        guard !results.isEmpty else { return nil }
        results.sort { $0.map.count > $1.map.count }

        var containers = results[0].map
        var used: [Candidate] = [results[0]]
        for candidate in results.dropFirst() where used.count < 2 {
            guard candidate.size != results[0].size else { continue }
            var added = 0
            var conflicts = 0
            for (path, bid) in candidate.map {
                if let known = containers[path] {
                    if known != bid { conflicts += 1 }
                } else {
                    added += 1
                }
            }
            if conflicts * 20 > candidate.map.count || added < minVotes { continue }
            for (path, bid) in candidate.map where containers[path] == nil { containers[path] = bid }
            used.append(candidate)
        }
        guard containers.count * 2 >= pathCount else { return nil }

        var display: [String: String] = [:]
        for result in results {
            var bestName: UInt32?
            var bestMatches = 0
            var nameOffset: UInt32 = 0
            while nameOffset + 4 <= result.size {
                defer { nameOffset += 4 }
                if nameOffset == result.bundleOffset { continue }
                var matches = 0
                for body in collected[result.index] {
                    guard let bref = u32(b, body + Int(result.bundleOffset)),
                          let nref = u32(b, body + Int(nameOffset)) else { continue }
                    guard bref & 3 == 0, nref != 0, nref & 3 == 0 else { continue }
                    let bid = strings[NSNumber(value: bref >> 2)] ?? ""
                    if let known = builtinNames[bid], strings[NSNumber(value: nref >> 2)] == known { matches += 1 }
                }
                if matches > bestMatches { bestMatches = matches; bestName = nameOffset }
            }
            guard bestMatches >= 3, let chosenName = bestName else { continue }
            for body in collected[result.index] {
                guard let bref = u32(b, body + Int(result.bundleOffset)),
                      let nref = u32(b, body + Int(chosenName)) else { continue }
                guard bref & 3 == 0, nref != 0, nref & 3 == 0 else { continue }
                guard let bid = strings[NSNumber(value: bref >> 2)],
                      let name = safeName(strings[NSNumber(value: nref >> 2)]),
                      looksLikeBundleID(bid), display[bid] == nil else { continue }
                display[bid] = name
            }
        }

        if rememberedTypes == nil {
            let stored = results.map { result -> [String: Any] in
                ["size": NSNumber(value: result.size),
                 "container": NSNumber(value: result.containerOffset),
                 "bundle": NSNumber(value: result.bundleOffset)]
            }
            defaults.set(["build": build, "types": stored], forKey: autoLayoutDefaultsKey)
        }

        var listed = containers
        for value in paths.values {
            guard let raw = value as? String else { continue }
            let clean = cleanPath(raw)
            if isDataContainerPath(clean), listed[clean] == nil { listed[clean] = "__UNLABELED__" }
        }
        listed = listed.filter { $0.value != "__UNLABELED__" }

        let parts = results.map { "0x\(String($0.size, radix: 16))@0x\(String($0.containerOffset, radix: 16))" }
        return AutoResult(containers: listed, display: display, layout: "auto[\(parts.joined(separator: ","))]")
    }

    private static func autoCollect(_ b: [UInt8], _ n: Int, _ heap: Int,
                                    _ refs: Set<UInt32>,
                                    _ types: [(size: UInt32, container: UInt32)]) -> [[Int]] {
        var result = [[Int]](repeating: [], count: types.count)
        var total = 0
        var offset = 0
        while offset + 8 <= n, total < 200_000 {
            defer { offset += 4 }
            guard let size = u32(b, offset + 4) else { continue }
            for (index, type) in types.enumerated() {
                guard size == type.size, offset + 8 + Int(size) <= n,
                      type.container + 4 <= size else { continue }
                guard let ref = u32(b, offset + 8 + Int(type.container)),
                      ref != 0, ref & 3 == 0, refs.contains(ref) else { continue }
                result[index].append(offset + 8)
                total += 1
            }
        }
        return result
    }

    private static func osBuild() -> String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size + 1)
        let status = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            var len = size
            return sysctlbyname("kern.osversion", ptr.baseAddress, &len, nil, 0)
        }
        guard status == 0 else { return "" }
        return String(cString: buffer)
    }

    // MARK: - App Group IDs từ plist nhúng

    private static func groupIDsFromStore(_ data: Data) -> [String: String] {
        let needle = Data("/mobile/Containers/Shared/AppGroup/".utf8)
        let magic = Data("bplist00".utf8)
        var parsedOffsets: Set<Int> = []
        var byPath: [String: Set<String>] = [:]
        var searchStart = data.startIndex

        while let range = data.range(of: needle, options: [], in: searchStart..<data.endIndex) {
            searchStart = range.upperBound
            let hit = range.lowerBound
            let from = max(0, hit - 16_384)
            var plistStart: Int?
            var candidate = hit - magic.count
            while candidate >= from {
                if Data(data[candidate..<(candidate + magic.count)]) == magic { plistStart = candidate; break }
                if candidate == 0 { break }
                candidate -= 1
            }
            guard let start = plistStart, !parsedOffsets.contains(start) else { continue }
            parsedOffsets.insert(start)
            var minimum = (hit - start) + needle.count
            for _ in 0..<8 {
                guard let length = bplistLength(data, start, minimum) else { break }
                guard start + length <= data.count else { break }
                let slice = data.subdata(in: start..<(start + length))
                if let plist = try? PropertyListSerialization.propertyList(from: slice, options: [], format: nil) {
                    collectGroupPairs(plist, into: &byPath, depth: 0)
                    break
                }
                minimum = length + 1
            }
        }

        var result: [String: String] = [:]
        for (path, ids) in byPath where ids.count == 1 { result[path] = ids.first! }
        return result
    }

    private static func bplistLength(_ data: Data, _ start: Int, _ minimum: Int) -> Int? {
        let upperBound = min(65_536, data.count - start)
        var length = Swift.max(minimum, 40)
        while length <= upperBound {
            let trailer = start + length - 32
            if trailer < start { return nil }
            if data[trailer] != 0 || data[trailer + 1] != 0 || data[trailer + 2] != 0 ||
               data[trailer + 3] != 0 || data[trailer + 4] != 0 {
                length += 1
                continue
            }
            let offsetSize = Int(data[trailer + 6])
            let refSize = Int(data[trailer + 7])
            guard offsetSize >= 1, offsetSize <= 8, refSize >= 1, refSize <= 8 else {
                length += 1
                continue
            }
            let bytes = [UInt8](data)
            guard let objects = be64(bytes, trailer + 8),
                  let top = be64(bytes, trailer + 16),
                  let table = be64(bytes, trailer + 24) else { return nil }
            guard objects > 0, objects <= 100_000, top < objects, table >= 8 else {
                length += 1
                continue
            }
            let tableBytes = objects * UInt64(offsetSize)
            let expectedLength = tableBytes + UInt64(table) + 32
            if expectedLength == UInt64(length) { return length }
            length += 1
        }
        return nil
    }

    private static let groupRoot = "/private/var/mobile/Containers/Shared/AppGroup/"

    private static func groupKey(_ value: Any?) -> String? {
        guard let path = value as? String else { return nil }
        var clean = path
        if clean.hasPrefix("/var/") { clean = "/private" + clean }
        while clean.hasSuffix("/") { clean.removeLast() }
        guard clean.hasPrefix(groupRoot) else { return nil }
        let uuid = String(clean.dropFirst(groupRoot.count))
        guard uuid.count == 36, UUID(uuidString: uuid) != nil else { return nil }
        return groupRoot + uuid.uppercased()
    }

    private static func plausibleGroupID(_ value: Any?) -> Bool {
        guard let id = value as? String, id.count >= 3, id.count <= 255 else { return false }
        return !id.hasPrefix(".") && !id.hasSuffix(".") && !id.contains("/") && id.contains(".")
    }

    private static func collectGroupPairs(_ object: Any?, into byPath: inout [String: Set<String>], depth: Int) {
        guard depth <= 6 else { return }
        if let dict = object as? [AnyHashable: Any] {
            for (key, value) in dict {
                if let path = groupKey(value), plausibleGroupID(key) {
                    let identifier = String(describing: key)
                    byPath[path, default: []].insert(identifier)
                } else {
                    collectGroupPairs(value, into: &byPath, depth: depth + 1)
                }
            }
        } else if let array = object as? [Any] {
            for item in array { collectGroupPairs(item, into: &byPath, depth: depth + 1) }
        }
    }

    // MARK: - Diagnostics

    private static var lastLog = ""
    private static let logLock = NSLock()
    private static func logOnce(_ text: String) {
        logLock.lock()
        defer { logLock.unlock() }
        guard text != lastLog else { return }
        lastLog = text
        NSLog("[Totorox] %@", text)
    }
}
