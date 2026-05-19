import AppKit
import ApplicationServices
import Foundation

// Temporary benchmark for WeChat AX read performance. Remove when investigation is done.

public enum WeChatAXBenchmark {
    private struct TimingStats {
        var attributeCalls: Int = 0
        var attributeNs: UInt64 = 0
        var actionCalls: Int = 0
        var actionNs: UInt64 = 0
        var settableCalls: Int = 0
        var settableNs: UInt64 = 0
        var childCalls: Int = 0
        var childNs: UInt64 = 0
        var nodesVisited: Int = 0
        var nodesEmitted: Int = 0
        var nodesPruned: Int = 0
        var maxDepth: Int = 0
        var roleCounts: [String: Int] = [:]

        mutating func recordAttribute(_ ns: UInt64) {
            attributeCalls += 1
            attributeNs += ns
        }

        mutating func recordAction(_ ns: UInt64) {
            actionCalls += 1
            actionNs += ns
        }

        mutating func recordSettable(_ ns: UInt64) {
            settableCalls += 1
            settableNs += ns
        }

        mutating func recordChildren(_ ns: UInt64) {
            childCalls += 1
            childNs += ns
        }
    }

    public static func run() {
        guard AXIsProcessTrusted() else {
            fputs("Accessibility permission required. Enable in System Settings → Privacy & Security → Accessibility.\n", stderr)
            exit(1)
        }

        guard let app = findWeChat() else {
            fputs("WeChat is not running. Open WeChat and retry.\n", stderr)
            exit(1)
        }

        print("WeChat: \(app.localizedName ?? "?") bundle=\(app.bundleIdentifier ?? "?") pid=\(app.processIdentifier)")

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        ChromiumAccessibilityActivation.shared.activateIfNeeded(
            pid: app.processIdentifier,
            root: appElement
        )
        let preferredWindowID = preferredWeChatWindowID(app: app)
        let windowMatch: (element: AXUIElement, title: String, frame: CGRect, cgWindow: CUWindowSnapshot)
        do {
            windowMatch = try ComputerUseCore.resolveWindow(
                in: appElement,
                app: app,
                titleSubstring: ProcessInfo.processInfo.environment["KWWK_WECHAT_BENCHMARK_WINDOW_TITLE"],
                preferredWindowID: preferredWindowID
            )
        } catch {
            fputs("Could not resolve WeChat window via AX: \(error)\n", stderr)
            exit(1)
        }
        let window = windowMatch.element
        let title = windowMatch.title
        let frame = windowMatch.frame
        print("Window: \"\(title)\" id=\(windowMatch.cgWindow.windowID) frame=\(frame)")

        _ = cuTitle(window)

        print("\n--- Pass 1: children-only walk (role + children) ---")
        let childrenOnly = benchmarkChildrenOnly(root: window)
        print(String(format: "Nodes: %d, time: %.1f ms", childrenOnly.nodes, ms(childrenOnly.ns)))

        print("\n--- Pass 2: instrumented production-like flattenTree ---")
        var stats = TimingStats()
        let focused = cuAttribute(appElement, name: kAXFocusedUIElementAttribute as String) as AXUIElement?
        let t0 = benchNow()
        _ = instrumentedFlattenTree(
            from: window,
            focusedElement: focused,
            visibleFrame: frame,
            filterVisibleNodes: true,
            stats: &stats
        )
        printStats("Instrumented flattenTree (filter visible)", stats: stats, totalNs: benchNow() - t0)

        print("\n--- Pass 3: instrumented flattenTree (no visible filter) ---")
        var statsNoFilter = TimingStats()
        let t1 = benchNow()
        _ = instrumentedFlattenTree(
            from: window,
            focusedElement: focused,
            visibleFrame: frame,
            filterVisibleNodes: false,
            stats: &statsNoFilter
        )
        printStats("Instrumented flattenTree (no filter)", stats: statsNoFilter, totalNs: benchNow() - t1)

        print("\n--- Pass 3b: captureSnapshot phase breakdown ---")
        let appElement2 = AXUIElementCreateApplication(app.processIdentifier)
        var t = benchNow()
        ChromiumAccessibilityActivation.shared.activateIfNeeded(pid: app.processIdentifier, root: appElement2)
        print(String(format: "  chromium activation: %.1f ms", ms(benchNow() - t)))
        t = benchNow()
        let windowMatch2 = try? ComputerUseCore.resolveWindow(
            in: appElement2,
            app: app,
            titleSubstring: "WeChat (Chats)",
            preferredWindowID: preferredWindowID
        )
        print(String(format: "  resolveWindow: %.1f ms", ms(benchNow() - t)))
        if let windowMatch2 {
            t = benchNow()
            _ = ComputerUseCore.popupMenuCandidate(in: appElement2)
            print(String(format: "  popupMenuCandidate: %.1f ms", ms(benchNow() - t)))
            t = benchNow()
            _ = ComputerUseCore.activeMenuBarItemCandidate(in: appElement2)
            print(String(format: "  activeMenuBarItemCandidate: %.1f ms", ms(benchNow() - t)))
            t = benchNow()
            _ = ComputerUseCore.activeStatusMenuItemCandidate(in: appElement2)
            print(String(format: "  activeStatusMenuItemCandidate: %.1f ms", ms(benchNow() - t)))
            t = benchNow()
            let statusCount = ComputerUseCore.statusMenuExtraCandidates(in: appElement2).count
            print(String(format: "  statusMenuExtraCandidates: %.1f ms (found %d)", ms(benchNow() - t), statusCount))
            t = benchNow()
            _ = ComputerUseCore.statusMenuExtraCandidates(in: appElement2)
            print(String(format: "  statusMenuExtraCandidates (2nd): %.1f ms", ms(benchNow() - t)))
        }

        print("\n--- Pass 4: ComputerUseCore.captureSnapshot (production path) ---")
        let iterations = 3
        var captureTimes: [Double] = []
        for i in 1 ... iterations {
            let start = benchNow()
            do {
                let snapshot = try ComputerUseCore.captureSnapshot(
                    appIdentifier: app.bundleIdentifier ?? "com.tencent.xinWeChat",
                    selection: .init(
                        titleSubstring: ProcessInfo.processInfo.environment["KWWK_WECHAT_BENCHMARK_WINDOW_TITLE"] ?? "WeChat (Chats)",
                        windowID: preferredWindowID
                    ),
                    includeScreenshot: false,
                    filterVisibleNodes: true
                )
                let elapsed = ms(benchNow() - start)
                captureTimes.append(elapsed)
                print(String(format: "  run %d: %.1f ms, nodes=%d", i, elapsed, snapshot.nodes.count))
            } catch {
                print("  run \(i) failed: \(error)")
            }
        }
        if captureTimes.isEmpty == false {
            let min = captureTimes.min()!
            let max = captureTimes.max()!
            let avg = captureTimes.reduce(0, +) / Double(captureTimes.count)
            print(String(format: "captureSnapshot: min=%.1f ms avg=%.1f ms max=%.1f ms", min, avg, max))
        }

        print("\n--- Pass 5: actions vs attributes (from pass 2) ---")
        if stats.nodesEmitted > 0, stats.attributeNs > 0 {
            let actionPct = 100.0 * Double(stats.actionNs) / Double(stats.attributeNs)
            print(String(format: "AXCopyActionNames: %.1f ms (~%.0f%% of attribute time, %d calls @ %.3f ms/call)",
                         ms(stats.actionNs), actionPct, stats.actionCalls,
                         ms(stats.actionNs) / Double(max(1, stats.actionCalls))))
            print(String(format: "AXIsAttributeSettable: %.1f ms (%d calls @ %.3f ms/call)",
                         ms(stats.settableNs), stats.settableCalls,
                         ms(stats.settableNs) / Double(max(1, stats.settableCalls))))
        }

        print("\nDone.")
    }

