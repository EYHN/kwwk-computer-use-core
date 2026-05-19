import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation
import Testing
@testable import KWWKComputerUseCore

private enum JSONValue {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

private enum ComputerUseTestHarness {
    static func executeAction(
        action: String,
        args: [String: JSONValue],
        screenshotCompression: ComputerUseScreenshotCompression,
        session: ComputerUseSession? = nil
    ) async throws -> ComputerUseCommandOutput {
        switch action {
        case "get-app-state":
            return try await withSession(session) { session in
                try ComputerUseAction.getAppState(
                    appIdentifier: try requiredString(args, "app"),
                    windowTitle: optionalString(args, "window_title"),
                    windowID: optionalInt(args, "window_id"),
                    includeScreenshot: optionalBool(args, "include_screenshot") ?? false,
                    session: session,
                    screenshotCompression: screenshotCompression
                )
            }
        case "click":
            return try await withSession(session) { session in
                try await ComputerUseAction.click(
                    elementIndex: optionalInt(args, "element_index"),
                    x: optionalDouble(args, "x"),
                    y: optionalDouble(args, "y"),
                    includeScreenshotAfter: optionalBool(args, "include_screenshot_after") ?? false,
                    session: session,
                    screenshotCompression: screenshotCompression
                )
            }
        case "type-text":
            return try await withSession(session) { session in
                try await ComputerUseAction.typeText(
                    text: try requiredString(args, "text"),
                    elementIndex: optionalInt(args, "element_index"),
                    includeScreenshotAfter: optionalBool(args, "include_screenshot_after") ?? false,
                    session: session,
                    screenshotCompression: screenshotCompression
                )
            }
        case "set-value":
            return try await withSession(session) { session in
                try await ComputerUseAction.setValue(
                    elementIndex: try requiredInt(args, "element_index"),
                    value: try requiredString(args, "value"),
                    includeScreenshotAfter: optionalBool(args, "include_screenshot_after") ?? false,
                    session: session,
                    screenshotCompression: screenshotCompression
                )
            }
        case "press-key":
            return try await withSession(session) { session in
                try await ComputerUseAction.pressKey(
                    key: try requiredString(args, "key"),
                    includeScreenshotAfter: optionalBool(args, "include_screenshot_after") ?? false,
                    session: session,
                    screenshotCompression: screenshotCompression
                )
            }
        case "perform-secondary-action":
            return try await withSession(session) { session in
                try await ComputerUseAction.performSecondaryAction(
                    elementIndex: try requiredInt(args, "element_index"),
                    action: try requiredString(args, "action"),
                    includeScreenshotAfter: optionalBool(args, "include_screenshot_after") ?? false,
                    session: session,
                    screenshotCompression: screenshotCompression
                )
            }
        default:
            throw ComputerUseError.invalidArgument("unknown test action \(action)")
        }
    }

    private static func withSession<T>(
        _ provided: ComputerUseSession?,
        _ body: (ComputerUseSession) async throws -> T
    ) async throws -> T {
        if let provided {
            return try await body(provided)
        }
        let session = ComputerUseSession()
        defer { session.finish() }
        return try await body(session)
    }

    private static func requiredString(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard case let .string(value) = args[key] else {
            throw ComputerUseError.invalidArgument("\(key) is required")
        }
        return value
    }

    private static func optionalString(_ args: [String: JSONValue], _ key: String) -> String? {
        guard case let .string(value) = args[key] else { return nil }
        return value
    }

    private static func requiredInt(_ args: [String: JSONValue], _ key: String) throws -> Int {
        guard let value = optionalInt(args, key) else {
            throw ComputerUseError.invalidArgument("\(key) is required")
        }
        return value
    }

    private static func optionalInt(_ args: [String: JSONValue], _ key: String) -> Int? {
        guard case let .int(value) = args[key] else { return nil }
        return value
    }

    private static func optionalDouble(_ args: [String: JSONValue], _ key: String) -> Double? {
        switch args[key] {
        case let .double(value): value
        case let .int(value): Double(value)
        default: nil
        }
    }

    private static func optionalBool(_ args: [String: JSONValue], _ key: String) -> Bool? {
        guard case let .bool(value) = args[key] else { return nil }
        return value
    }
}

@_silgen_name("GetProcessForPID")
private func testGetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

@_silgen_name("SetFrontProcessWithOptions")
private func testSetFrontProcessWithOptions(_ psn: UnsafePointer<ProcessSerialNumber>, _ options: UInt32) -> OSStatus

@Suite("Computer use in-process background behavior", .serialized)
struct InProcessComputerUseBehaviorTests {
    @Test("direct product actions preserve background focus invariants")
    func directProductActionsPreserveBackgroundFocusInvariants() async throws {
        guard ProcessInfo.processInfo.environment["KWWK_COMPUTER_USE_CORE_RUN_GUI_PROBE_TESTS"] == "1" else {
            return
        }
        guard AXIsProcessTrusted() else {
            Issue.record("Accessibility permission is required for GUI Probe tests.")
            return
        }
        guard ProbeHarness.bundleExists("A"),
              ProbeHarness.bundleExists("B"),
              ProbeHarness.bundleExists("C")
        else {
            Issue.record("Probe apps are missing under /private/tmp/kwwk-activation-probe.")
            return
        }
        ProbeHarness.showCountdownIfNeeded()
        defer { ProbeHarness.cleanup() }

        try await verifyClickByElement()
        try await verifyClickByCoordinate()
        try await verifyTypeText()
        try await verifyAXValueAndPress()
        try await verifySessionSwitchingRestoresPreviousBackgroundTarget()
    }

