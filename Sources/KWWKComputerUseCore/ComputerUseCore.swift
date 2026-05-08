import AppKit
import ApplicationServices
import CryptoKit
import Foundation

struct CUWindowSnapshot {
    let windowID: Int
    let ownerName: String
    let name: String
    let layer: Int
    let alpha: Double
    let bounds: CGRect
}

struct RuntimeAXNode {
    let index: Int
    let depth: Int
    let element: AXUIElement
    let role: String
    let subrole: String
    let title: String
    let description: String
    let value: Any?
    let help: String
    let identifier: String
    let url: URL?
    let enabled: Bool?
    let selected: Bool?
    let expanded: Bool?
    let focused: Bool?
    let frame: CGRect?
    let actions: [String]
    let isValueSettable: Bool
    let valueTypeDescription: String?
}

struct RuntimeAppSnapshot {
    let app: NSRunningApplication
    let appElement: AXUIElement
    let windowElement: AXUIElement
    let windowID: Int
    let windowTitle: String
    let windowFrame: CGRect
    let nodes: [RuntimeAXNode]
    let focusedElementIndex: Int?
    let selectedText: String?
    let screenshotURL: URL?
    let screenshotSize: CGSize?
    let fingerprint: String

    func node(index: Int) throws -> RuntimeAXNode {
        guard let node = nodes.first(where: { $0.index == index }) else {
            throw ComputerUseError.elementNotFound(index)
        }
        return node
    }
}

private struct WindowCandidate {
    let element: AXUIElement
    let title: String
    let frame: CGRect
    let cgWindow: CUWindowSnapshot
    let isMain: Bool
    let isFocused: Bool
}

private struct PopupMenuCandidate {
    let element: AXUIElement
    let frame: CGRect
}

struct WindowSelection {
    var titleSubstring: String?
}

enum ComputerUseCore {
    static func startupInventoryText() -> String {
        let apps = listRunningApps()
        guard apps.isEmpty == false else {
            return ""
        }

        var lines = [
            "Startup macOS app/window inventory.",
            "<computer_use_inventory>",
            "<apps>",
        ]

        lines.append(contentsOf: apps.map(formatRunningApp))
        lines.append("</apps>")

        guard AXIsProcessTrusted() else {
            lines.append("<windows unavailable=\"accessibility_permission_required\" />")
            lines.append("</computer_use_inventory>")
            return lines.joined(separator: "\n")
        }

        lines.append("<windows>")
        var wroteWindowApp = false
        for app in apps {
            guard cuCGWindows(for: app.pid).isEmpty == false else {
                continue
            }

            let identifier = app.bundleID.isEmpty ? app.name : app.bundleID
            guard let windows = try? listWindows(appIdentifier: identifier),
                  windows.isEmpty == false
            else {
                continue
            }

            wroteWindowApp = true
            lines.append("\(app.name) — \(app.bundleID) [pid \(app.pid)]")
            for (index, window) in windows.enumerated() {
                var flags: [String] = []
                if window.isMain { flags.append("main") }
                let flagText = flags.isEmpty ? "" : " [\(flags.joined(separator: ","))]"
                lines.append("[\(index)] window_id=\(window.windowID) title=\"\(window.title)\"\(flagText)")
            }
        }
        if wroteWindowApp == false {
            lines.append("(no readable windows)")
        }
        lines.append("</windows>")
        lines.append("</computer_use_inventory>")
        return lines.joined(separator: "\n")
    }

    static func listWindows(appIdentifier: String) throws -> [ComputerUseWindowDescriptor] {
        guard AXIsProcessTrusted() else {
            throw ComputerUseError.accessibilityPermissionDenied
        }

        let app = try resolveRunningApplication(matching: appIdentifier)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        ChromiumAccessibilityActivation.shared.activateIfNeeded(
            pid: app.processIdentifier,
            root: appElement
        )

        let appName = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
        let bundleID = app.bundleIdentifier ?? ""
        return windowCandidates(in: appElement, app: app).map { candidate in
            ComputerUseWindowDescriptor(
                appName: appName,
                bundleID: bundleID,
                pid: app.processIdentifier,
                windowID: candidate.cgWindow.windowID,
                title: candidate.title,
                isMain: candidate.isMain
            )
        }
    }

