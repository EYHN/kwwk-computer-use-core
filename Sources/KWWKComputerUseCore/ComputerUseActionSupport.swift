import ApplicationServices
import Foundation

extension ComputerUseAction {
    static func captureSnapshotWithWindowFallback(
        appIdentifier: String,
        windowTitle: String?,
        includeScreenshot: Bool,
        screenshotCompression: ComputerUseScreenshotCompression
    ) throws -> (snapshot: RuntimeAppSnapshot, usedWindowFallback: Bool) {
        do {
            let snapshot = try ComputerUseCore.captureSnapshot(
                appIdentifier: appIdentifier,
                selection: WindowSelection(titleSubstring: windowTitle),
                includeScreenshot: includeScreenshot,
                screenshotCompression: screenshotCompression
            )
            return (snapshot, false)
        } catch let error as ComputerUseError {
            guard case .windowNotFound = error,
                  let windowTitle,
                  windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            else {
                throw error
            }

            let snapshot = try ComputerUseCore.captureSnapshot(
                appIdentifier: appIdentifier,
                includeScreenshot: includeScreenshot,
                screenshotCompression: screenshotCompression
            )
            return (snapshot, true)
        }
    }

    static func localPoint(
        node: RuntimeAXNode,
        in snapshot: RuntimeAppSnapshot
    ) throws -> CGPoint {
        guard let frame = clickFrame(for: node, in: snapshot) else {
            throw ComputerUseError.elementFrameUnavailable(node.index)
        }

        let screenPoint = CGPoint(x: frame.midX, y: frame.midY)
        return translatedWindowLocalPoint(
            screenPoint: screenPoint,
            windowFrame: snapshot.windowFrame
        )
    }

    static func clickFrame(
        for node: RuntimeAXNode,
        in snapshot: RuntimeAppSnapshot
    ) -> CGRect? {
        if shouldPreferDescendantClickFrame(for: node),
           let descendantFrame = descendantClickFrame(for: node, in: snapshot) {
            return descendantFrame
        }
        return node.frame ?? descendantClickFrame(for: node, in: snapshot)
    }

    static func shouldPreferDescendantClickFrame(for node: RuntimeAXNode) -> Bool {
        let structuralRoles: Set<String> = [
            kAXGroupRole as String,
            kAXRowRole as String,
            kAXCellRole as String,
        ]
        return structuralRoles.contains(node.role)
    }

    static func descendantClickFrame(
        for node: RuntimeAXNode,
        in snapshot: RuntimeAppSnapshot
    ) -> CGRect? {
        let start = node.index + 1
        guard start < snapshot.nodes.count else { return nil }

        var frames: [CGRect] = []
        for index in start ..< snapshot.nodes.count {
            let candidate = snapshot.nodes[index]
            guard candidate.depth > node.depth else { break }
            guard let frame = candidate.frame,
                  frame.width >= 2,
                  frame.height >= 2,
                  cuFrameIsVisible(frame, in: snapshot.windowFrame)
            else {
                continue
            }

            if candidate.role == kAXStaticTextRole as String ||
                candidate.role == kAXImageRole as String ||
                candidate.title.isEmpty == false ||
                candidate.description.isEmpty == false {
                frames.append(frame)
            }
        }

        guard frames.isEmpty == false else { return nil }
        let union = frames.dropFirst().reduce(frames[0]) { partial, frame in
            partial.union(frame)
        }
        guard union.height <= max(24, snapshot.windowFrame.height * 0.35),
              union.width <= max(24, snapshot.windowFrame.width * 0.95)
        else {
            return nil
        }
        return union
    }

    static func clickAtLocalPoint(
        _ localPoint: CGPoint,
        in snapshot: RuntimeAppSnapshot
    ) throws {
        let dispatcher = BackgroundMouseDispatcher(
            targetPID: snapshot.app.processIdentifier,
            windowNumber: snapshot.windowID,
            windowFrame: snapshot.windowFrame,
            modifierFlags: []
        )
        try dispatcher.click(at: localPoint)
    }

