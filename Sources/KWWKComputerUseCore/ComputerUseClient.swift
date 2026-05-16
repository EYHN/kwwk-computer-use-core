import Foundation

/// Product-facing facade for macOS computer-use actions.
///
/// Keep one client alive for a related sequence of actions so background
/// activation and focus suppression state can be reused across calls. Call
/// `finish()` when the interaction sequence is complete.
public final class ComputerUseClient: @unchecked Sendable {
    /// Shared action session used for background activation and action history.
    public let session: ComputerUseSession

    /// Screenshot compression policy used by state and post-action captures.
    public var screenshotCompression: ComputerUseScreenshotCompression

    public init(
        session: ComputerUseSession = ComputerUseSession(),
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault
    ) {
        self.session = session
        self.screenshotCompression = screenshotCompression
    }

    deinit {
        finish()
    }

    /// Restores any background activation state held by the session.
    public func finish() {
        session.finish()
    }

    /// Returns an agent-facing formatted list of installed and running apps.
    public func listApps() -> ComputerUseCommandOutput {
        ComputerUseAction.listApps()
    }

    /// Returns structured installed and running app descriptors.
    public func apps() -> [ComputerUseAppDescriptor] {
        ComputerUseCore.listApps()
    }

    /// Returns structured descriptors for currently running GUI apps.
    public func runningApps() -> [RunningAppDescriptor] {
        ComputerUseCore.listRunningApps()
    }

    /// Opens an app by bundle identifier, exact name, partial name, or `.app` path.
    ///
    /// The app is launched without forcing foreground activation when possible.
    public func openApp(_ appIdentifier: String) async throws -> ComputerUseCommandOutput {
        try await ComputerUseAction.openApp(appIdentifier: appIdentifier)
    }

    /// Returns an agent-facing formatted list of readable windows for an app.
    public func listWindows(app appIdentifier: String) throws -> ComputerUseCommandOutput {
        try ComputerUseAction.listWindows(appIdentifier: appIdentifier)
    }

    /// Returns structured readable windows for a running app.
    public func windows(app appIdentifier: String) throws -> [ComputerUseWindowDescriptor] {
        try ComputerUseCore.listWindows(appIdentifier: appIdentifier)
    }

    /// Captures an app state snapshot formatted for agent prompts.
    ///
    /// The captured state becomes this client's latest snapshot for follow-up actions.
    public func getAppState(
        app appIdentifier: String,
        windowTitle: String? = nil,
        includeScreenshot: Bool = false
    ) throws -> ComputerUseCommandOutput {
        try ComputerUseAction.getAppState(
            appIdentifier: appIdentifier,
            windowTitle: windowTitle,
            includeScreenshot: includeScreenshot,
            session: session,
            screenshotCompression: screenshotCompression
        )
    }

    /// Captures an app state snapshot as structured data.
    ///
    /// Prefer this for product integrations that should not parse formatted
    /// prompt text. The captured state becomes this client's latest snapshot.
    public func state(
        app appIdentifier: String,
        windowTitle: String? = nil,
        includeScreenshot: Bool = false
    ) throws -> ComputerUseState {
        try ComputerUseAction.getStructuredAppState(
            appIdentifier: appIdentifier,
            windowTitle: windowTitle,
            includeScreenshot: includeScreenshot,
            session: session,
            screenshotCompression: screenshotCompression
        )
    }

    /// Clicks an element from the latest captured snapshot.
    public func click(
        elementIndex: Int,
        includeScreenshotAfter: Bool = false
    ) async throws -> ComputerUseCommandOutput {
        try await ComputerUseAction.click(
            elementIndex: elementIndex,
            x: nil,
            y: nil,
            includeScreenshotAfter: includeScreenshotAfter,
            session: session,
            screenshotCompression: screenshotCompression
        )
    }

    /// Clicks a screenshot pixel coordinate from the latest screenshot-backed snapshot.
    ///
    /// Coordinate clicks require the snapshot to have been captured with
    /// `includeScreenshot: true`.
    public func click(
        x: Double,
        y: Double,
        includeScreenshotAfter: Bool = false
    ) async throws -> ComputerUseCommandOutput {
        try await ComputerUseAction.click(
            elementIndex: nil,
            x: x,
            y: y,
            includeScreenshotAfter: includeScreenshotAfter,
            session: session,
            screenshotCompression: screenshotCompression
        )
    }

    /// Types text into an explicit editable element or the focused editable element.
    public func typeText(
        text: String,
        elementIndex: Int? = nil,
        includeScreenshotAfter: Bool = false
    ) async throws -> ComputerUseCommandOutput {
        try await ComputerUseAction.typeText(
            text: text,
            elementIndex: elementIndex,
            includeScreenshotAfter: includeScreenshotAfter,
            session: session,
            screenshotCompression: screenshotCompression
        )
    }

    /// Sets `AXValue` on a value-settable element.
    public func setValue(
        elementIndex: Int,
        value: String,
        includeScreenshotAfter: Bool = false
    ) async throws -> ComputerUseCommandOutput {
        try await ComputerUseAction.setValue(
            elementIndex: elementIndex,
            value: value,
            includeScreenshotAfter: includeScreenshotAfter,
            session: session,
            screenshotCompression: screenshotCompression
        )
    }

    /// Sends a key or key combination to the snapshot target.
    public func pressKey(
        key: String,
        includeScreenshotAfter: Bool = false
    ) async throws -> ComputerUseCommandOutput {
        try await ComputerUseAction.pressKey(
            key: key,
            includeScreenshotAfter: includeScreenshotAfter,
            session: session,
            screenshotCompression: screenshotCompression
        )
    }

    /// Scrolls from an element using AX scrolling when available, with wheel fallback.
    public func scroll(
        elementIndex: Int,
        direction: String,
        pages: Double = 1,
        includeScreenshotAfter: Bool = false
    ) async throws -> ComputerUseCommandOutput {
        try await ComputerUseAction.scroll(
            elementIndex: elementIndex,
            direction: direction,
            pages: pages,
            includeScreenshotAfter: includeScreenshotAfter,
            session: session,
            screenshotCompression: screenshotCompression
        )
    }

    /// Performs a secondary AX action by raw action name or display action name.
    public func performSecondaryAction(
        elementIndex: Int,
        action: String,
        includeScreenshotAfter: Bool = false
    ) async throws -> ComputerUseCommandOutput {
        try await ComputerUseAction.performSecondaryAction(
            elementIndex: elementIndex,
            action: action,
            includeScreenshotAfter: includeScreenshotAfter,
            session: session,
            screenshotCompression: screenshotCompression
        )
    }

    /// Drags between two screenshot pixel coordinates from the latest screenshot-backed snapshot.
    ///
    /// Drag coordinates require the snapshot to have been captured with
    /// `includeScreenshot: true`.
    public func drag(
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        includeScreenshotAfter: Bool = false
    ) async throws -> ComputerUseCommandOutput {
        try await ComputerUseAction.drag(
            fromX: fromX,
            fromY: fromY,
            toX: toX,
            toY: toY,
            includeScreenshotAfter: includeScreenshotAfter,
            session: session,
            screenshotCompression: screenshotCompression
        )
    }
}
