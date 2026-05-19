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
    let collectionSummary: String?
}

enum RuntimeSurfaceKind: String {
    case window
    case status
    case menu
}

struct RuntimeAppSnapshot {
    let app: NSRunningApplication
    let appElement: AXUIElement
    let windowElement: AXUIElement
    let surfaceKind: RuntimeSurfaceKind
    let windowID: Int
    let windowTitle: String
    let windowFrame: CGRect
    let nodes: [RuntimeAXNode]
    let focusedElementIndex: Int?
    let selectedText: String?
    let screenshotURL: URL?
    let screenshotSize: CGSize?
    let fingerprint: String

    init(
        app: NSRunningApplication,
        appElement: AXUIElement,
        windowElement: AXUIElement,
        surfaceKind: RuntimeSurfaceKind = .window,
        windowID: Int,
        windowTitle: String,
        windowFrame: CGRect,
        nodes: [RuntimeAXNode],
        focusedElementIndex: Int?,
        selectedText: String?,
        screenshotURL: URL?,
        screenshotSize: CGSize?,
        fingerprint: String
    ) {
        self.app = app
        self.appElement = appElement
        self.windowElement = windowElement
        self.surfaceKind = surfaceKind
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.windowFrame = windowFrame
        self.nodes = nodes
        self.focusedElementIndex = focusedElementIndex
        self.selectedText = selectedText
        self.screenshotURL = screenshotURL
        self.screenshotSize = screenshotSize
        self.fingerprint = fingerprint
    }

    func node(index: Int) throws -> RuntimeAXNode {
        guard let node = nodes.first(where: { $0.index == index }) else {
            throw ComputerUseError.elementNotFound(index)
        }
        return node
    }
}

struct WindowSelection {
    var titleSubstring: String? = nil
    var windowID: Int? = nil
}

enum ComputerUseCore {
    private typealias ResolvedWindowMatch = (
        element: AXUIElement,
        title: String,
        frame: CGRect,
        cgWindow: CUWindowSnapshot
    )

    private struct SnapshotSurfaceScan {
        let appElement: AXUIElement
        let focusedElement: AXUIElement?
        let selectedText: String?
        let statusMenuExtras: [AXUIElement]
        let transientMenuWindowFrame: CGRect?
        let windowMatch: ResolvedWindowMatch?
        let windowResolutionError: ComputerUseError?
    }

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