    static func performDefaultAXActionIfAvailable(
        on node: RuntimeAXNode,
        in snapshot: RuntimeAppSnapshot
    ) -> Bool {
        let preferredActions = if node.role == (kAXMenuBarItemRole as String) ||
            node.role == (kAXMenuItemRole as String)
        {
            [kAXPressAction as String, "AXPick"]
        } else {
            [kAXPressAction as String]
        }

        guard let action = preferredActions.first(where: { node.actions.contains($0) }) else {
            return false
        }
        FocusDebug.log("ax \(displayName(forAction: action)) start element=\(node.index): \(focusTargetDescription(snapshot))")
        let succeeded = AXUIElementPerformAction(node.element, action as CFString) == .success
        FocusDebug.log("ax \(displayName(forAction: action)) end success=\(succeeded): \(focusTargetDescription(snapshot))")
        return succeeded
    }

    static func focusTargetDescription(_ snapshot: RuntimeAppSnapshot) -> String {
        let appName = snapshot.app.localizedName ?? snapshot.app.bundleIdentifier ?? "unknown"
        let target = "\(appName) pid=\(snapshot.app.processIdentifier) bundle=\(snapshot.app.bundleIdentifier ?? "-") active=\(snapshot.app.isActive) hidden=\(snapshot.app.isHidden)"
        return "frontmost=\(FocusDebug.frontmostDescription()) target=\(target) window=\(snapshot.windowID) \(FocusDebug.windowStackDescription(windowNumber: snapshot.windowID, targetPID: snapshot.app.processIdentifier))"
    }

    static func editableNode(
        in snapshot: RuntimeAppSnapshot,
        metadata: ComputerUseSnapshotMetadata,
        explicitIndex: Int?
    ) throws -> RuntimeAXNode {
        if let explicitIndex {
            let node = try ComputerUseCore.resolveCachedElement(
                cachedIndex: explicitIndex,
                metadata: metadata,
                fresh: snapshot
            )
            guard node.isValueSettable else {
                throw ComputerUseError.elementNotSettable(explicitIndex)
            }
            return node
        }

        guard let focusedIndex = snapshot.focusedElementIndex else {
            throw ComputerUseError.focusedElementUnavailable
        }
        let focused = try snapshot.node(index: focusedIndex)
        guard focused.isValueSettable else {
            throw ComputerUseError.elementNotSettable(focusedIndex)
        }
        return focused
    }

    static func performAXScroll(
        startingAt element: AXUIElement,
        fallbackRoot: AXUIElement,
        direction: String,
        pages: Double
    ) -> Bool {
        let canonical = direction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let wantsVertical = canonical == "up" || canonical == "down"
        let wantsIncrement = canonical == "down" || canonical == "right"
        let action = wantsIncrement ? (kAXIncrementAction as String) : (kAXDecrementAction as String)
        let roots = [element, fallbackRoot]
        let foundScrollBars = roots.flatMap { scrollBars(in: $0) }
        let matching = foundScrollBars.filter { bar in
            guard let orientation = cuAttribute(bar, name: kAXOrientationAttribute as String) as String? else {
                return true
            }
            if wantsVertical {
                return orientation == (kAXVerticalOrientationValue as String)
            }
            return orientation == (kAXHorizontalOrientationValue as String)
        }

        let repetitions = max(1, Int((max(0.05, pages) * 3).rounded(.up)))
        for bar in matching {
            var performed = false
            for _ in 0 ..< repetitions {
                let result = AXUIElementPerformAction(bar, action as CFString)
                if result != AXError.success { break }
                performed = true
                usleep(20_000)
            }
            if performed {
                return true
            }

            if setScrollBarValue(bar, increment: wantsIncrement, pages: pages) {
                return true
            }
        }
        return false
    }