    @Test("coordinate clicks land at requested Probe window locations")
    func coordinateClicksLandAtRequestedProbeWindowLocations() async throws {
        guard ProcessInfo.processInfo.environment["KWWK_COMPUTER_USE_CORE_RUN_GUI_PROBE_TESTS"] == "1" else {
            return
        }
        guard AXIsProcessTrusted() else {
            Issue.record("Accessibility permission is required for GUI Probe tests.")
            return
        }
        guard ProbeHarness.bundleExists("A"),
              ProbeHarness.bundleExists("B"),
              ProbeHarness.bundleExists("C")
        else {
            Issue.record("Probe apps are missing under /private/tmp/kwwk-activation-probe.")
            return
        }
        ProbeHarness.showCountdownIfNeeded()
        defer { ProbeHarness.cleanup() }

        try await verifyCoordinateClickLocation(
            windowLocalPoint: CGPoint(x: 355, y: 200),
            eventPrefix: "root.mouseDown",
            expectedClickDelta: 0
        )
        try await verifyCoordinateClickLocation(
            windowLocalPoint: CGPoint(x: 108, y: 53),
            eventPrefix: "button.mouseDown",
            expectedClickDelta: 1
        )
    }

    @Test("Probe global menu bar click returns menu AX tree")
    func probeGlobalMenuBarClickReturnsMenuAXTree() async throws {
        guard ProcessInfo.processInfo.environment["KWWK_COMPUTER_USE_CORE_RUN_GUI_PROBE_TESTS"] == "1" else {
            return
        }
        guard AXIsProcessTrusted() else {
            Issue.record("Accessibility permission is required for GUI Probe tests.")
            return
        }
        guard ProbeHarness.bundleExists("A"),
              ProbeHarness.bundleExists("B"),
              ProbeHarness.bundleExists("C")
        else {
            Issue.record("Probe apps are missing under /private/tmp/kwwk-activation-probe.")
            return
        }
        ProbeHarness.showCountdownIfNeeded()
        defer { ProbeHarness.cleanup() }

        try await verifyGlobalMenuBarClickReturnsMenuAXTree()
    }

    @Test("Probe background global menu item can be picked")
    func probeBackgroundGlobalMenuItemCanBePicked() async throws {
        guard ProcessInfo.processInfo.environment["KWWK_COMPUTER_USE_CORE_RUN_GUI_PROBE_TESTS"] == "1" else {
            return
        }
        guard AXIsProcessTrusted() else {
            Issue.record("Accessibility permission is required for GUI Probe tests.")
            return
        }
        guard ProbeHarness.bundleExists("A"),
              ProbeHarness.bundleExists("B"),
              ProbeHarness.bundleExists("C")
        else {
            Issue.record("Probe apps are missing under /private/tmp/kwwk-activation-probe.")
            return
        }
        ProbeHarness.showCountdownIfNeeded()
        defer { ProbeHarness.cleanup() }

        try await verifyBackgroundGlobalMenuItemCanBePicked()
    }

    @Test("Probe status menu click returns menu AX tree")
    func probeStatusMenuClickReturnsMenuAXTree() async throws {
        guard ProcessInfo.processInfo.environment["KWWK_COMPUTER_USE_CORE_RUN_GUI_PROBE_TESTS"] == "1" else {
            return
        }
        guard AXIsProcessTrusted() else {
            Issue.record("Accessibility permission is required for GUI Probe tests.")
            return
        }
        guard ProbeHarness.bundleExists("A"),
              ProbeHarness.bundleExists("B"),
              ProbeHarness.bundleExists("C")
        else {
            Issue.record("Probe apps are missing under /private/tmp/kwwk-activation-probe.")
            return
        }
        ProbeHarness.showCountdownIfNeeded()
        defer { ProbeHarness.cleanup() }

        try await verifyStatusMenuClickReturnsMenuAXTree()
    }

    @Test("Probe window menu button click returns menu AX tree")
    func probeWindowMenuButtonClickReturnsMenuAXTree() async throws {
        guard ProcessInfo.processInfo.environment["KWWK_COMPUTER_USE_CORE_RUN_GUI_PROBE_TESTS"] == "1" else {
            return
        }
        guard AXIsProcessTrusted() else {
            Issue.record("Accessibility permission is required for GUI Probe tests.")
            return
        }
        guard ProbeHarness.bundleExists("A"),
              ProbeHarness.bundleExists("B"),
              ProbeHarness.bundleExists("C")
        else {
            Issue.record("Probe apps are missing under /private/tmp/kwwk-activation-probe.")
            return
        }
        ProbeHarness.showCountdownIfNeeded()
        defer { ProbeHarness.cleanup() }

        try await verifyWindowMenuButtonClickReturnsMenuAXTree()
    }

    @Test("Probe window menu button minimal repro")
    func probeWindowMenuButtonMinimalRepro() async throws {
        guard ProcessInfo.processInfo.environment["KWWK_COMPUTER_USE_CORE_RUN_GUI_PROBE_TESTS"] == "1" else {
            return
        }
        guard AXIsProcessTrusted() else {
            Issue.record("Accessibility permission is required for GUI Probe tests.")
            return
        }
        guard ProbeHarness.bundleExists("A"),
              ProbeHarness.bundleExists("B"),
              ProbeHarness.bundleExists("C")
        else {
            Issue.record("Probe apps are missing under /private/tmp/kwwk-activation-probe.")
            return
        }
        ProbeHarness.showCountdownIfNeeded()
        defer { ProbeHarness.cleanup() }

        try await verifyWindowMenuButtonMinimalRepro()
    }

