import ApplicationServices
import Foundation

public enum ComputerUseAction {
    public static func getAppState(
        appIdentifier: String,
        windowTitle: String?,
        includeScreenshot: Bool,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault
    ) throws -> ComputerUseCommandOutput {
        let result = try captureSnapshotWithWindowFallback(
            appIdentifier: appIdentifier,
            windowTitle: windowTitle,
            includeScreenshot: includeScreenshot,
            screenshotCompression: screenshotCompression
        )
        let output = try ComputerUseCore.persistAndFormat(snapshot: result.snapshot)
        guard result.usedWindowFallback, let windowTitle else {
            return output
        }

        return ComputerUseCommandOutput(
            text: """
            Requested window_title "\(windowTitle)" was not found; returned the current \(appIdentifier) window instead. After navigation, prefer omitting window_title unless you need a specific stable window.

            \(output.text)
            """,
            metadata: output.metadata
        )
    }

    public static func getStructuredAppState(
        appIdentifier: String,
        windowTitle: String?,
        includeScreenshot: Bool,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault
    ) throws -> ComputerUseState {
        let result = try captureSnapshotWithWindowFallback(
            appIdentifier: appIdentifier,
            windowTitle: windowTitle,
            includeScreenshot: includeScreenshot,
            screenshotCompression: screenshotCompression
        )
        return try ComputerUseCore.persistAndBuildState(snapshot: result.snapshot)
    }

    public static func listApps() -> ComputerUseCommandOutput {
        let lines = ComputerUseCore.listApps().map(ComputerUseCore.formatAppListLine)
        return ComputerUseCommandOutput(text: lines.joined(separator: "\n"))
    }

    public static func openApp(appIdentifier: String) async throws -> ComputerUseCommandOutput {
        let result = try await ComputerUseCore.openApp(appIdentifier: appIdentifier)
        let status = result.didLaunch ? "Opened app:" : "App already running:"
        return ComputerUseCommandOutput(text: """
        \(status)
        \(ComputerUseCore.formatAppListLine(result.app))
        """)
    }

    public static func listWindows(appIdentifier: String) throws -> ComputerUseCommandOutput {
        let windows = try ComputerUseCore.listWindows(appIdentifier: appIdentifier)
        guard let first = windows.first else {
            return ComputerUseCommandOutput(text: "No windows found for \(appIdentifier).")
        }

        var lines = [
            "\(first.appName) — \(first.bundleID) [pid \(first.pid)]",
            "<windows>",
        ]
        for (index, window) in windows.enumerated() {
            var flags: [String] = []
            if window.isMain { flags.append("main") }
            let flagText = flags.isEmpty ? "" : " [\(flags.joined(separator: ","))]"
            lines.append(
                "[\(index)] window_id=\(window.windowID) title=\"\(window.title)\"\(flagText)"
            )
        }
        lines.append("</windows>")
        return ComputerUseCommandOutput(text: lines.joined(separator: "\n"))
    }

    public static func click(
        snapshotID: String,
        elementIndex: Int?,
        x: Double?,
        y: Double?,
        includeScreenshotAfter: Bool,
        session: ComputerUseSession,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault
    ) async throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.load(snapshotID: snapshotID)
        let current = try ComputerUseCore.validateSnapshot(metadata)
        let node = try elementIndex.map {
            try ComputerUseCore.resolveCachedElement(
                cachedIndex: $0,
                metadata: metadata,
                fresh: current
            )
        }
        let point: CGPoint?
        if let node {
            point = try? localPoint(node: node, in: current)
        } else if let x, let y {
            try ComputerUseCore.ensureStableFrameForCoordinateAction(
                metadata: metadata,
                fresh: current
            )
            point = try screenshotPointToWindowLocal(
                screenshotSize: metadata.screenshotSize,
                windowFrame: current.windowFrame,
                x: x,
                y: y
            )
        } else {
            point = nil
        }
        let event = session.visualEffectEvent(
            action: point == nil ? .targetWindow : .click,
            snapshot: current,
            startPoint: point
        )