    static func captureSnapshot(
        appIdentifier: String,
        selection: WindowSelection = .init(),
        includeScreenshot: Bool,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault,
        filterVisibleNodes: Bool = false
    ) throws -> RuntimeAppSnapshot {
        guard AXIsProcessTrusted() else {
            throw ComputerUseError.accessibilityPermissionDenied
        }

        let app = try resolveRunningApplication(matching: appIdentifier)
        return try captureSnapshot(
            app: app,
            selection: selection,
            includeScreenshot: includeScreenshot,
            screenshotCompression: screenshotCompression,
            filterVisibleNodes: filterVisibleNodes
        )
    }

    static func captureSnapshot(
        metadata: ComputerUseSnapshotMetadata,
        includeScreenshot: Bool,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault,
        filterVisibleNodes: Bool = false
    ) throws -> RuntimeAppSnapshot {
        guard AXIsProcessTrusted() else {
            throw ComputerUseError.accessibilityPermissionDenied
        }

        guard let app = resolveRunningApp(metadata: metadata) else {
            throw ComputerUseError.staleState(appName: metadata.appName)
        }

        return try captureSnapshot(
            app: app,
            selection: WindowSelection(titleSubstring: metadata.windowTitle),
            includeScreenshot: includeScreenshot,
            screenshotCompression: screenshotCompression,
            preferredWindowID: metadata.windowID,
            preferredWindowFrame: metadata.windowFrame.cgRect,
            filterVisibleNodes: filterVisibleNodes
        )
    }

    static func validateSnapshot(_ metadata: ComputerUseSnapshotMetadata) throws -> RuntimeAppSnapshot {
        do {
            return try captureSnapshot(metadata: metadata, includeScreenshot: false)
        } catch {
            throw ComputerUseError.staleState(appName: metadata.appName)
        }
    }

    static func resolveCachedElement(
        cachedIndex: Int,
        metadata: ComputerUseSnapshotMetadata,
        fresh: RuntimeAppSnapshot
    ) throws -> RuntimeAXNode {
        guard let freshIndex = resolveFreshElementIndex(
            cachedIndex: cachedIndex,
            cached: metadata.nodeSignatures,
            fresh: fresh.nodes
        ) else {
            throw ComputerUseError.staleState(appName: metadata.appName)
        }
        return try fresh.node(index: freshIndex)
    }