    @inline(__always)
    private static func benchNow() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    }

    private static func ms(_ ns: UInt64) -> Double {
        Double(ns) / 1_000_000
    }

    private static func preferredWeChatWindowID(app: NSRunningApplication) -> Int? {
        if let raw = ProcessInfo.processInfo.environment["KWWK_WECHAT_BENCHMARK_WINDOW_ID"],
           let windowID = Int(raw) {
            return windowID
        }

        let cgWindows = cuCGWindows(for: app.processIdentifier)
        if let chats = cgWindows.first(where: { $0.name == "WeChat (Chats)" && $0.layer == 0 }) {
            return chats.windowID
        }
        return cgWindows.first(where: { $0.layer == 0 && $0.name.isEmpty == false })?.windowID
    }

    private static func findWeChat() -> NSRunningApplication? {
        let candidates = [
            "com.tencent.xinWeChat",
            "com.tencent.WeChatMac",
        ]
        for bundleID in candidates {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                return app
            }
        }
        return NSWorkspace.shared.runningApplications.first {
            ($0.localizedName ?? "").localizedCaseInsensitiveContains("WeChat") ||
                ($0.localizedName ?? "").contains("微信")
        }
    }

    private static func instrumentedFlattenTree(
        from root: AXUIElement,
        focusedElement: AXUIElement?,
        visibleFrame: CGRect,
        filterVisibleNodes: Bool,
        stats: inout TimingStats
    ) -> Int {
        struct PendingNode {
            let children: [PendingNode]
        }

        var visited = Set<CFHashCode>()

        func timedAttribute<T>(_ element: AXUIElement, name: String) -> T? {
            let start = benchNow()
            let value: T? = cuAttribute(element, name: name)
            stats.recordAttribute(benchNow() - start)
            return value
        }

        func timedRawAttribute(_ element: AXUIElement, name: String) -> Any? {
            let start = benchNow()
            let value = cuRawAttribute(element, name: name)
            stats.recordAttribute(benchNow() - start)
            return value
        }

        func timedActions(_ element: AXUIElement) -> [String] {
            let start = benchNow()
            let value = cuActions(element)
            stats.recordAction(benchNow() - start)
            return value
        }

        func timedSettable(_ element: AXUIElement, name: String) -> Bool {
            let start = benchNow()
            let value = cuIsAttributeSettable(element, name: name)
            stats.recordSettable(benchNow() - start)
            return value
        }

        func timedChildren(_ element: AXUIElement, role: String) -> [AXUIElement] {
            let start = benchNow()
            let value = cuChildElementsForWalk(element, role: role)
            stats.recordChildren(benchNow() - start)
            return value
        }

        func build(
            _ element: AXUIElement,
            depth: Int,
            visibleClip: CGRect,
            insideWebArea: Bool
        ) -> PendingNode? {
            stats.nodesVisited += 1
            stats.maxDepth = max(stats.maxDepth, depth)
            guard depth <= 64 else { return nil }

            let identifier = CFHash(element)
            if visited.contains(identifier) { return nil }
            visited.insert(identifier)

            let role = timedAttribute(element, name: kAXRoleAttribute as String) as String? ?? "AXUnknown"
            stats.roleCounts[role, default: 0] += 1
            _ = timedAttribute(element, name: kAXSubroleAttribute as String) as String? ?? ""
            let titleStart = benchNow()
            let title = cuTitle(element)
            stats.recordAttribute(benchNow() - titleStart)
            let descStart = benchNow()
            let description = cuDescription(element)
            stats.recordAttribute(benchNow() - descStart)
            let frameStart = benchNow()
            let frame = cuFrame(element)
            stats.recordAttribute(benchNow() - frameStart)

            let focused = focusedElement.map { CFEqual($0, element) }
            let selected = timedAttribute(element, name: kAXSelectedAttribute as String) as Bool?
            let hidden = timedAttribute(element, name: "AXHidden") as Bool?
            if hidden == true, depth > 0, focused != true, selected != true {
                stats.nodesPruned += 1
                return nil
            }

            let rawChildren = timedChildren(element, role: role)
            _ = cuCollectionSummary(element, role: role)
            let childVisibleClip = filterVisibleNodes
                ? cuDescendantVisibleClip(role: role, frame: frame, inheritedClip: visibleClip)
                : visibleClip
            let childInsideWebArea = insideWebArea || role == "AXWebArea"
            let children = rawChildren.compactMap {
                build($0, depth: depth + 1, visibleClip: childVisibleClip, insideWebArea: childInsideWebArea)
            }

            let frameVisible = insideWebArea
                ? cuWebFrameIsMeaningfullyVisible(frame, in: visibleClip)
                : cuFrameIsVisible(frame, in: visibleClip)
            let visible = if roleCanContainVisibleDescendants(role) {
                frameVisible || children.isEmpty == false
            } else {
                insideWebArea
                    ? cuWebFrameIsMeaningfullyVisible(frame, in: visibleClip)
                    : cuFrameIsMeaningfullyVisible(frame, in: visibleClip)
            }
            let selfDescribingStructuralNode = roleCanContainVisibleDescendants(role) &&
                (!title.isEmpty || !description.isEmpty)
            if filterVisibleNodes,
               depth > 0,
               !visible,
               !selfDescribingStructuralNode,
               focused != true,
               selected != true
            {
                stats.nodesPruned += 1
                return nil
            }

            _ = timedRawAttribute(element, name: kAXValueAttribute as String)
            _ = timedAttribute(element, name: kAXHelpAttribute as String) as String?
            _ = timedAttribute(element, name: kAXIdentifierAttribute as String) as String?
            _ = timedAttribute(element, name: kAXURLAttribute as String) as URL?
            _ = timedAttribute(element, name: kAXEnabledAttribute as String) as Bool?
            _ = timedAttribute(element, name: kAXExpandedAttribute as String) as Bool?
            _ = timedActions(element)
            _ = timedSettable(element, name: kAXValueAttribute as String)
            stats.nodesEmitted += 1
            return PendingNode(children: children)
        }

        guard build(root, depth: 0, visibleClip: visibleFrame, insideWebArea: false) != nil else {
            return 0
        }
        return stats.nodesEmitted
    }

    private static func printStats(_ label: String, stats: TimingStats, totalNs: UInt64) {
        print("\n=== \(label) ===")
        print(String(format: "Total: %.1f ms", ms(totalNs)))
        print("Nodes visited: \(stats.nodesVisited), emitted: \(stats.nodesEmitted), pruned: \(stats.nodesPruned), maxDepth: \(stats.maxDepth)")
        print(String(format: "AX attribute calls: %d (%.1f ms, %.3f ms/call)",
                     stats.attributeCalls, ms(stats.attributeNs), ms(stats.attributeNs) / Double(max(1, stats.attributeCalls))))
        print(String(format: "AX action calls: %d (%.1f ms, %.3f ms/call)",
                     stats.actionCalls, ms(stats.actionNs), ms(stats.actionNs) / Double(max(1, stats.actionCalls))))
        print(String(format: "AX settable calls: %d (%.1f ms, %.3f ms/call)",
                     stats.settableCalls, ms(stats.settableNs), ms(stats.settableNs) / Double(max(1, stats.settableCalls))))
        print(String(format: "AX children calls: %d (%.1f ms, %.3f ms/call)",
                     stats.childCalls, ms(stats.childNs), ms(stats.childNs) / Double(max(1, stats.childCalls))))
        let accounted = stats.attributeNs + stats.actionNs + stats.settableNs + stats.childNs
        print(String(format: "Accounted AX IPC: %.1f ms (%.0f%% of total)",
                     ms(accounted), 100 * Double(accounted) / Double(max(1, totalNs))))

        let topRoles = stats.roleCounts.sorted { $0.value > $1.value }.prefix(12)
        print("Top roles:")
        for (role, count) in topRoles {
            print("  \(role): \(count)")
        }
    }

    private static func benchmarkChildrenOnly(root: AXUIElement, maxDepth: Int = 64) -> (nodes: Int, ns: UInt64) {
        var count = 0
        let start = benchNow()
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth <= maxDepth else { return }
            count += 1
            let role = cuAttribute(element, name: kAXRoleAttribute as String) as String? ?? ""
            for child in cuChildElementsForWalk(element, role: role) {
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return (count, benchNow() - start)
    }
}