    static func scrollBars(in root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var stack = [root]
        var visited = Set<ObjectIdentifier>()
        let relationshipAttributes = [
            kAXChildrenAttribute as String,
            kAXContentsAttribute as String,
            kAXVerticalScrollBarAttribute as String,
            kAXHorizontalScrollBarAttribute as String,
        ]
        while let current = stack.popLast() {
            let identifier = ObjectIdentifier(current as AnyObject)
            if visited.contains(identifier) { continue }
            visited.insert(identifier)

            let role = cuAttribute(current, name: kAXRoleAttribute as String) as String? ?? ""
            if role == (kAXScrollBarRole as String) {
                result.append(current)
                continue
            }

            for attribute in relationshipAttributes {
                if let child = cuAttribute(current, name: attribute) as AXUIElement? {
                    stack.append(child)
                } else if let children = cuAttribute(current, name: attribute) as [AXUIElement]? {
                    stack.append(contentsOf: children)
                }
            }
        }
        return result
    }

    static func setScrollBarValue(
        _ scrollBar: AXUIElement,
        increment: Bool,
        pages: Double
    ) -> Bool {
        guard cuIsAttributeSettable(scrollBar, name: kAXValueAttribute as String),
              let rawValue = cuRawAttribute(scrollBar, name: kAXValueAttribute as String),
              let current = numericValue(rawValue)
        else {
            return false
        }

        let minValue = numericValue(cuRawAttribute(scrollBar, name: kAXMinValueAttribute as String)) ?? 0
        let maxValue = numericValue(cuRawAttribute(scrollBar, name: kAXMaxValueAttribute as String)) ?? 1
        let span = max(maxValue - minValue, 0.01)
        let delta = span * 0.18 * max(0.05, pages)
        let target = min(max(current + (increment ? delta : -delta), minValue), maxValue)
        guard abs(target - current) > 0.0001 else { return false }

        let number = NSNumber(value: target)
        return AXUIElementSetAttributeValue(
            scrollBar,
            kAXValueAttribute as CFString,
            number
        ) == .success
    }

    static func numericValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let double as Double:
            return double
        case let float as Float:
            return Double(float)
        case let int as Int:
            return Double(int)
        default:
            return nil
        }
    }

    static func screenshotPointToWindowLocal(
        screenshotSize: CGSizeCodable?,
        windowFrame: CGRect,
        x: Double,
        y: Double
    ) throws -> CGPoint {
        guard let screenshotSize = screenshotSize?.cgSize else {
            throw ComputerUseError.coordinateActionRequiresScreenshot
        }

        return windowLocalPoint(
            fromScreenshotPixel: CGPoint(x: x, y: y),
            screenshotSize: screenshotSize,
            windowFrame: windowFrame
        )
    }

    static func resolveSecondaryAction(
        node: RuntimeAXNode,
        requestedAction: String
    ) throws -> String {
        if let raw = node.actions.first(where: {
            $0.caseInsensitiveCompare(requestedAction) == .orderedSame
        }) {
            return raw
        }

        if let display = node.actions.first(where: {
            displayName(forAction: $0).caseInsensitiveCompare(requestedAction) == .orderedSame
        }) {
            return display
        }

        throw ComputerUseError.secondaryActionNotFound(
            elementIndex: node.index,
            action: requestedAction
        )
    }

    static func settledOutput(
        afterActionOn snapshot: RuntimeAppSnapshot,
        includeScreenshot: Bool,
        screenshotCompression: ComputerUseScreenshotCompression
    ) throws -> ComputerUseCommandOutput {
        let updated = try ComputerUseCore.captureSettledSnapshot(
            afterActionOn: snapshot,
            includeScreenshot: includeScreenshot,
            screenshotCompression: screenshotCompression
        )
        return try ComputerUseCore.persistAndFormat(snapshot: updated)
    }
}