        return try session.performWithBackgroundActivation(on: current, visualEffect: event) {
            if let node {
                if !performDefaultAXActionIfAvailable(on: node, in: current) {
                    try clickAtLocalPoint(try localPoint(node: node, in: current), in: current)
                }
            } else if let x, let y {
                let point = try screenshotPointToWindowLocal(
                    screenshotSize: metadata.screenshotSize,
                    windowFrame: current.windowFrame,
                    x: x,
                    y: y
                )
                try clickAtLocalPoint(point, in: current)
            } else {
                throw ComputerUseError.invalidArgument("click requires either element_index or x/y")
            }

            return try settledOutput(
                afterActionOn: current,
                includeScreenshot: includeScreenshotAfter,
                screenshotCompression: screenshotCompression
            )
        }
    }

    public static func typeText(
        snapshotID: String,
        text: String,
        elementIndex: Int?,
        includeScreenshotAfter: Bool,
        session: ComputerUseSession,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault
    ) async throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.load(snapshotID: snapshotID)
        let current = try ComputerUseCore.validateSnapshot(metadata)
        let event = session.visualEffectEvent(action: .keyboard, snapshot: current)
        return try session.performWithBackgroundActivation(on: current, visualEffect: event) {
            let node = try editableNode(
                in: current,
                metadata: metadata,
                explicitIndex: elementIndex
            )

            if cuIsAttributeSettable(node.element, name: kAXFocusedAttribute as String) {
                _ = AXUIElementSetAttributeValue(
                    node.element,
                    kAXFocusedAttribute as CFString,
                    kCFBooleanTrue
                )
            }

            let keyboard = BackgroundKeyboardDispatcher(
                targetPID: current.app.processIdentifier,
                windowNumber: current.windowID
            )
            try keyboard.typeText(text)

            return try settledOutput(
                afterActionOn: current,
                includeScreenshot: includeScreenshotAfter,
                screenshotCompression: screenshotCompression
            )
        }
    }

    public static func setValue(
        snapshotID: String,
        elementIndex: Int,
        value: String,
        includeScreenshotAfter: Bool,
        session: ComputerUseSession,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault
    ) async throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.load(snapshotID: snapshotID)
        let current = try ComputerUseCore.validateSnapshot(metadata)
        let node = try ComputerUseCore.resolveCachedElement(
            cachedIndex: elementIndex,
            metadata: metadata,
            fresh: current
        )

        guard node.isValueSettable else {
            throw ComputerUseError.elementNotSettable(elementIndex)
        }

        let event = session.visualEffectEvent(
            action: .accessibilityAction,
            snapshot: current,
            startPoint: try? localPoint(node: node, in: current),
            detail: "setValue"
        )
        return try session.performWithBackgroundActivation(on: current, visualEffect: event) {
            if cuIsAttributeSettable(node.element, name: kAXFocusedAttribute as String) {
                _ = AXUIElementSetAttributeValue(
                    node.element,
                    kAXFocusedAttribute as CFString,
                    kCFBooleanTrue
                )
            }

            let result = AXUIElementSetAttributeValue(
                node.element,
                kAXValueAttribute as CFString,
                value as CFTypeRef
            )
            guard result == .success else {
                throw UIElementError.axError(result, action: "set AXValue")
            }

            return try settledOutput(
                afterActionOn: current,
                includeScreenshot: includeScreenshotAfter,
                screenshotCompression: screenshotCompression
            )
        }
    }

    public static func pressKey(
        snapshotID: String,
        key: String,
        includeScreenshotAfter: Bool,
        session: ComputerUseSession,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault
    ) async throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.load(snapshotID: snapshotID)
        let current = try ComputerUseCore.validateSnapshot(metadata)
        let event = session.visualEffectEvent(action: .keyboard, snapshot: current, detail: key)
        return try session.performWithBackgroundActivation(on: current, visualEffect: event) {
            let dispatcher = BackgroundKeyboardDispatcher(
                targetPID: current.app.processIdentifier,
                windowNumber: current.windowID
            )
            try dispatcher.press(keyCombination: key)

            return try settledOutput(
                afterActionOn: current,
                includeScreenshot: includeScreenshotAfter,
                screenshotCompression: screenshotCompression
            )
        }
    }

    public static func scroll(
        snapshotID: String,
        elementIndex: Int,
        direction: String,
        pages: Double,
        includeScreenshotAfter: Bool,
        session: ComputerUseSession,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault
    ) async throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.load(snapshotID: snapshotID)
        let current = try ComputerUseCore.validateSnapshot(metadata)
        let node = try ComputerUseCore.resolveCachedElement(
            cachedIndex: elementIndex,
            metadata: metadata,
            fresh: current
        )
        let point = try localPoint(node: node, in: current)
        let event = session.visualEffectEvent(
            action: .scroll,
            snapshot: current,
            startPoint: point,
            detail: direction
        )
        return try session.performWithBackgroundActivation(on: current, visualEffect: event) {
            let dispatcher = BackgroundMouseDispatcher(
                targetPID: current.app.processIdentifier,
                windowNumber: current.windowID,
                windowFrame: current.windowFrame,
                modifierFlags: []
            )
            let didAXScroll = performAXScroll(
                startingAt: node.element,
                fallbackRoot: current.windowElement,
                direction: direction,
                pages: pages
            )
            if !didAXScroll {
                try dispatcher.scroll(at: point, direction: direction, pages: pages)
            }

            let output = try settledOutput(
                afterActionOn: current,
                includeScreenshot: includeScreenshotAfter,
                screenshotCompression: screenshotCompression
            )
            guard output.metadata?.fingerprint == current.fingerprint else {
                return output
            }

            let delivery = didAXScroll ? "AX scroll action" : "postToPid wheel fallback"
            return ComputerUseCommandOutput(
                text: """
                Scroll delivery note: \(delivery) produced no observable state change. Do not treat this alone as proof that the list reached its end; if exhaustive traversal is required, try another scrollable container or a keyboard/list-navigation path.

                \(output.text)
                """,
                metadata: output.metadata
            )
        }
    }

    public static func performSecondaryAction(
        snapshotID: String,
        elementIndex: Int,
        action: String,
        includeScreenshotAfter: Bool,
        session: ComputerUseSession,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault
    ) async throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.load(snapshotID: snapshotID)
        let current = try ComputerUseCore.validateSnapshot(metadata)
        let node = try ComputerUseCore.resolveCachedElement(
            cachedIndex: elementIndex,
            metadata: metadata,
            fresh: current
        )
        let rawAction = try resolveSecondaryAction(node: node, requestedAction: action)
        let event = session.visualEffectEvent(
            action: .accessibilityAction,
            snapshot: current,
            startPoint: try? localPoint(node: node, in: current),
            detail: rawAction
        )
        return try session.performWithBackgroundActivation(on: current, visualEffect: event) {
            let result = AXUIElementPerformAction(node.element, rawAction as CFString)
            guard result == .success else {
                throw UIElementError.axError(result, action: rawAction)
            }

            return try settledOutput(
                afterActionOn: current,
                includeScreenshot: includeScreenshotAfter,
                screenshotCompression: screenshotCompression
            )
        }
    }

    public static func drag(
        snapshotID: String,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        includeScreenshotAfter: Bool,
        session: ComputerUseSession,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault
    ) async throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.load(snapshotID: snapshotID)
        let current = try ComputerUseCore.validateSnapshot(metadata)
        try ComputerUseCore.ensureStableFrameForCoordinateAction(
            metadata: metadata,
            fresh: current
        )
        let fromLocal = try screenshotPointToWindowLocal(
            screenshotSize: metadata.screenshotSize,
            windowFrame: current.windowFrame,
            x: fromX,
            y: fromY
        )
        let toLocal = try screenshotPointToWindowLocal(
            screenshotSize: metadata.screenshotSize,
            windowFrame: current.windowFrame,
            x: toX,
            y: toY
        )
        let event = session.visualEffectEvent(
            action: .drag,
            snapshot: current,
            startPoint: fromLocal,
            endPoint: toLocal
        )

        return try session.performWithBackgroundActivation(on: current, visualEffect: event) {

            let dispatcher = BackgroundMouseDispatcher(
                targetPID: current.app.processIdentifier,
                windowNumber: current.windowID,
                windowFrame: current.windowFrame,
                modifierFlags: []
            )

            var handle = try dispatcher.startDrag(at: fromLocal, button: .left)
            let steps = 16
            for step in 1 ... steps {
                let t = CGFloat(step) / CGFloat(steps)
                let point = CGPoint(
                    x: fromLocal.x + ((toLocal.x - fromLocal.x) * t),
                    y: fromLocal.y + ((toLocal.y - fromLocal.y) * t)
                )
                try handle.move(to: point)
                usleep(12_000)
            }
            try handle.release(at: toLocal)

            return try settledOutput(
                afterActionOn: current,
                includeScreenshot: includeScreenshotAfter,
                screenshotCompression: screenshotCompression
            )
        }
    }

}