    private func verifyClickByElement() async throws {
        let context = try ProbeHarness.reset()
        let baseline = ProbeHarness.captureBaseline(context)
        let session = makeProbeSession()
        defer { session.finish() }
        let snapshot = try await getProbeBState(includeScreenshot: false, session: session)
        let buttonIndex = try index(containingIdentifier: "probe-button", in: snapshot.text)

        _ = try await ComputerUseTestHarness.executeAction(
            action: "click",
            args: [
                "element_index": .int(buttonIndex),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        ProbeHarness.pump(0.35)
        try ProbeHarness.expectInvariant(
            baseline: baseline,
            context: context,
            expectedClicks: baseline.clicks + 1
        )
    }

    private func verifyClickByCoordinate() async throws {
        let context = try ProbeHarness.reset()
        let baseline = ProbeHarness.captureBaseline(context)
        let session = makeProbeSession()
        defer { session.finish() }
        let snapshot = try await getProbeBState(includeScreenshot: true, session: session)
        let metadata = try #require(snapshot.metadata)
        let buttonFrame = try ProbeHarness.axFrame(
            try ProbeHarness.findElement(inProbeB: context) {
                ProbeHarness.axString($0, kAXIdentifierAttribute as String) == "probe-button"
            }
        )
        let coordinate = screenshotCoordinate(
            screenPoint: CGPoint(x: buttonFrame.midX, y: buttonFrame.midY),
            windowFrame: metadata.windowFrame.cgRect,
            screenshotSize: try #require(metadata.screenshotSize).cgSize
        )

        _ = try await ComputerUseTestHarness.executeAction(
            action: "click",
            args: [
                "x": .double(coordinate.x),
                "y": .double(coordinate.y),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        ProbeHarness.pump(0.35)
        try ProbeHarness.expectInvariant(
            baseline: baseline,
            context: context,
            expectedClicks: baseline.clicks + 1
        )
    }

    private func verifyTypeText() async throws {
        let context = try ProbeHarness.reset()
        let baseline = ProbeHarness.captureBaseline(context)
        let session = makeProbeSession()
        defer { session.finish() }
        let snapshot = try await getProbeBState(includeScreenshot: false, session: session)
        let inputIndex = try index(containingIdentifier: "probe-input", in: snapshot.text)

        _ = try await ComputerUseTestHarness.executeAction(
            action: "type-text",
            args: [
                "element_index": .int(inputIndex),
                "text": .string("ip"),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        ProbeHarness.pump(0.35)
        let input = try ProbeHarness.findElement(inProbeB: context) {
            ProbeHarness.axString($0, kAXIdentifierAttribute as String) == "probe-input"
        }
        #expect(ProbeHarness.axString(input, kAXValueAttribute as String) == "ip")
        try ProbeHarness.expectInvariant(
            baseline: baseline,
            context: context,
            expectedClicks: baseline.clicks
        )
    }

    private func verifyAXValueAndPress() async throws {
        let context = try ProbeHarness.reset()
        let baseline = ProbeHarness.captureBaseline(context)
        let session = makeProbeSession()
        defer { session.finish() }
        let snapshot = try await getProbeBState(includeScreenshot: false, session: session)
        let inputIndex = try index(containingIdentifier: "probe-input", in: snapshot.text)
        let buttonIndex = try index(containingIdentifier: "probe-button", in: snapshot.text)

        _ = try await ComputerUseTestHarness.executeAction(
            action: "set-value",
            args: [
                "element_index": .int(inputIndex),
                "value": .string("ax"),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        _ = try await getProbeBState(includeScreenshot: false, session: session)
        _ = try await ComputerUseTestHarness.executeAction(
            action: "perform-secondary-action",
            args: [
                "element_index": .int(buttonIndex),
                "action": .string("Press"),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        ProbeHarness.pump(0.35)
        let input = try ProbeHarness.findElement(inProbeB: context) {
            ProbeHarness.axString($0, kAXIdentifierAttribute as String) == "probe-input"
        }
        #expect(ProbeHarness.axString(input, kAXValueAttribute as String) == "ax")
        try ProbeHarness.expectInvariant(
            baseline: baseline,
            context: context,
            expectedClicks: baseline.clicks + 1
        )
    }

    private func verifyCoordinateClickLocation(
        windowLocalPoint expectedPoint: CGPoint,
        eventPrefix: String,
        expectedClickDelta: Int
    ) async throws {
        let context = try ProbeHarness.reset()
        let baseline = ProbeHarness.captureBaseline(context)
        let session = makeProbeSession()
        defer { session.finish() }
        let beforeLog = ProbeHarness.logText("ProbeB")
        let snapshot = try await getProbeBState(includeScreenshot: true, session: session)
        let metadata = try #require(snapshot.metadata)
        let coordinate = screenshotCoordinate(
            windowLocalPoint: expectedPoint,
            windowFrame: metadata.windowFrame.cgRect,
            screenshotSize: try #require(metadata.screenshotSize).cgSize
        )

        _ = try await ComputerUseTestHarness.executeAction(
            action: "click",
            args: [
                "x": .double(coordinate.x),
                "y": .double(coordinate.y),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        ProbeHarness.pump(0.35)
        let newLog = String(ProbeHarness.logText("ProbeB").dropFirst(beforeLog.count))
        let actualPoint = try #require(ProbeHarness.latestLoggedPoint(in: newLog, prefix: eventPrefix))
        #expect(ProbeHarness.distance(actualPoint, expectedPoint) <= 2)
        try ProbeHarness.expectInvariant(
            baseline: baseline,
            context: context,
            expectedClicks: baseline.clicks + expectedClickDelta
        )
    }

    private func verifySessionSwitchingRestoresPreviousBackgroundTarget() async throws {
        let context = try ProbeHarness.reset()
        let baseline = ProbeHarness.captureBaseline(context)
        let session = makeProbeSession()
        defer { session.finish() }

        let probeBSnapshot = try await getProbeState("B", includeScreenshot: false, session: session)
        let probeBButton = try index(containingIdentifier: "probe-button", in: probeBSnapshot.text)
        _ = try await ComputerUseTestHarness.executeAction(
            action: "click",
            args: [
                "element_index": .int(probeBButton),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        ProbeHarness.pump(0.35)
        try ProbeHarness.expectInvariant(
            baseline: baseline,
            context: context,
            expectedClicks: baseline.clicks + 1
        )

        let probeCSnapshot = try await getProbeState("C", includeScreenshot: false, session: session)
        let probeCButton = try index(containingIdentifier: "probe-button", in: probeCSnapshot.text)
        _ = try await ComputerUseTestHarness.executeAction(
            action: "click",
            args: [
                "element_index": .int(probeCButton),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        ProbeHarness.pump(0.35)
        #expect(ProbeHarness.lastState("ProbeB")?.contains("isActive=false") == true)
        #expect(ProbeHarness.lastState("ProbeC")?.contains("isActive=true") == true)
        #expect(ProbeHarness.stack(ids: context.ids) == baseline.stack)
        #expect(ProbeHarness.frontmost() == baseline.frontmost)

        session.finish()
        ProbeHarness.pump(0.35)
        #expect(ProbeHarness.lastState("ProbeC")?.contains("isActive=false") == true)
        #expect(ProbeHarness.stack(ids: context.ids) == baseline.stack)
        #expect(ProbeHarness.frontmost() == baseline.frontmost)
    }

    private func verifyGlobalMenuBarClickReturnsMenuAXTree() async throws {
        let context = try ProbeHarness.reset()
        let baseline = ProbeHarness.captureBaseline(context)
        let session = makeProbeSession()
        defer { session.finish() }

        let snapshot = try await getProbeBState(includeScreenshot: false, session: session)
        #expect(snapshot.text.contains("\n\t") && snapshot.text.contains("ProbeB"))
        #expect(!snapshot.text.contains("Apple, Secondary Actions"))
        let appMenuIndex = try index(containingAll: ["Probe Tools"], in: snapshot.text)

        let output = try await ComputerUseTestHarness.executeAction(
            action: "click",
            args: [
                "element_index": .int(appMenuIndex),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        #expect(output.text.contains(#"<app_state surface="menu">"#))
        #expect(output.text.contains("Probe Tool One"))
        #expect(output.text.contains("The focused UI element") == false || output.text.contains("menu"))

        if output.metadata != nil {
            _ = try? await ComputerUseTestHarness.executeAction(
                action: "press-key",
                args: [
                    "key": .string("Escape"),
                    "include_screenshot_after": .bool(false),
                ],
                screenshotCompression: .foregroundDefault,
                session: session
            )
        }

        ProbeHarness.pump(0.35)
        #expect(ProbeHarness.clicks("ProbeB") == baseline.clicks)
    }

    private func verifyBackgroundGlobalMenuItemCanBePicked() async throws {
        let context = try ProbeHarness.reset()
        let baseline = ProbeHarness.captureBaseline(context)
        let session = makeProbeSession()
        defer { session.finish() }

        let snapshot = try await getProbeBState(includeScreenshot: false, session: session)
        #expect(snapshot.text.contains("Probe Tools"))
        let toolsMenuIndex = try index(containingAll: ["Probe Tools"], in: snapshot.text)

        let menuOutput = try await ComputerUseTestHarness.executeAction(
            action: "click",
            args: [
                "element_index": .int(toolsMenuIndex),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        #expect(menuOutput.text.contains("Probe Tool One"))
        ProbeHarness.pump(0.25)
        let toolOneIndex = try index(containingAll: ["Probe Tool One"], in: menuOutput.text)
        let postPickOutput = try await ComputerUseTestHarness.executeAction(
            action: "click",
            args: [
                "element_index": .int(toolOneIndex),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        assertWindowSurface(
            postPickOutput.text,
            containing: ["ProbeB Main Window", "probe-menu-button"],
            excluding: ["Probe Tool One", "Probe Tool Two"],
            label: "global-menu-item-click"
        )

        ProbeHarness.pump(0.35)
        #expect(ProbeHarness.logText("ProbeB").contains("appMenuPicked title=Probe Tool One"))
        #expect(ProbeHarness.stack(ids: context.ids) == baseline.stack)
        #expect(ProbeHarness.frontmost() == baseline.frontmost)
        #expect(ProbeHarness.clicks("ProbeB") == baseline.clicks)
    }

    private func verifyStatusMenuClickReturnsMenuAXTree() async throws {
        _ = try ProbeHarness.reset()
        let session = makeProbeSession()
        defer { session.finish() }

        let snapshot = try await getProbeBState(includeScreenshot: false, session: session)
        let statusIndex = try index(containingIdentifier: "probe-status-item", in: snapshot.text)
        let menuOutput = try await ComputerUseTestHarness.executeAction(
            action: "click",
            args: [
                "element_index": .int(statusIndex),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        assertMenuSurface(menuOutput.text, containing: ["ProbeB Status One", "ProbeB Status Two"], label: "status-click")

        let statusOneIndex = try index(containingAll: ["ProbeB Status One"], in: menuOutput.text)
        let postPickOutput = try await ComputerUseTestHarness.executeAction(
            action: "click",
            args: [
                "element_index": .int(statusOneIndex),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        assertWindowSurface(
            postPickOutput.text,
            containing: ["ProbeB Main Window", "probe-menu-button"],
            excluding: ["ProbeB Status One", "ProbeB Status Two"],
            label: "status-menu-item-click"
        )

        ProbeHarness.pump(0.35)
        #expect(ProbeHarness.logText("ProbeB").contains("statusMenuPicked title=ProbeB Status One"))
    }

    private func verifyWindowMenuButtonClickReturnsMenuAXTree() async throws {
        let context = try ProbeHarness.reset()
        let baseline = ProbeHarness.captureBaseline(context)
        let session = makeProbeSession()
        defer { session.finish() }

        let snapshot = try await getProbeBState(includeScreenshot: false, session: session)
        let menuButtonIndex = try index(containingIdentifier: "probe-menu-button", in: snapshot.text)

        let menuOutput = try await ComputerUseTestHarness.executeAction(
            action: "click",
            args: [
                "element_index": .int(menuButtonIndex),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        assertMenuSurface(menuOutput.text, containing: ["First Choice", "Second Choice"], label: "popup-click")

        let firstChoiceIndex = try index(containingAll: ["First Choice"], in: menuOutput.text)
        let postPickOutput = try await ComputerUseTestHarness.executeAction(
            action: "click",
            args: [
                "element_index": .int(firstChoiceIndex),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        assertWindowSurface(
            postPickOutput.text,
            containing: ["ProbeB Main Window", "probe-menu-button"],
            excluding: ["First Choice", "Second Choice"],
            label: "popup-item-click"
        )

        ProbeHarness.pump(0.35)
        #expect(ProbeHarness.logText("ProbeB").contains("windowMenuPicked title=First Choice"))
        #expect(ProbeHarness.clicks("ProbeB") == baseline.clicks)
    }

    private func verifyWindowMenuButtonMinimalRepro() async throws {
        let context = try ProbeHarness.reset()
        let baseline = ProbeHarness.captureBaseline(context)
        let session = makeProbeSession()
        defer { session.finish() }

        let snapshot = try await getProbeBState(includeScreenshot: false, session: session)
        let menuButtonIndex = try index(containingIdentifier: "probe-menu-button", in: snapshot.text)
        #expect(snapshot.text.contains("ID: probe-button"))
        #expect(menuButtonIndex >= 0)

        try ProbeHarness.openProbeBWindowMenu(context)
        ProbeHarness.captureScreenAfterDelay(label: "popup-before-get-state", delay: 0.1)
        let popupState = try await getProbeBState(includeScreenshot: false, session: session)
        assertMenuSurface(popupState.text, containing: ["First Choice", "Second Choice"], label: "popup-get-state")
        try await pressEscape(session: session)

        ProbeHarness.pump(0.35)
        #expect(ProbeHarness.clicks("ProbeB") == baseline.clicks)
    }

    private func assertMenuSurface(_ state: String, containing fragments: [String], label: String) {
        let hasMenuSurface = state.contains(#"<app_state surface="menu">"#)
        let missingFragments = fragments.filter { !state.contains($0) }
        if !hasMenuSurface || !missingFragments.isEmpty {
            let diagnosticURL = ProbeHarness.captureFailureDiagnostic(label: label, state: state)
            Issue.record("""
            Menu surface assertion failed for \(label).
            Missing menu surface: \(!hasMenuSurface)
            Missing fragments: \(missingFragments.joined(separator: ", "))
            Diagnostic: \(diagnosticURL?.path ?? "unavailable")
            """)
        }
        #expect(hasMenuSurface)
        for fragment in fragments {
            #expect(state.contains(fragment))
        }
    }

    private func assertWindowSurface(
        _ state: String,
        containing fragments: [String],
        excluding excludedFragments: [String],
        label: String
    ) {
        let hasWindowSurface = state.contains(#"<app_state surface="window">"#)
        let missingFragments = fragments.filter { !state.contains($0) }
        let unexpectedFragments = excludedFragments.filter { state.contains($0) }
        if !hasWindowSurface || !missingFragments.isEmpty || !unexpectedFragments.isEmpty {
            let diagnosticURL = ProbeHarness.captureFailureDiagnostic(label: label, state: state)
            Issue.record("""
            Window surface assertion failed for \(label).
            Missing window surface: \(!hasWindowSurface)
            Missing fragments: \(missingFragments.joined(separator: ", "))
            Unexpected fragments: \(unexpectedFragments.joined(separator: ", "))
            Diagnostic: \(diagnosticURL?.path ?? "unavailable")
            """)
        }
        #expect(hasWindowSurface)
        for fragment in fragments {
            #expect(state.contains(fragment))
        }
        for fragment in excludedFragments {
            #expect(!state.contains(fragment))
        }
    }

    private func pressEscape(session: ComputerUseSession) async throws {
        _ = try await ComputerUseTestHarness.executeAction(
            action: "press-key",
            args: [
                "key": .string("Escape"),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )
        ProbeHarness.pump(0.2)
    }

    private func getProbeBState(includeScreenshot: Bool) async throws -> ComputerUseCommandOutput {
        try await getProbeState("B", includeScreenshot: includeScreenshot)
    }

    private func getProbeBState(
        includeScreenshot: Bool,
        session: ComputerUseSession
    ) async throws -> ComputerUseCommandOutput {
        try await getProbeState("B", includeScreenshot: includeScreenshot, session: session)
    }

    private func getProbeState(_ key: String, includeScreenshot: Bool) async throws -> ComputerUseCommandOutput {
        try await getProbeState(key, includeScreenshot: includeScreenshot, session: nil)
    }

    private func getProbeState(
        _ key: String,
        includeScreenshot: Bool,
        session: ComputerUseSession?
    ) async throws -> ComputerUseCommandOutput {
        try await ComputerUseTestHarness.executeAction(
            action: "get-app-state",
            args: [
                "app": .string("com.kwwk.activationprobe.\(key.lowercased())"),
                "window_title": .string("Probe\(key) AppKit Activation Probe"),
                "include_screenshot": .bool(includeScreenshot),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )
    }

    private func index(containingIdentifier identifier: String, in state: String) throws -> Int {
        do {
            return try index(containingAll: ["ID: \(identifier)"], in: state)
        } catch {
            return try index(containingAll: [identifier], in: state)
        }
    }

    private func index(containingAll fragments: [String], in state: String) throws -> Int {
        for rawLine in state.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard fragments.allSatisfy({ line.contains($0) }) else { continue }
            let token = line.split(separator: " ").first ?? ""
            if let value = Int(token) {
                return value
            }
        }
        _ = ProbeHarness.captureFailureDiagnostic(label: "missing-\(fragments.joined(separator: "-"))", state: state)
        throw ComputerUseError.invalidArgument("missing element containing \(fragments.joined(separator: ", "))")
    }

    private func screenshotCoordinate(
        screenPoint: CGPoint,
        windowFrame: CGRect,
        screenshotSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: ((screenPoint.x - windowFrame.minX) / windowFrame.width) * screenshotSize.width,
            y: ((screenPoint.y - windowFrame.minY) / windowFrame.height) * screenshotSize.height
        )
    }

    private func screenshotCoordinate(
        windowLocalPoint: CGPoint,
        windowFrame: CGRect,
        screenshotSize: CGSize
    ) -> CGPoint {
        screenshotCoordinate(
            screenPoint: CGPoint(
                x: windowFrame.minX + windowLocalPoint.x,
                y: windowFrame.maxY - windowLocalPoint.y
            ),
            windowFrame: windowFrame,
            screenshotSize: screenshotSize
        )
    }

    private func makeProbeSession() -> ComputerUseSession {
        let session = ComputerUseSession()
        session.visualEffectHook = AppKitComputerUseVisualEffects()
        return session
    }
}

private enum ProbeHarness {
    struct Context {
        let a: NSRunningApplication
        let b: NSRunningApplication
        let c: NSRunningApplication
        let ids: [String: Int]
    }

    struct Baseline {
        let stack: String
        let frontmost: String
        let cursor: CGPoint
        let clicks: Int
    }

    private static let root = URL(fileURLWithPath: "/private/tmp/kwwk-activation-probe", isDirectory: true)
    private static let bundles = [
        "A": ("com.kwwk.activationprobe.a", root.appendingPathComponent("ProbeA.app", isDirectory: true)),
        "B": ("com.kwwk.activationprobe.b", root.appendingPathComponent("ProbeB.app", isDirectory: true)),
        "C": ("com.kwwk.activationprobe.c", root.appendingPathComponent("ProbeC.app", isDirectory: true)),
    ]
    private static let countdownState = CountdownState()

    private final class AXElementBox: @unchecked Sendable {
        let element: AXUIElement

        init(_ element: AXUIElement) {
            self.element = element
        }
    }

    private final class CountdownState: @unchecked Sendable {
        private let lock = NSLock()
        private var didShow = false

        func shouldShow() -> Bool {
            lock.withLock {
                guard didShow == false else {
                    return false
                }
                didShow = true
                return true
            }
        }
    }

    static func bundleExists(_ key: String) -> Bool {
        guard let url = bundles[key]?.1 else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func showCountdownIfNeeded(seconds: Int = 5) {
        guard countdownState.shouldShow() else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                showCountdown(seconds: seconds)
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    showCountdown(seconds: seconds)
                }
            }
        }
    }

    static func cleanup() {
        terminateAll()
    }

    static func captureFailureDiagnostic(label: String, state: String) -> URL? {
        let directory = URL(fileURLWithPath: "/private/tmp/kwwk-computer-use-core-gui-failures", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            let safeLabel = label.map { character in
                character.isLetter || character.isNumber || character == "-" ? character : "-"
            }
            let stem = "\(timestamp)-\(String(safeLabel))"
            let stateURL = directory.appendingPathComponent("\(stem).txt")
            try state.write(to: stateURL, atomically: true, encoding: .utf8)

            let windowsURL = directory.appendingPathComponent("\(stem).windows.txt")
            try windowListDiagnostic().write(to: windowsURL, atomically: true, encoding: .utf8)

            if let image = CGDisplayCreateImage(CGMainDisplayID()) {
                let imageURL = directory.appendingPathComponent("\(stem).png")
                let bitmap = NSBitmapImageRep(cgImage: image)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: imageURL, options: .atomic)
                }
            }

            return directory
        } catch {
            Issue.record("Failed to write GUI failure diagnostic for \(label): \(error)")
            return nil
        }
    }

    static func captureScreenAfterDelay(label: String, delay: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            _ = captureFailureDiagnostic(label: label, state: "screen captured during \(label)")
        }
    }

    private static func windowListDiagnostic() -> String {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return "CGWindowListCopyWindowInfo failed"
        }

        return windows.enumerated().map { index, window in
            let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
            let pid = window[kCGWindowOwnerPID as String] as? Int ?? 0
            let name = window[kCGWindowName as String] as? String ?? ""
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let number = window[kCGWindowNumber as String] as? Int ?? 0
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 0
            let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let x = bounds["X"] ?? 0
            let y = bounds["Y"] ?? 0
            let width = bounds["Width"] ?? 0
            let height = bounds["Height"] ?? 0
            return "#\(index) id=\(number) layer=\(layer) alpha=\(alpha) pid=\(pid) owner=\(owner) name=\(name) bounds=(\(x),\(y),\(width),\(height))"
        }.joined(separator: "\n")
    }

    @MainActor
    private static func showCountdown(seconds: Int) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "KWWK Computer Use GUI Tests"
        panel.level = .modalPanel
        panel.isReleasedWhenClosed = false

        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.font = .systemFont(ofSize: 17, weight: .medium)
        label.frame = NSRect(x: 24, y: 46, width: 372, height: 58)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        panel.contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView?.addSubview(label)

        panel.center()
        app.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()

        for remaining in stride(from: max(seconds, 1), through: 1, by: -1) {
            label.stringValue = "GUI probe tests will control the mouse and app focus.\nDo not use this computer.\nStarting in \(remaining)..."
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        panel.close()
    }

    static func reset() throws -> Context {
        terminateAll()
        try launch("B")
        pump(0.25)
        try launch("C")
        pump(0.25)
        try launch("A")
        pump(0.45)
        guard let a = app("A"), let b = app("B"), let c = app("C") else {
            throw ComputerUseError.invalidArgument("Probe apps did not launch")
        }
        try setFront(a.processIdentifier)
        pump(0.35)
        let windowIDB = try windowID(pid: b.processIdentifier)
        return Context(
            a: a,
            b: b,
            c: c,
            ids: [
                "A": try windowID(pid: a.processIdentifier),
                "B": windowIDB,
                "C": try windowID(pid: c.processIdentifier),
            ]
        )
    }

    static func captureBaseline(_ context: Context) -> Baseline {
        Baseline(
            stack: stack(ids: context.ids),
            frontmost: frontmost(),
            cursor: CGEvent(source: nil)?.location ?? .zero,
            clicks: clicks()
        )
    }

    static func expectInvariant(
        baseline: Baseline,
        context: Context,
        expectedClicks: Int
    ) throws {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline,
              (frontmost() != baseline.frontmost || clicks() != expectedClicks) {
            pump(0.05)
        }

        let currentState = lastState("ProbeB") ?? ""
        #expect(Set(stack(ids: context.ids).split(separator: ">")) == Set(baseline.stack.split(separator: ">")))
        #expect(frontmost() == baseline.frontmost)
        #expect(distance(CGEvent(source: nil)?.location ?? .zero, baseline.cursor) <= 1)
        #expect(clicks() == expectedClicks)
        #expect(currentState.contains("isActive=true"))
        #expect(currentState.contains("isKey=true"))
        #expect(currentState.contains("isMain=true"))
        #expect(currentState.contains("front=ProbeA"))
    }

    static func findElement(
        inProbeB context: Context,
        matches: (AXUIElement) -> Bool
    ) throws -> AXUIElement {
        try findElement(root: firstWindow(of: AXUIElementCreateApplication(context.b.processIdentifier)), matches: matches)
    }

    static func openProbeBWindowMenu(_ context: Context) throws {
        try setFront(context.b.processIdentifier)
        pump(0.2)
        let button = try findElement(inProbeB: context) {
            axString($0, kAXIdentifierAttribute as String) == "probe-menu-button"
        }
        let box = AXElementBox(button)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = AXUIElementPerformAction(box.element, kAXPressAction as CFString)
        }
        guard waitForTransientMenuWindow(pid: context.b.processIdentifier, timeout: 2.0) != nil else {
            _ = captureFailureDiagnostic(label: "popup-open-timeout", state: logText("ProbeB"))
            throw ComputerUseError.invalidArgument("ProbeB transient menu window did not appear")
        }
    }

    static func axFrame(_ element: AXUIElement) throws -> CGRect {
        guard let rawPosition = rawAttribute(element, kAXPositionAttribute as String),
              let rawSize = rawAttribute(element, kAXSizeAttribute as String)
        else {
            throw ComputerUseError.invalidArgument("missing AX frame")
        }
        guard let position = axValue(rawPosition),
              let size = axValue(rawSize)
        else {
            throw ComputerUseError.invalidArgument("invalid AX frame")
        }
        var point = CGPoint.zero
        var cgSize = CGSize.zero
        AXValueGetValue(position, .cgPoint, &point)
        AXValueGetValue(size, .cgSize, &cgSize)
        return CGRect(origin: point, size: cgSize)
    }

    static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        rawAttribute(element, attribute) as? String
    }

    static func logText(_ appName: String) -> String {
        (try? String(
            contentsOf: URL(fileURLWithPath: "/private/tmp/\(appName).activation.log"),
            encoding: .utf8
        )) ?? ""
    }

    static func latestLoggedPoint(in logText: String, prefix: String) -> CGPoint? {
        for line in logText.split(separator: "\n").reversed() {
            guard line.contains(prefix),
                  let start = line.range(of: "loc=(")?.upperBound,
                  let end = line[start...].firstIndex(of: ")")
            else {
                continue
            }
            let coordinates = line[start ..< end].split(separator: ",")
            guard coordinates.count == 2,
                  let x = Double(coordinates[0]),
                  let y = Double(coordinates[1])
            else {
                continue
            }
            return CGPoint(x: x, y: y)
        }
        return nil
    }

    static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    static func waitForTransientMenuWindow(pid: pid_t, timeout: TimeInterval) -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = transientMenuWindowFrame(pid: pid) {
                return frame
            }
            pump(0.03)
        }
        return nil
    }

    private static func transientMenuWindowFrame(pid: pid_t) -> CGRect? {
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

    private static func terminateAll() {
        for (_, (bundleID, _)) in bundles {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                app.terminate()
            }
        }
        pump(0.8)
        for (_, (bundleID, _)) in bundles {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                app.forceTerminate()
            }
        }
        pump(0.15)
    }

    private static func launch(_ key: String) throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let semaphore = DispatchSemaphore(value: 0)
        final class LaunchResultBox: @unchecked Sendable {
            let lock = NSLock()
            var error: Error?
        }
        let box = LaunchResultBox()
        NSWorkspace.shared.openApplication(at: bundles[key]!.1, configuration: config) { _, error in
            box.lock.withLock {
                box.error = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        let error = box.lock.withLock { box.error }
        if let error {
            throw error
        }
    }

    private static func app(_ key: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundles[key]!.0).first
    }

    private static func setFront(_ pid: pid_t) throws {
        var psn = ProcessSerialNumber()
        guard testGetProcessForPID(pid, &psn) == noErr else {
            throw ComputerUseError.invalidArgument("failed to resolve process serial number")
        }
        _ = testSetFrontProcessWithOptions(&psn, UInt32(kSetFrontProcessFrontWindowOnly | kSetFrontProcessCausedByUser))
    }

    private static func firstWindow(of app: AXUIElement) throws -> AXUIElement {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement], let window = windows.first else {
            throw ComputerUseError.invalidArgument("failed to resolve ProbeB window")
        }
        return window
    }

    private static func findElement(
        root: AXUIElement,
        matches: (AXUIElement) -> Bool
    ) throws -> AXUIElement {
        if matches(root) {
            return root
        }
        for attribute in [kAXChildrenAttribute as String, kAXContentsAttribute as String] {
            guard let rawValue = rawAttribute(root, attribute) else { continue }
            if let children = rawValue as? [AXUIElement] {
                for child in children {
                    if let found = try? findElement(root: child, matches: matches) {
                        return found
                    }
                }
            } else {
                guard let child = axElement(rawValue) else {
                    continue
                }
                if let found = try? findElement(root: child, matches: matches) {
                    return found
                }
            }
        }
        throw ComputerUseError.invalidArgument("failed to find AX element")
    }

    private static func rawAttribute(_ element: AXUIElement, _ attribute: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func axValue(_ value: Any) -> AXValue? {
        guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else {
            return nil
        }
        return (value as! AXValue)
    }

    private static func axElement(_ value: Any) -> AXUIElement? {
        guard CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func windowID(pid: pid_t) throws -> Int {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw ComputerUseError.invalidArgument("failed to read CG windows")
        }
        for window in windows where
            (window[kCGWindowOwnerPID as String] as? pid_t) == pid &&
            (window[kCGWindowLayer as String] as? Int) == 0 {
            if let id = window[kCGWindowNumber as String] as? Int {
                return id
            }
        }
        throw ComputerUseError.invalidArgument("failed to find Probe window id")
    }

    static func stack(ids: [String: Int]) -> String {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return "unavailable"
        }
        var order: [String] = []
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0 else { continue }
            let id = window[kCGWindowNumber as String] as? Int ?? 0
            for (key, target) in ids where target == id {
                order.append(key)
            }
        }
        return order.joined(separator: ">")
    }

    static func frontmost() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "nil" }
        return "\(app.localizedName ?? "?"):\(app.processIdentifier)"
    }

    static func clicks(_ appName: String = "ProbeB") -> Int {
        guard let state = lastState(appName),
              let match = state.split(separator: " ").first(where: { $0.hasPrefix("clicks=") }),
              let value = Int(match.dropFirst("clicks=".count))
        else {
            return 0
        }
        return value
    }

    static func lastState(_ appName: String) -> String? {
        let url = URL(fileURLWithPath: "/private/tmp/\(appName).activation.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let line = text.split(separator: "\n").reversed().first(where: { $0.contains("isActive=") }),
              let range = line.range(of: "isActive=")
        else {
            return nil
        }
        return String(line[range.lowerBound...])
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