    static func persistAndFormat(snapshot: RuntimeAppSnapshot) throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.save(snapshot: snapshot)
        return formattedState(snapshot: snapshot, metadata: metadata)
    }

    static func persistAndBuildState(snapshot: RuntimeAppSnapshot) throws -> ComputerUseState {
        let metadata = try ComputerUseSnapshotStore.save(snapshot: snapshot)
        return structuredState(snapshot: snapshot, metadata: metadata)
    }

    static func structuredState(
        snapshot: RuntimeAppSnapshot,
        metadata: ComputerUseSnapshotMetadata
    ) -> ComputerUseState {
        let parents = parentIndicesFromDepths(snapshot.nodes.map(\.depth))
        let nodes = snapshot.nodes.enumerated().map { i, node in
            ComputerUseNode(
                index: node.index,
                parentIndex: parents[i],
                depth: node.depth,
                role: node.role,
                subrole: node.subrole,
                title: node.title,
                description: node.description,
                value: stringValueOrNil(node.value),
                help: node.help,
                identifier: node.identifier,
                url: node.url?.absoluteString,
                enabled: node.enabled,
                selected: node.selected,
                expanded: node.expanded,
                focused: node.focused,
                frame: node.frame.map(CGRectCodable.init),
                actions: node.actions,
                isValueSettable: node.isValueSettable,
                valueTypeDescription: node.valueTypeDescription
            )
        }
        return ComputerUseState(
            metadata: metadata,
            focusedElementIndex: snapshot.focusedElementIndex,
            selectedText: snapshot.selectedText,
            nodes: nodes
        )
    }

    static func formattedState(
        snapshot: RuntimeAppSnapshot,
        metadata: ComputerUseSnapshotMetadata
    ) -> ComputerUseCommandOutput {
        let stateDump = ComputerUseStateFormatter.format(snapshot: snapshot)
        var text = """
        Computer Use state (Snapshot: \(metadata.id))
        <app_state>
        \(stateDump)
        </app_state>
        """

        if let screenshotPath = metadata.screenshotPath {
            text += "\nScreenshot: \(screenshotPath)"
        }

        if let screenshotSize = metadata.screenshotSize {
            text += "\nScreenshotSize: \(Int(screenshotSize.width))x\(Int(screenshotSize.height))"
        }

        return ComputerUseCommandOutput(text: text, metadata: metadata)
    }

    private static let coordinateFrameTolerance: CGFloat = 8

    static func ensureStableFrameForCoordinateAction(
        metadata: ComputerUseSnapshotMetadata,
        fresh: RuntimeAppSnapshot
    ) throws {
        guard nearlyEqualRects(
            fresh.windowFrame,
            metadata.windowFrame.cgRect,
            tolerance: coordinateFrameTolerance
        ) else {
            throw ComputerUseError.staleState(appName: metadata.appName)
        }
    }

    static func captureSettledSnapshot(
        afterActionOn snapshot: RuntimeAppSnapshot,
        includeScreenshot: Bool,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault,
        filterVisibleNodes: Bool = false
    ) throws -> RuntimeAppSnapshot {
        guard AXIsProcessTrusted() else {
            throw ComputerUseError.accessibilityPermissionDenied
        }

        let deadline = ProcessInfo.processInfo.systemUptime + ComputerUseActionSettleTiming.timeout
        let requiredStablePasses = ComputerUseActionSettleTiming.requiredStablePasses
        var lastFingerprint: String?
        var stablePasses = 0
        var latestSnapshot: RuntimeAppSnapshot?

        while true {
            let candidate = try captureSnapshot(
                app: snapshot.app,
                selection: WindowSelection(titleSubstring: snapshot.windowTitle),
                includeScreenshot: false,
                screenshotCompression: screenshotCompression,
                preferredWindowID: snapshot.windowID,
                filterVisibleNodes: filterVisibleNodes
            )
            latestSnapshot = candidate

            if candidate.fingerprint == lastFingerprint {
                stablePasses += 1
            } else {
                lastFingerprint = candidate.fingerprint
                stablePasses = 1
            }

            if stablePasses >= requiredStablePasses {
                break
            }

            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 {
                break
            }

            RunLoop.current.run(until: Date(timeIntervalSinceNow: min(ComputerUseActionSettleTiming.pollInterval, remaining)))
        }

        guard let latestSnapshot else {
            throw ComputerUseError.windowNotFound(
                app: snapshot.app.localizedName ?? snapshot.app.bundleIdentifier ?? "Unknown",
                title: snapshot.windowTitle
            )
        }

        guard includeScreenshot else {
            return latestSnapshot
        }

        return try captureSnapshot(
            app: latestSnapshot.app,
            selection: WindowSelection(titleSubstring: latestSnapshot.windowTitle),
            includeScreenshot: true,
            screenshotCompression: screenshotCompression,
            preferredWindowID: latestSnapshot.windowID,
            filterVisibleNodes: filterVisibleNodes
        )
    }

    private static func captureSnapshot(
        app: NSRunningApplication,
        selection: WindowSelection,
        includeScreenshot: Bool,
        screenshotCompression: ComputerUseScreenshotCompression,
        preferredWindowID: Int? = nil,
        preferredWindowFrame: CGRect? = nil,
        filterVisibleNodes: Bool = false
    ) throws -> RuntimeAppSnapshot {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        ChromiumAccessibilityActivation.shared.activateIfNeeded(
            pid: app.processIdentifier,
            root: appElement
        )
        let windowMatch = try resolveWindow(
            in: appElement,
            app: app,
            titleSubstring: selection.titleSubstring,
            preferredWindowID: preferredWindowID,
            preferredWindowFrame: preferredWindowFrame
        )

        let focusedElement = cuAttribute(
            appElement,
            name: kAXFocusedUIElementAttribute as String
        ) as AXUIElement?

        if let popupMenu = popupMenuCandidate(in: appElement) ?? activeMenuBarItemCandidate(in: appElement) {
            let nodes = flattenTree(
                from: popupMenu.element,
                focusedElement: focusedElement,
                visibleFrame: popupMenu.frame,
                filterVisibleNodes: filterVisibleNodes
            )
            let focusedIndex = focusedElement.flatMap { focused in
                nodes.first(where: { CFEqual($0.element, focused) })?.index
            }
            let selectedText = focusedElement.flatMap {
                cuAttribute($0, name: kAXSelectedTextAttribute as String) as String?
            }
            let fingerprint = fingerprint(
                app: app,
                windowID: windowMatch.cgWindow.windowID,
                windowTitle: windowMatch.title,
                windowFrame: windowMatch.frame,
                nodes: nodes,
                focusedElementIndex: focusedIndex,
                selectedText: selectedText
            )

            return RuntimeAppSnapshot(
                app: app,
                appElement: appElement,
                windowElement: popupMenu.element,
                windowID: windowMatch.cgWindow.windowID,
                windowTitle: windowMatch.title,
                windowFrame: windowMatch.frame,
                nodes: nodes,
                focusedElementIndex: focusedIndex,
                selectedText: selectedText,
                screenshotURL: nil,
                screenshotSize: nil,
                fingerprint: fingerprint
            )
        }

        var nodes = flattenTree(
            from: windowMatch.element,
            focusedElement: focusedElement,
            visibleFrame: windowMatch.frame,
            filterVisibleNodes: filterVisibleNodes
        )
        if let menuBar = cuAttribute(appElement, name: kAXMenuBarAttribute as String) as AXUIElement? {
            nodes.append(contentsOf: reindexedNodes(
                flattenTree(
                    from: menuBar,
                    focusedElement: focusedElement,
                    visibleFrame: cuFrame(menuBar) ?? windowMatch.frame,
                    filterVisibleNodes: filterVisibleNodes,
                    maxDepth: 1
                ),
                startingAt: nodes.count
            ))
        }

        let focusedIndex = focusedElement.flatMap { focused in
            nodes.first(where: { CFEqual($0.element, focused) })?.index
        }

        let selectedText = focusedElement.flatMap {
            cuAttribute($0, name: kAXSelectedTextAttribute as String) as String?
        }

        let screenshotCapture = includeScreenshot
            ? BackgroundWindowCapture.captureWindowScreenshot(
                windowID: windowMatch.cgWindow.windowID,
                compression: screenshotCompression
            )
            : nil

        let fingerprint = fingerprint(
            app: app,
            windowID: windowMatch.cgWindow.windowID,
            windowTitle: windowMatch.title,
            windowFrame: windowMatch.frame,
            nodes: nodes,
            focusedElementIndex: focusedIndex,
            selectedText: selectedText
        )

        return RuntimeAppSnapshot(
            app: app,
            appElement: appElement,
            windowElement: windowMatch.element,
            windowID: windowMatch.cgWindow.windowID,
            windowTitle: windowMatch.title,
            windowFrame: windowMatch.frame,
            nodes: nodes,
            focusedElementIndex: focusedIndex,
            selectedText: selectedText,
            screenshotURL: screenshotCapture?.url,
            screenshotSize: screenshotCapture?.size,
            fingerprint: fingerprint
        )
    }

    private static func resolveRunningApp(
        metadata: ComputerUseSnapshotMetadata
    ) -> NSRunningApplication? {
        if metadata.bundleID.isEmpty == false {
            if let match = NSRunningApplication.runningApplications(
                withBundleIdentifier: metadata.bundleID
            ).first(where: { $0.processIdentifier == metadata.pid }) {
                return match
            }
        }
        return NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier == metadata.pid
        })
    }

    private static func resolveRunningApplication(matching identifier: String) throws -> NSRunningApplication {
        if let app = resolveRunningApplicationIfAvailable(matching: identifier) {
            return app
        }

        throw ComputerUseError.appNotRunning(identifier)
    }

    private static func resolveWindow(
        in appElement: AXUIElement,
        app: NSRunningApplication,
        titleSubstring: String?,
        preferredWindowID: Int?,
        preferredWindowFrame: CGRect? = nil
    ) throws -> (element: AXUIElement, title: String, frame: CGRect, cgWindow: CUWindowSnapshot) {
        let candidates = windowCandidates(
            in: appElement,
            app: app,
            preferredWindowID: preferredWindowID
        )

        if let preferredWindowID,
           let exact = candidates.first(where: { $0.cgWindow.windowID == preferredWindowID })
        {
            return resolvedWindow(exact)
        }

        if let preferredWindowFrame,
           let best = bestCandidateByFrame(candidates, hint: preferredWindowFrame)
        {
            return resolvedWindow(best)
        }

        let filtered: [WindowCandidate] = if let titleSubstring, titleSubstring.isEmpty == false {
            candidates.filter { candidate in
                candidate.title.localizedCaseInsensitiveContains(titleSubstring)
            }
        } else {
            candidates
        }

        if let main = filtered.first(where: { $0.isMain }) {
            return resolvedWindow(main)
        }

        if let focused = filtered.first(where: { $0.isFocused }) {
            return resolvedWindow(focused)
        }

        if let first = filtered.first {
            return resolvedWindow(first)
        }

        throw ComputerUseError.windowNotFound(
            app: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
            title: titleSubstring
        )
    }

    private static func windowCandidates(
        in appElement: AXUIElement,
        app: NSRunningApplication,
        preferredWindowID: Int? = nil
    ) -> [WindowCandidate] {
        let windows = mergeAXWindowCandidates(
            listedWindows: cuAttribute(appElement, name: kAXWindowsAttribute as String) as [AXUIElement]? ?? [],
            focusedWindow: cuAttribute(appElement, name: kAXFocusedWindowAttribute as String) as AXUIElement?,
            mainWindow: cuAttribute(appElement, name: kAXMainWindowAttribute as String) as AXUIElement?
        )
        let cgWindows = cuCGWindows(for: app.processIdentifier)

        var candidates: [WindowCandidate] = []

        for window in windows {
            guard let frame = cuFrame(window) else {
                continue
            }

            let title = cuTitle(window)
            let matchingWindow = matchCGWindow(
                axWindow: window,
                candidates: cgWindows,
                preferredWindowID: preferredWindowID,
                title: title,
                frame: frame
            )

            guard let cgWindow = matchingWindow else {
                continue
            }

            candidates.append(WindowCandidate(
                element: window,
                title: title,
                frame: frame,
                cgWindow: cgWindow,
                isMain: cuBoolAttribute(window, name: kAXMainAttribute as String) == true,
                isFocused: cuBoolAttribute(window, name: kAXFocusedAttribute as String) == true
            ))
        }

        return candidates
    }

    private static func resolvedWindow(
        _ candidate: WindowCandidate
    ) -> (element: AXUIElement, title: String, frame: CGRect, cgWindow: CUWindowSnapshot) {
        (candidate.element, candidate.title, candidate.frame, candidate.cgWindow)
    }

    private static func bestCandidateByFrame(
        _ candidates: [WindowCandidate],
        hint: CGRect
    ) -> WindowCandidate? {
        func score(_ frame: CGRect) -> CGFloat {
            let dx = frame.midX - hint.midX
            let dy = frame.midY - hint.midY
            let dw = frame.width - hint.width
            let dh = frame.height - hint.height
            return sqrt(dx * dx + dy * dy) + abs(dw) + abs(dh)
        }
        return candidates
            .map { ($0, score($0.frame)) }
            .min(by: { $0.1 < $1.1 })?.0
    }

    private static func matchCGWindow(
        axWindow: AXUIElement,
        candidates: [CUWindowSnapshot],
        preferredWindowID: Int?,
        title: String,
        frame: CGRect
    ) -> CUWindowSnapshot? {
        if let exactWindowID = AXWindowIDResolver.cgWindowID(forAXWindow: axWindow),
           let exact = candidates.first(where: { $0.windowID == Int(exactWindowID) })
        {
            return exact
        }

        if let preferredWindowID,
           let preferred = candidates.first(where: { $0.windowID == preferredWindowID }),
           nearlyEqualRects(preferred.bounds, frame, tolerance: 4)
        {
            return preferred
        }

        if title.isEmpty == false {
            let sameTitle = candidates.filter {
                $0.name.localizedCaseInsensitiveContains(title)
            }
            if let frameMatch = sameTitle.first(where: {
                nearlyEqualRects($0.bounds, frame)
            }) {
                return frameMatch
            }
            if let firstTitle = sameTitle.first {
                return firstTitle
            }
        }

        return candidates.first(where: { nearlyEqualRects($0.bounds, frame) }) ??
            candidates.first(where: { $0.layer == 0 })
    }

    private static func popupMenuCandidate(in appElement: AXUIElement) -> PopupMenuCandidate? {
        let roots = cuElements(from: cuRawAttribute(appElement, name: kAXFocusedWindowAttribute as String)) +
            cuElements(from: cuRawAttribute(appElement, name: kAXWindowsAttribute as String)) +
            cuElements(from: cuRawAttribute(appElement, name: kAXFocusedUIElementAttribute as String))
        var stack = roots
        var visited = Set<CFHashCode>()
        var best: PopupMenuCandidate?

        while let element = stack.popLast() {
            let identifier = CFHash(element)
            if visited.contains(identifier) {
                continue
            }
            visited.insert(identifier)

            let role = cuAttribute(element, name: kAXRoleAttribute as String) as String? ?? ""
            if role == (kAXMenuRole as String),
               let frame = cuFrame(element),
               popupMenuHasItems(element),
               isTransientPopupMenu(element) {
                let candidate = PopupMenuCandidate(element: element, frame: frame)
                if best == nil || menuItemCount(in: element) > menuItemCount(in: best!.element) {
                    best = candidate
                }
            }

            stack.append(contentsOf: cuChildElements(element))
        }

        return best
    }

    private static func isTransientPopupMenu(_ menu: AXUIElement) -> Bool {
        var current: AXUIElement? = menu
        var visited = Set<CFHashCode>()

        while let element = current {
            let identifier = CFHash(element)
            if visited.contains(identifier) {
                return false
            }
            visited.insert(identifier)

            let role = cuAttribute(element, name: kAXRoleAttribute as String) as String? ?? ""
            if role == (kAXMenuBarItemRole as String) ||
                role == (kAXMenuItemRole as String) ||
                role == (kAXPopUpButtonRole as String) ||
                role == "AXMenuButton" {
                return true
            }

            if role == "AXWebArea" ||
                role == (kAXWindowRole as String) {
                return false
            }

            current = cuAttribute(element, name: kAXParentAttribute as String) as AXUIElement?
        }

        return false
    }

    private static func activeMenuBarItemCandidate(in appElement: AXUIElement) -> PopupMenuCandidate? {
        guard let menuBar = cuAttribute(appElement, name: kAXMenuBarAttribute as String) as AXUIElement? else {
            return nil
        }

        let items = cuChildElements(menuBar).filter { element in
            let role = cuAttribute(element, name: kAXRoleAttribute as String) as String? ?? ""
            return role == (kAXMenuBarItemRole as String) && cuTitle(element) != "Apple"
        }

        for item in items where cuBoolAttribute(item, name: kAXSelectedAttribute as String) == true {
            let menus = cuChildElements(item).filter { child in
                let role = cuAttribute(child, name: kAXRoleAttribute as String) as String? ?? ""
                return role == (kAXMenuRole as String) && popupMenuHasItems(child)
            }
            guard menus.isEmpty == false else {
                continue
            }
            let frame = cuFrame(item) ?? menus.compactMap(cuFrame).first
            if let frame {
                return PopupMenuCandidate(element: item, frame: frame)
            }
        }

        return nil
    }

    private static func reindexedNodes(
        _ nodes: [RuntimeAXNode],
        startingAt offset: Int
    ) -> [RuntimeAXNode] {
        nodes.map { node in
            RuntimeAXNode(
                index: node.index + offset,
                depth: node.depth,
                element: node.element,
                role: node.role,
                subrole: node.subrole,
                title: node.title,
                description: node.description,
                value: node.value,
                help: node.help,
                identifier: node.identifier,
                url: node.url,
                enabled: node.enabled,
                selected: node.selected,
                expanded: node.expanded,
                focused: node.focused,
                frame: node.frame,
                actions: node.actions,
                isValueSettable: node.isValueSettable,
                valueTypeDescription: node.valueTypeDescription
            )
        }
    }

    private static func popupMenuHasItems(_ menu: AXUIElement) -> Bool {
        menuItemCount(in: menu) > 0
    }

    private static func menuItemCount(in menu: AXUIElement) -> Int {
        cuMenuChildren(menu).filter { child in
            let role = cuAttribute(child, name: kAXRoleAttribute as String) as String? ?? ""
            return role == (kAXMenuItemRole as String) || !cuTitle(child).isEmpty || !cuDescription(child).isEmpty
        }.count
    }

    private static func flattenTree(
        from root: AXUIElement,
        focusedElement: AXUIElement?,
        visibleFrame: CGRect,
        filterVisibleNodes: Bool,
        maxDepth: Int = 64
    ) -> [RuntimeAXNode] {
        struct PendingNode {
            let element: AXUIElement
            let role: String
            let subrole: String
            let title: String
            let description: String
            let value: Any?
            let help: String
            let identifier: String
            let url: URL?
            let enabled: Bool?
            let selected: Bool?
            let expanded: Bool?
            let focused: Bool?
            let frame: CGRect?
            let actions: [String]
            let isValueSettable: Bool
            let valueTypeDescription: String?
            let children: [PendingNode]
        }

        var visited = Set<CFHashCode>()

        func build(_ element: AXUIElement, depth: Int, visibleClip: CGRect) -> PendingNode? {
            guard depth <= maxDepth else {
                return nil
            }

            let identifier = CFHash(element)
            if visited.contains(identifier) {
                return nil
            }
            visited.insert(identifier)

            let role = cuAttribute(element, name: kAXRoleAttribute as String) as String? ?? "AXUnknown"
            let subrole = cuAttribute(element, name: kAXSubroleAttribute as String) as String? ?? ""
            let title = cuTitle(element)
            let description = cuDescription(element)
            let frame = cuFrame(element)
            let focused = focusedElement.map { CFEqual($0, element) }
            let selected = cuBoolAttribute(element, name: kAXSelectedAttribute as String)
            let hidden = cuBoolAttribute(element, name: "AXHidden") == true
            if hidden, depth > 0, focused != true, selected != true {
                return nil
            }

            let rawChildren = cuChildElementsForWalk(element, role: role)
            let childVisibleClip = filterVisibleNodes
                ? cuDescendantVisibleClip(role: role, frame: frame, inheritedClip: visibleClip)
                : visibleClip
            let children = rawChildren.compactMap {
                build($0, depth: depth + 1, visibleClip: childVisibleClip)
            }

            let visible = if roleCanContainVisibleDescendants(role) {
                cuFrameIsVisible(frame, in: visibleClip) || children.isEmpty == false
            } else {
                cuFrameIsMeaningfullyVisible(frame, in: visibleClip)
            }
            let selfDescribingStructuralNode = roleCanContainVisibleDescendants(role) &&
                (!title.isEmpty || !description.isEmpty)
            let visibleFilteringDisabled = ProcessInfo.processInfo.environment["KWWK_COMPUTER_USE_CORE_DISABLE_VISIBLE_FILTER"] == "1"
            if filterVisibleNodes,
               !visibleFilteringDisabled,
               depth > 0,
               !visible,
               !selfDescribingStructuralNode,
               focused != true,
               selected != true
            {
                return nil
            }

            let value = cuRawAttribute(element, name: kAXValueAttribute as String)
            return PendingNode(
                element: element,
                role: role,
                subrole: subrole,
                title: title,
                description: description,
                value: value,
                help: cuAttribute(element, name: kAXHelpAttribute as String) as String? ?? "",
                identifier: cuAttribute(element, name: kAXIdentifierAttribute as String) as String? ?? "",
                url: cuAttribute(element, name: kAXURLAttribute as String) as URL?,
                enabled: cuBoolAttribute(element, name: kAXEnabledAttribute as String),
                selected: selected,
                expanded: cuBoolAttribute(element, name: kAXExpandedAttribute as String),
                focused: focused,
                frame: frame,
                actions: cuActions(element),
                isValueSettable: cuIsAttributeSettable(element, name: kAXValueAttribute as String),
                valueTypeDescription: describeValueType(value),
                children: children
            )
        }

        guard let rootNode = build(root, depth: 0, visibleClip: visibleFrame) else {
            return []
        }

        var nodes: [RuntimeAXNode] = []
        func emit(_ pending: PendingNode, depth: Int) {
            let index = nodes.count
            nodes.append(RuntimeAXNode(
                index: index,
                depth: depth,
                element: pending.element,
                role: pending.role,
                subrole: pending.subrole,
                title: pending.title,
                description: pending.description,
                value: pending.value,
                help: pending.help,
                identifier: pending.identifier,
                url: pending.url,
                enabled: pending.enabled,
                selected: pending.selected,
                expanded: pending.expanded,
                focused: pending.focused,
                frame: pending.frame,
                actions: pending.actions,
                isValueSettable: pending.isValueSettable,
                valueTypeDescription: pending.valueTypeDescription
            ))
            for child in pending.children {
                emit(child, depth: depth + 1)
            }
        }
        emit(rootNode, depth: 0)

        return nodes
    }

    private static func fingerprint(
        app: NSRunningApplication,
        windowID: Int,
        windowTitle: String,
        windowFrame: CGRect,
        nodes: [RuntimeAXNode],
        focusedElementIndex: Int?,
        selectedText: String?
    ) -> String {
        let parts = nodes.map { node -> String in
            let components: [String] = [
                "\(node.index)",
                node.role,
                node.subrole,
                node.title,
                stableFingerprintValue(for: node),
                node.help,
                node.identifier,
                stableFingerprintURL(for: node),
                node.enabled.map(String.init) ?? "",
                node.selected.map(String.init) ?? "",
                node.expanded.map(String.init) ?? "",
                node.frame.map(stableRectString) ?? "",
                node.actions.joined(separator: ","),
            ]
            return components.joined(separator: "|")
        }

        let payload = """
        \(app.bundleIdentifier ?? "")
        |\(app.processIdentifier)
        |\(windowID)
        |\(windowTitle)
        |\(stableRectString(windowFrame))
        |focus=\(focusedElementIndex.map(String.init) ?? "")
        |selected=\(selectedText ?? "")
        |\(parts.joined(separator: "\n"))
        """

        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private enum ComputerUseActionSettleTiming {
    static var timeout: TimeInterval {
        milliseconds(from: "KWWK_COMPUTER_USE_CORE_ACTION_SETTLE_TIMEOUT_MS", fallback: 1600)
    }

    static var pollInterval: TimeInterval {
        milliseconds(from: "KWWK_COMPUTER_USE_CORE_ACTION_SETTLE_POLL_MS", fallback: 120)
    }

    static var requiredStablePasses: Int {
        guard
            let raw = ProcessInfo.processInfo.environment["KWWK_COMPUTER_USE_CORE_ACTION_SETTLE_STABLE_PASSES"],
            let value = Int(raw)
        else {
            return 3
        }

        return max(1, value)
    }

    private static func milliseconds(from key: String, fallback: Double) -> TimeInterval {
        guard
            let raw = ProcessInfo.processInfo.environment[key],
            let value = Double(raw),
            value >= 0
        else {
            return fallback / 1000
        }

        return value / 1000
    }
}

func displayName(forAction action: String) -> String {
    let trimmed = action.hasPrefix("AX") ? String(action.dropFirst(2)) : action
    let noByPage = trimmed.replacingOccurrences(of: "ByPage", with: "")
    return splitCamelCase(noByPage).joined(separator: " ")
}

func describeRole(_ role: String) -> String {
    if role == kAXWindowRole as String {
        return "standard window"
    }
    if role == kAXStaticTextRole as String {
        return "text"
    }
    return splitCamelCase(role.hasPrefix("AX") ? String(role.dropFirst(2)) : role)
        .joined(separator: " ")
        .lowercased()
}

func splitCamelCase(_ string: String) -> [String] {
    guard string.isEmpty == false else {
        return []
    }

    var words: [String] = []
    var current = ""

    for scalar in string.unicodeScalars {
        let character = Character(scalar)
        if current.isEmpty == false,
           CharacterSet.uppercaseLetters.contains(scalar)
        {
            words.append(current)
            current = String(character)
        } else {
            current.append(character)
        }
    }

    if current.isEmpty == false {
        words.append(current)
    }

    return words
}

func stringifyValue(_ value: Any?) -> String {
    guard let value else {
        return ""
    }

    if let string = value as? String {
        return string
    }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "1" : "0"
        }
        return number.stringValue
    }
    if let url = value as? URL {
        return url.absoluteString
    }
    if let axValue = cuAXValue(from: value) {
        switch AXValueGetType(axValue) {
        case .cgPoint:
            var point = CGPoint.zero
            guard AXValueGetValue(axValue, .cgPoint, &point) else {
                return ""
            }
            return NSStringFromPoint(point)
        case .cgSize:
            var size = CGSize.zero
            guard AXValueGetValue(axValue, .cgSize, &size) else {
                return ""
            }
            return NSStringFromSize(size)
        case .cfRange:
            var range = CFRange()
            guard AXValueGetValue(axValue, .cfRange, &range) else {
                return ""
            }
            return "{\(range.location), \(range.length)}"
        default:
            return ""
        }
    }
    return String(describing: value)
}

func stringValueOrNil(_ value: Any?) -> String? {
    let valueString = stringifyValue(value)
    return valueString.isEmpty ? nil : valueString
}

func describeValueType(_ value: Any?) -> String? {
    guard let value else {
        return nil
    }
    if value is String {
        return "string"
    }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return "bool"
        }
        if CFNumberIsFloatType(number) {
            return "float"
        }
        return "int"
    }
    return nil
}

func windowLocalPoint(
    fromScreenshotPixel point: CGPoint,
    screenshotSize: CGSize,
    windowFrame: CGRect
) -> CGPoint {
    windowLocalPoint(
        fromScreenshotPixel: Point<ScreenshotPixelSpace>(point),
        screenshotSize: screenshotSize,
        windowFrame: windowFrame
    ).cgPoint
}

func nearlyEqualRects(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 2) -> Bool {
    abs(lhs.origin.x - rhs.origin.x) <= tolerance &&
        abs(lhs.origin.y - rhs.origin.y) <= tolerance &&
        abs(lhs.width - rhs.width) <= tolerance &&
        abs(lhs.height - rhs.height) <= tolerance
}
