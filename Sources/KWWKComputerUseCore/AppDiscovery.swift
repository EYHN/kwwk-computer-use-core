import AppKit
import CoreServices
import Foundation

extension ComputerUseCore {
    static func formatRunningApp(_ app: RunningAppDescriptor) -> String {
        "\(app.name) — \(app.bundleID) [pid \(app.pid)\(app.isActive ? ", active" : "")]"
    }

    static func listApps(recentDays: Int = 14) -> [ComputerUseAppDescriptor] {
        let now = Date()
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -max(0, recentDays),
            to: now
        ) ?? now
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        var appsByKey: [String: ComputerUseAppDescriptor] = [:]

        for url in discoverApplicationBundleURLs() {
            guard let descriptor = appDescriptor(bundleURL: url) else {
                continue
            }
            guard descriptor.lastUsedDate.map({ $0 >= cutoff }) == true else {
                continue
            }
            mergeAppDescriptor(descriptor, into: &appsByKey)
        }

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
            guard let descriptor = appDescriptor(
                runningApplication: app,
                frontmostPID: frontmostPID
            ) else { continue }
            mergeAppDescriptor(descriptor, into: &appsByKey)
        }

        return appsByKey.values.sorted(by: appListSort)
    }

    static func openApp(appIdentifier: String) async throws -> (app: ComputerUseAppDescriptor, didLaunch: Bool) {
        if let running = resolveRunningApplicationIfAvailable(matching: appIdentifier),
           let descriptor = appDescriptor(
               runningApplication: running,
               frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
           ) {
            return (descriptor, false)
        }

        let appURL = try resolveApplicationBundleURL(matching: appIdentifier)
        let launched = try await launchApplication(at: appURL)
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while true {
            if let running = launched ?? resolveRunningApplicationForBundle(at: appURL),
               let descriptor = appDescriptor(
                   runningApplication: running,
                   frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
               ) {
                return (descriptor, true)
            }

            if ProcessInfo.processInfo.systemUptime >= deadline {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        guard let descriptor = appDescriptor(bundleURL: appURL) else {
            throw ComputerUseError.appNotFound(appIdentifier)
        }
        return (descriptor, true)
    }

    static func formatAppListLine(_ app: ComputerUseAppDescriptor) -> String {
        var flags: [String] = []
        if app.isFrontmost {
            flags.append("frontmost")
        }
        if app.isRunning {
            flags.append("running")
        }
        if let lastUsedDate = app.lastUsedDate {
            flags.append("last-used=\(appListDateString(lastUsedDate))")
        }
        if let useCount = app.useCount {
            flags.append("uses=\(useCount)")
        }

        let suffix = flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]"
        return "\(app.name) — \(app.bundleID)\(suffix)"
    }

    static func listRunningApps() -> [RunningAppDescriptor] {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy != .prohibited &&
                    (app.localizedName?.isEmpty == false || app.bundleIdentifier?.isEmpty == false)
            }
            .sorted { lhs, rhs in
                let lhsName = lhs.localizedName ?? lhs.bundleIdentifier ?? ""
                let rhsName = rhs.localizedName ?? rhs.bundleIdentifier ?? ""
                return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
            }
            .map { app in
                RunningAppDescriptor(
                    name: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
                    bundleID: app.bundleIdentifier ?? "",
                    pid: app.processIdentifier,
                    isActive: frontmostPID == app.processIdentifier
                )
            }
    }

    static func resolveRunningApplicationIfAvailable(matching identifier: String) -> NSRunningApplication? {
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }

        if let byBundleID = runningApps.first(where: { $0.bundleIdentifier == identifier }) {
            return byBundleID
        }

        if let byName = runningApps.first(where: {
            ($0.localizedName ?? "").localizedCaseInsensitiveCompare(identifier) == .orderedSame
        }) {
            return byName
        }

        if let containsName = runningApps.first(where: {
            ($0.localizedName ?? "").localizedCaseInsensitiveContains(identifier)
        }) {
            return containsName
        }

        return nil
    }

    private static func mergeAppDescriptor(
        _ incoming: ComputerUseAppDescriptor,
        into appsByKey: inout [String: ComputerUseAppDescriptor]
    ) {
        let key = appListKey(name: incoming.name, bundleID: incoming.bundleID)
        guard var existing = appsByKey[key] else {
            appsByKey[key] = incoming
            return
        }

        existing.name = preferredAppName(existing.name, incoming.name)
        if existing.bundleID.isEmpty {
            existing.bundleID = incoming.bundleID
        }
        existing.pid = existing.pid ?? incoming.pid
        existing.isRunning = existing.isRunning || incoming.isRunning
        existing.isFrontmost = existing.isFrontmost || incoming.isFrontmost
        existing.lastUsedDate = latest(existing.lastUsedDate, incoming.lastUsedDate)
        existing.useCount = maxOptional(existing.useCount, incoming.useCount)
        appsByKey[key] = existing
    }

    private static func discoverApplicationBundleURLs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]

        var urls: [URL] = []
        var seen = Set<String>()
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                guard url.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame else {
                    continue
                }
                let standardizedPath = url.standardizedFileURL.path
                if seen.insert(standardizedPath).inserted {
                    urls.append(url)
                }
                enumerator.skipDescendants()
            }
        }
        return urls
    }

    private static func appDescriptor(bundleURL: URL) -> ComputerUseAppDescriptor? {
        guard let metadata = MDItemCreate(kCFAllocatorDefault, bundleURL.path as CFString) else {
            return nil
        }

        let bundle = Bundle(url: bundleURL)
        let displayName = mdString(metadata, kMDItemDisplayName)
        let name = firstNonEmpty([
            displayName,
            bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
            bundleURL.deletingPathExtension().lastPathComponent,
        ]) ?? "Unknown"
        let bundleID = firstNonEmpty([
            bundle?.bundleIdentifier,
            mdString(metadata, kMDItemCFBundleIdentifier),
        ]) ?? ""

        return ComputerUseAppDescriptor(
            name: name,
            bundleID: bundleID,
            pid: nil,
            isRunning: false,
            isFrontmost: false,
            lastUsedDate: MDItemCopyAttribute(metadata, kMDItemLastUsedDate) as? Date,
            useCount: mdInt(metadata, "kMDItemUseCount" as CFString)
        )
    }

    private static func appDescriptor(
        runningApplication app: NSRunningApplication,
        frontmostPID: pid_t?
    ) -> ComputerUseAppDescriptor? {
        guard app.localizedName?.isEmpty == false || app.bundleIdentifier?.isEmpty == false else {
            return nil
        }

        let metadata = app.bundleURL.flatMap(appDescriptor(bundleURL:))
        return ComputerUseAppDescriptor(
            name: app.localizedName ?? metadata?.name ?? app.bundleIdentifier ?? "Unknown",
            bundleID: app.bundleIdentifier ?? metadata?.bundleID ?? "",
            pid: app.processIdentifier,
            isRunning: true,
            isFrontmost: frontmostPID == app.processIdentifier,
            lastUsedDate: metadata?.lastUsedDate,
            useCount: metadata?.useCount
        )
    }

    private static func resolveApplicationBundleURL(matching identifier: String) throws -> URL {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw ComputerUseError.invalidArgument("app is required")
        }

        let explicitURL = URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
        if explicitURL.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame,
           FileManager.default.fileExists(atPath: explicitURL.path) {
            return explicitURL
        }

        let candidates = discoverApplicationBundleURLs().compactMap { url -> (url: URL, descriptor: ComputerUseAppDescriptor)? in
            guard let descriptor = appDescriptor(bundleURL: url) else { return nil }
            return (url, descriptor)
        }

        if let exactBundleID = candidates.first(where: {
            $0.descriptor.bundleID.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return exactBundleID.url
        }

        if let exactName = candidates.first(where: {
            $0.descriptor.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return exactName.url
        }

        if let containsName = candidates.first(where: {
            $0.descriptor.name.localizedCaseInsensitiveContains(trimmed)
        }) {
            return containsName.url
        }

        throw ComputerUseError.appNotFound(identifier)
    }

    private static func launchApplication(at url: URL) async throws -> NSRunningApplication? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false

        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: app)
                }
            }
        }
    }

    private static func resolveRunningApplicationForBundle(at url: URL) -> NSRunningApplication? {
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            return nil
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.activationPolicy != .prohibited })
    }

    private static func mdString(_ item: MDItem, _ attribute: CFString) -> String? {
        MDItemCopyAttribute(item, attribute) as? String
    }

    private static func mdInt(_ item: MDItem, _ attribute: CFString) -> Int? {
        switch MDItemCopyAttribute(item, attribute) {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        values.first { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        } ?? nil
    }

    private static func appListKey(name: String, bundleID: String) -> String {
        if bundleID.isEmpty == false {
            return "bundle:\(bundleID)"
        }
        return "name:\(name.lowercased())"
    }

    private static func preferredAppName(_ lhs: String, _ rhs: String) -> String {
        if lhs == "Unknown" { return rhs }
        if rhs == "Unknown" { return lhs }
        return lhs.count <= rhs.count ? lhs : rhs
    }

    private static func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return max(lhs, rhs)
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }

    private static func maxOptional(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return max(lhs, rhs)
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }

    private static func appListSort(
        lhs: ComputerUseAppDescriptor,
        rhs: ComputerUseAppDescriptor
    ) -> Bool {
        if lhs.isFrontmost != rhs.isFrontmost {
            return lhs.isFrontmost
        }
        if lhs.isRunning != rhs.isRunning {
            return lhs.isRunning
        }
        switch (lhs.lastUsedDate, rhs.lastUsedDate) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        switch (lhs.useCount, rhs.useCount) {
        case let (lhsCount?, rhsCount?) where lhsCount != rhsCount:
            return lhsCount > rhsCount
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func appListDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
