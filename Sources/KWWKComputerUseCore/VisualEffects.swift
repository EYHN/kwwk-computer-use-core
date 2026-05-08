import CoreGraphics
import Foundation

public enum ComputerUseVisualEffectAction: String, Codable, Equatable, Sendable {
    case targetWindow
    case click
    case scroll
    case drag
    case keyboard
    case accessibilityAction
}

public struct ComputerUseVisualEffectEvent: Codable, Equatable, Sendable {
    public var action: ComputerUseVisualEffectAction
    public var windowID: Int
    public var windowFrame: CGRectCodable
    public var startPoint: CGPointCodable?
    public var endPoint: CGPointCodable?
    public var detail: String?

    public init(
        action: ComputerUseVisualEffectAction,
        windowID: Int,
        windowFrame: CGRectCodable,
        startPoint: CGPointCodable? = nil,
        endPoint: CGPointCodable? = nil,
        detail: String? = nil
    ) {
        self.action = action
        self.windowID = windowID
        self.windowFrame = windowFrame
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.detail = detail
    }
}

public protocol ComputerUseVisualEffectHook: AnyObject {
    func perform<T>(
        _ event: ComputerUseVisualEffectEvent,
        action: () throws -> T
    ) throws -> T

    func finish()
}

public final class AppKitComputerUseVisualEffects: ComputerUseVisualEffectHook, @unchecked Sendable {
    private let lock = NSLock()
    private var borderOverlay: BorderOverlay?

    public init() {}

    public func perform<T>(
        _ event: ComputerUseVisualEffectEvent,
        action: () throws -> T
    ) throws -> T {
        try runOnMain {
            self.ensureBorderOverlay().attach(toCGWindow: CGWindowID(event.windowID))

            switch event.action {
            case .drag:
                return try self.runDrag(event, action: action)
            case .click:
                return try self.runAction(event, kind: .click(button: .left), action: action)
            case .scroll:
                return try self.runAction(event, kind: .scroll(direction: event.detail ?? ""), action: action)
            case .accessibilityAction:
                return try self.runAction(event, kind: .accessibilityAction, action: action)
            case .keyboard, .targetWindow:
                return try action()
            }
        }
    }

    public func finish() {
        try? runOnMain {
            self.borderOverlay?.detach()
            self.borderOverlay = nil
            DaemonCursor.shared.tearDown()
        }
    }

    private func ensureBorderOverlay() -> BorderOverlay {
        if let borderOverlay {
            return borderOverlay
        }
        let borderOverlay = BorderOverlay()
        self.borderOverlay = borderOverlay
        return borderOverlay
    }

    private func runAction<T>(
        _ event: ComputerUseVisualEffectEvent,
        kind: ActionOverlayKind,
        action: () throws -> T
    ) throws -> T {
        var output: Result<T, Error>?
        try DaemonCursor.shared.runApproachThenAction(
            kind: kind,
            target: target(for: event),
            fallbackScreenPoint: screenPoint(for: event.startPoint, windowFrame: event.windowFrame.cgRect),
            fallbackWindowFrame: event.windowFrame.cgRect,
            tracking: tracking(for: event)
        ) {
            output = Result { try action() }
        }
        return try output?.get() ?? action()
    }

    private func runDrag<T>(
        _ event: ComputerUseVisualEffectEvent,
        action: () throws -> T
    ) throws -> T {
        let start = screenPoint(for: event.startPoint, windowFrame: event.windowFrame.cgRect)
        let end = screenPoint(for: event.endPoint ?? event.startPoint, windowFrame: event.windowFrame.cgRect)
        var output: Result<T, Error>?
        try DaemonCursor.shared.runApproachThenDrag(
            button: .left,
            target: target(for: event),
            startScreenPoint: start,
            endScreenPoint: end,
            fallbackWindowFrame: event.windowFrame.cgRect,
            approachTracking: tracking(for: event),
            onDragDown: {
                output = Result { try action() }
            },
            onDragMove: { _, _ in },
            onDragUp: { _ in }
        )
        return try output?.get() ?? action()
    }

    private func target(for event: ComputerUseVisualEffectEvent) -> CursorAnchor {
        .window(number: event.windowID, layer: Int(CGWindowLevelForKey(.normalWindow)))
    }

    private func tracking(for event: ComputerUseVisualEffectEvent) -> ActionOverlayTracking {
        windowLocalPointOverlayTracking(
            target: target(for: event),
            fallbackWindowFrame: event.windowFrame.cgRect
        ) {
            event.startPoint?.cgPoint ?? CGPoint(
                x: event.windowFrame.cgRect.width / 2,
                y: event.windowFrame.cgRect.height / 2
            )
        }
    }

    private func screenPoint(
        for point: CGPointCodable?,
        windowFrame: CGRect
    ) -> CGPoint {
        appKitScreenPoint(
            fromWindowLocal: Point<WindowLocalSpace>(
                point?.cgPoint ?? CGPoint(x: windowFrame.width / 2, y: windowFrame.height / 2)
            ),
            windowFrame: windowFrame
        ).cgPoint
    }

    private func runOnMain<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            if Thread.isMainThread {
                return try body()
            } else {
                return try withoutActuallyEscaping(body) { escapable in
                    let operation = MainSyncOperation(escapable)
                    DispatchQueue.main.sync {
                        operation.run()
                    }
                    return try operation.result!.get()
                }
            }
        }
    }
}

private final class MainSyncOperation<T>: @unchecked Sendable {
    private let body: () throws -> T
    var result: Result<T, Error>?

    init(_ body: @escaping () throws -> T) {
        self.body = body
    }

    func run() {
        result = Result { try body() }
    }
}