    static func captureSnapshot(
        appIdentifier: String,
        selection: WindowSelection = .init(),
        includeScreenshot: Bool,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault,
        filterVisibleNodes: Bool = true
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
        filterVisibleNodes: Bool = true
    ) throws -> RuntimeAppSnapshot {
        guard AXIsProcessTrusted() else {
            throw ComputerUseError.accessibilityPermissionDenied
        }

        guard let app = resolveRunningApp(metadata: metadata) else {
            throw ComputerUseError.staleState(appName: metadata.appName)
        }

        let selectedWindowID = metadata.windowID > 0 ? metadata.windowID : nil
        let selectedTitle = metadata.windowID > 0 ? metadata.windowTitle : nil

        return try captureSnapshot(
            app: app,
            selection: WindowSelection(titleSubstring: selectedTitle, windowID: selectedWindowID),
            includeScreenshot: includeScreenshot,
            screenshotCompression: screenshotCompression,
            preferredWindowID: selectedWindowID,
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
            surface: snapshot.surfaceKind.rawValue,
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
        let otherWindows = otherWindowsText(for: snapshot)
        let surfaceHint = surfaceHintText(for: snapshot)
        var text = """
        Computer Use state
        <app_state surface="\(snapshot.surfaceKind.rawValue)">
        \(surfaceHint)
        \(stateDump)
        \(otherWindows)
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

    private static func surfaceHintText(for snapshot: RuntimeAppSnapshot) -> String {
        switch snapshot.surfaceKind {
        case .window:
            return "Surface: window. The state below is the app window plus the app's top-level menu bar items."
        case .status:
            return "Surface: status. No app window is available; the state below contains the app's status item. Click it by element_index to open its status menu."
        case .menu:
            return "Surface: menu. An app menu is currently open. Click a menu item by element_index, or use press-key {\"key\":\"escape\"} to close the menu and return to the window."
        }
    }

    private static func otherWindowsText(for snapshot: RuntimeAppSnapshot) -> String {
        let appIdentifier = snapshot.app.bundleIdentifier
            ?? snapshot.app.localizedName
            ?? ""
        guard appIdentifier.isEmpty == false,
              let windows = try? listWindows(appIdentifier: appIdentifier),
              windows.count > 1
        else {
            return ""
        }

        var lines = ["Other windows:"]
        for window in windows {
            var flags: [String] = []
            if window.windowID == snapshot.windowID {
                flags.append("current")
            }
            if window.isMain {
                flags.append("main")
            }
            let flagText = flags.isEmpty ? "" : " [\(flags.joined(separator: ","))]"
            lines.append("- window_id=\(window.windowID) title=\"\(window.title)\"\(flagText)")
        }
        lines.append("Use window_id or window_title to inspect a different window.")
        return lines.joined(separator: "\n")
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
        filterVisibleNodes: Bool = true
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
            let selectedWindowID = snapshot.windowID > 0 ? snapshot.windowID : nil
            let selectedTitle = snapshot.windowID > 0 ? snapshot.windowTitle : nil
            let candidate = try captureSnapshot(
                app: snapshot.app,
                selection: WindowSelection(titleSubstring: selectedTitle),
                includeScreenshot: false,
                screenshotCompression: screenshotCompression,
                preferredWindowID: selectedWindowID,
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
            selection: WindowSelection(titleSubstring: latestSnapshot.windowID > 0 ? latestSnapshot.windowTitle : nil),
            includeScreenshot: true,
            screenshotCompression: screenshotCompression,
            preferredWindowID: latestSnapshot.windowID > 0 ? latestSnapshot.windowID : nil,
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
        filterVisibleNodes: Bool = true
    ) throws -> RuntimeAppSnapshot {
        try runAXRead {
            Result {
                try captureSnapshotOnAXReadQueue(
                    app: app,
                    selection: selection,
                    includeScreenshot: includeScreenshot,
                    screenshotCompression: screenshotCompression,
                    preferredWindowID: preferredWindowID,
                    preferredWindowFrame: preferredWindowFrame,
                    filterVisibleNodes: filterVisibleNodes
                )
            }
        }.get()
    }

    private static func captureSnapshotOnAXReadQueue(
        app: NSRunningApplication,
        selection: WindowSelection,
        includeScreenshot: Bool,
        screenshotCompression: ComputerUseScreenshotCompression,
        preferredWindowID: Int?,
        preferredWindowFrame: CGRect?,
        filterVisibleNodes: Bool
    ) throws -> RuntimeAppSnapshot {
        let scan = try scanSnapshotSurface(
            app: app,
            selection: selection,
            preferredWindowID: preferredWindowID,
            preferredWindowFrame: preferredWindowFrame
        )
        guard let windowMatch = scan.windowMatch else {
            guard let error = scan.windowResolutionError,
                  case .windowNotFound = error,
                  selection.titleSubstring == nil,
                  selection.windowID == nil,
                  preferredWindowID == nil,
                  let statusSnapshot = statusSurfaceSnapshot(
                    app: app,
                    appElement: scan.appElement,
                    focusedElement: scan.focusedElement,
                    selectedText: scan.selectedText,
                    statusMenuExtras: scan.statusMenuExtras,
                    filterVisibleNodes: filterVisibleNodes
                  )
            else {
                throw scan.windowResolutionError ?? ComputerUseError.windowNotFound(
                    app: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
                    title: selection.titleSubstring
                )
            }
            return statusSnapshot
        }

        if let menuSnapshot = menuSurfaceSnapshot(
            app: app,
            appElement: scan.appElement,
            windowMatch: windowMatch,
            focusedElement: scan.focusedElement,
            selectedText: scan.selectedText,
            statusMenuExtras: scan.statusMenuExtras,
            transientMenuWindowFrame: scan.transientMenuWindowFrame,
            filterVisibleNodes: filterVisibleNodes
        ) {
            return menuSnapshot
        }

        var nodes = flattenTree(
            from: windowMatch.element,
            focusedElement: scan.focusedElement,
            visibleFrame: windowMatch.frame,
            filterVisibleNodes: filterVisibleNodes
        )
        nodes.append(contentsOf: reindexedNodes(
            menuBarNodes(
                appElement: scan.appElement,
                focusedElement: scan.focusedElement,
                fallbackFrame: windowMatch.frame,
                filterVisibleNodes: filterVisibleNodes
            ),
            startingAt: nodes.count
        ))
        nodes.append(contentsOf: reindexedNodes(
            statusMenuExtraNodes(
                statusMenuExtras: scan.statusMenuExtras,
                focusedElement: scan.focusedElement,
                fallbackFrame: windowMatch.frame,
                filterVisibleNodes: filterVisibleNodes
            ),
            startingAt: nodes.count
        ))

        let focusedIndex = scan.focusedElement.flatMap { focused in
            nodes.first(where: { CFEqual($0.element, focused) })?.index
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
            selectedText: scan.selectedText
        )

        return RuntimeAppSnapshot(
            app: app,
            appElement: scan.appElement,
            windowElement: windowMatch.element,
            surfaceKind: .window,
            windowID: windowMatch.cgWindow.windowID,
            windowTitle: windowMatch.title,
            windowFrame: windowMatch.frame,
            nodes: nodes,
            focusedElementIndex: focusedIndex,
            selectedText: scan.selectedText,
            screenshotURL: screenshotCapture?.url,
            screenshotSize: screenshotCapture?.size,
            fingerprint: fingerprint
        )
    }

    private static func scanSnapshotSurface(
        app: NSRunningApplication,
        selection: WindowSelection,
        preferredWindowID: Int?,
        preferredWindowFrame: CGRect?
    ) throws -> SnapshotSurfaceScan {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        ChromiumAccessibilityActivation.shared.activateIfNeeded(
            pid: app.processIdentifier,
            root: appElement
        )
        let focusedElement = cuAttribute(
            appElement,
            name: kAXFocusedUIElementAttribute as String
        ) as AXUIElement?
        let selectedText = focusedElement.flatMap {
            cuAttribute($0, name: kAXSelectedTextAttribute as String) as String?
        }
        let statusMenuExtras = statusMenuExtraCandidates(in: appElement)
        let transientMenuWindowFrame = transientMenuWindowFrame(for: app.processIdentifier)

        do {
            let windowMatch = try resolveWindow(
                in: appElement,
                app: app,
                titleSubstring: selection.titleSubstring,
                preferredWindowID: selection.windowID ?? preferredWindowID,
                preferredWindowFrame: preferredWindowFrame,
                requirePreferredWindowID: selection.windowID != nil
            )
            return SnapshotSurfaceScan(
                appElement: appElement,
                focusedElement: focusedElement,
                selectedText: selectedText,
                statusMenuExtras: statusMenuExtras,
                transientMenuWindowFrame: transientMenuWindowFrame,
                windowMatch: windowMatch,
                windowResolutionError: nil
            )
        } catch let error as ComputerUseError {
            return SnapshotSurfaceScan(
                appElement: appElement,
                focusedElement: focusedElement,
                selectedText: selectedText,
                statusMenuExtras: statusMenuExtras,
                transientMenuWindowFrame: transientMenuWindowFrame,
                windowMatch: nil,
                windowResolutionError: error
            )
        }
    }

    static func runAXRead<T>(_ body: @escaping () -> T) -> T {
        body()
    }

    private static func transientMenuWindowFrame(for pid: pid_t) -> CGRect? {
        let popupMenuLevel = CGWindowLevelForKey(.popUpMenuWindow)
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
        else {
            return nil
        }

        for window in windows {
            let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            guard ownerPID == pid, layer == popupMenuLevel else {
                continue
            }
            guard let rawBounds = window[kCGWindowBounds as String] as? [String: CGFloat] else {
                continue
            }
            let frame = CGRect(
                x: rawBounds["X"] ?? 0,
                y: rawBounds["Y"] ?? 0,
                width: rawBounds["Width"] ?? 0,
                height: rawBounds["Height"] ?? 0
            )
            guard frame.width > 0, frame.height > 0 else {
                continue
            }
            return frame
        }

        return nil
    }

    private static func menuSurfaceSnapshot(
        app: NSRunningApplication,
        appElement: AXUIElement,
        windowMatch: ResolvedWindowMatch,
        focusedElement: AXUIElement?,
        selectedText: String?,
        statusMenuExtras: [AXUIElement],
        transientMenuWindowFrame: CGRect?,
        filterVisibleNodes: Bool
    ) -> RuntimeAppSnapshot? {
        runAXRead {
            if let menuWindowFrame = transientMenuWindowFrame {
                let roots = [appElement, windowMatch.element] + cuElements(from: focusedElement)
                if let popupMenu = popupMenuCandidate(
                    near: roots,
                    requireVisibleItems: false,
                    matching: menuWindowFrame
                ) {
                    return menuSurfaceSnapshot(
                        app: app,
                        appElement: appElement,
                        windowMatch: windowMatch,
                        focusedElement: focusedElement,
                        selectedText: selectedText,
                        popupMenu: PopupMenuCandidate(element: popupMenu.element, frame: menuWindowFrame),
                        filterVisibleNodes: false
                    )
                }
            }

            if let popupMenu = activeMenuBarItemCandidate(in: appElement) ??
                activeStatusMenuItemCandidate(in: statusMenuExtras) {
                return menuSurfaceSnapshot(
                    app: app,
                    appElement: appElement,
                    windowMatch: windowMatch,
                    focusedElement: focusedElement,
                    selectedText: selectedText,
                    popupMenu: popupMenu,
                    filterVisibleNodes: filterVisibleNodes
                )
            }
            return nil
        }
    }

    private static func menuSurfaceSnapshot(
        app: NSRunningApplication,
        appElement: AXUIElement,
        windowMatch: ResolvedWindowMatch,
        focusedElement: AXUIElement?,
        selectedText: String?,
        popupMenu: PopupMenuCandidate,
        filterVisibleNodes: Bool
    ) -> RuntimeAppSnapshot? {
            let nodes = flattenTree(
                from: popupMenu.element,
                focusedElement: focusedElement,
                visibleFrame: popupMenu.frame,
                filterVisibleNodes: filterVisibleNodes
            )
            let focusedIndex = focusedElement.flatMap { focused in
                nodes.first(where: { CFEqual($0.element, focused) })?.index
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
                surfaceKind: .menu,
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

    private static func menuBarNodes(
        appElement: AXUIElement,
        focusedElement: AXUIElement?,
        fallbackFrame: CGRect,
        filterVisibleNodes: Bool
    ) -> [RuntimeAXNode] {
        runAXRead {
            guard let menuBar = cuAttribute(appElement, name: kAXMenuBarAttribute as String) as AXUIElement? else {
                return []
            }

            return flattenTree(
                from: menuBar,
                focusedElement: focusedElement,
                visibleFrame: cuFrame(menuBar) ?? fallbackFrame,
                filterVisibleNodes: filterVisibleNodes,
                maxDepth: 1
            )
        }
    }

    private static func statusMenuExtraNodes(
        statusMenuExtras: [AXUIElement],
        focusedElement: AXUIElement?,
        fallbackFrame: CGRect,
        filterVisibleNodes: Bool
    ) -> [RuntimeAXNode] {
        runAXRead {
            var nodes: [RuntimeAXNode] = []
            for statusItem in statusMenuExtras {
                nodes.append(contentsOf: reindexedNodes(
                    flattenTree(
                        from: statusItem,
                        focusedElement: focusedElement,
                        visibleFrame: cuFrame(statusItem) ?? fallbackFrame,
                        filterVisibleNodes: filterVisibleNodes,
                        maxDepth: 0
                    ),
                    startingAt: nodes.count
                ))
            }
            return nodes
        }
    }

    private static func statusSurfaceSnapshot(
        app: NSRunningApplication,
        appElement: AXUIElement,
        focusedElement: AXUIElement?,
        selectedText: String?,
        statusMenuExtras: [AXUIElement],
        filterVisibleNodes: Bool
    ) -> RuntimeAppSnapshot? {
        if let popupMenu = activeStatusMenuItemCandidate(in: statusMenuExtras) {
            return statusSurfaceSnapshot(
                app: app,
                appElement: appElement,
                focusedElement: focusedElement,
                selectedText: selectedText,
                rootElement: popupMenu.element,
                surfaceKind: .menu,
                title: "Status Menu",
                frame: popupMenu.frame,
                filterVisibleNodes: filterVisibleNodes
            )
        }

        let statusItems = statusMenuExtras
        guard let firstStatusItem = statusItems.first else {
            return nil
        }

        let frames = statusItems.compactMap(cuFrame)
        let frame = frames.reduce(CGRect.null) { partial, next in
            partial.isNull ? next : partial.union(next)
        }
        let visibleFrame = frame.isNull ? (cuFrame(firstStatusItem) ?? .zero) : frame

        var nodes: [RuntimeAXNode] = []
        for statusItem in statusItems {
            nodes.append(contentsOf: reindexedNodes(
                flattenTree(
                    from: statusItem,
                    focusedElement: focusedElement,
                    visibleFrame: cuFrame(statusItem) ?? visibleFrame,
                    filterVisibleNodes: filterVisibleNodes,
                    maxDepth: 0
                ),
                startingAt: nodes.count
            ))
        }

        return statusSurfaceSnapshot(
            app: app,
            appElement: appElement,
            focusedElement: focusedElement,
            selectedText: selectedText,
            rootElement: firstStatusItem,
            surfaceKind: .status,
            title: "Status Items",
            frame: visibleFrame,
            nodes: nodes,
            filterVisibleNodes: filterVisibleNodes
        )
    }

    private static func statusSurfaceSnapshot(
        app: NSRunningApplication,
        appElement: AXUIElement,
        focusedElement: AXUIElement?,
        selectedText: String?,
        rootElement: AXUIElement,
        surfaceKind: RuntimeSurfaceKind,
        title: String,
        frame: CGRect,
        nodes providedNodes: [RuntimeAXNode]? = nil,
        filterVisibleNodes: Bool
    ) -> RuntimeAppSnapshot {
        let nodes = providedNodes ?? flattenTree(
            from: rootElement,
            focusedElement: focusedElement,
            visibleFrame: frame,
            filterVisibleNodes: filterVisibleNodes
        )
        let focusedIndex = focusedElement.flatMap { focused in
            nodes.first(where: { CFEqual($0.element, focused) })?.index
        }
        let windowID = statusSurfaceWindowID(app: app, frame: frame)
        let fingerprint = fingerprint(
            app: app,
            windowID: windowID,
            windowTitle: title,
            windowFrame: frame,
            nodes: nodes,
            focusedElementIndex: focusedIndex,
            selectedText: selectedText
        )

        return RuntimeAppSnapshot(
            app: app,
            appElement: appElement,
            windowElement: rootElement,
            surfaceKind: surfaceKind,
            windowID: windowID,
            windowTitle: title,
            windowFrame: frame,
            nodes: nodes,
            focusedElementIndex: focusedIndex,
            selectedText: selectedText,
            screenshotURL: nil,
            screenshotSize: nil,
            fingerprint: fingerprint
        )
    }

    private static func statusSurfaceWindowID(app _: NSRunningApplication, frame _: CGRect) -> Int {
        return 0
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
                valueTypeDescription: node.valueTypeDescription,
                collectionSummary: node.collectionSummary
            )
        }
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
            let collectionSummary: String?
            let children: [PendingNode]
        }

        var visited = Set<CFHashCode>()

        func build(
            _ element: AXUIElement,
            depth: Int,
            visibleClip: CGRect,
            insideWebArea: Bool
        ) -> PendingNode? {
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
            let collectionSummary = cuCollectionSummary(element, role: role)
            let childVisibleClip = filterVisibleNodes
                ? cuDescendantVisibleClip(role: role, frame: frame, inheritedClip: visibleClip)
                : visibleClip
            let childInsideWebArea = insideWebArea || role == "AXWebArea"
            let children = rawChildren.compactMap {
                build(
                    $0,
                    depth: depth + 1,
                    visibleClip: childVisibleClip,
                    insideWebArea: childInsideWebArea
                )
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
                collectionSummary: collectionSummary,
                children: children
            )
        }

        guard let rootNode = build(root, depth: 0, visibleClip: visibleFrame, insideWebArea: false) else {
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
                valueTypeDescription: pending.valueTypeDescription,
                collectionSummary: pending.collectionSummary
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
