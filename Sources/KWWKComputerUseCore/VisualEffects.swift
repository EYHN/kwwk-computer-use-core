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
        try withoutActuallyEscaping(action) { escapableAction in
            let actionBox = VisualEffectActionBox(escapableAction)
            try runOnMain {
                self.ensureBorderOverlay().attach(toCGWindow: CGWindowID(event.windowID))

                switch event.action {
                case .drag:
                    try self.runDrag(event)
                case .click:
                    try self.runAction(event, kind: .click(button: .left))
                case .scroll:
                    try self.runAction(event, kind: .scroll(direction: event.detail ?? ""))
                case .accessibilityAction:
                    try self.runAction(event, kind: .accessibilityAction)
                case .keyboard, .targetWindow:
                    break
                }
            }
            return try actionBox.call()
        }
    }

    public func finish() {
        try? runOnMain {
            self.borderOverlay?.detach()
            self.borderOverlay = nil
            DaemonCursor.shared.tearDown()
        }
    }

    @MainActor
    private func ensureBorderOverlay() -> BorderOverlay {
        if let borderOverlay {
            return borderOverlay
        }
        let borderOverlay = BorderOverlay()
        self.borderOverlay = borderOverlay
        return borderOverlay
    }

    @MainActor
    private func runAction(
        _ event: ComputerUseVisualEffectEvent,
        kind: ActionOverlayKind
    ) throws {
        try DaemonCursor.shared.runApproachThenAction(
            kind: kind,
            target: target(for: event),
            fallbackScreenPoint: screenPoint(for: event.startPoint, windowFrame: event.windowFrame.cgRect),
            fallbackWindowFrame: event.windowFrame.cgRect,
            tracking: tracking(for: event)
        ) {
            // The actual computer-use action runs after this method returns, on
            // the caller's background executor. Keep the main thread dedicated
            // to the visual cursor animation.
        }
    }

    @MainActor
    private func runDrag(_ event: ComputerUseVisualEffectEvent) throws {
        let start = screenPoint(for: event.startPoint, windowFrame: event.windowFrame.cgRect)
        let end = screenPoint(for: event.endPoint ?? event.startPoint, windowFrame: event.windowFrame.cgRect)
        try DaemonCursor.shared.runApproachThenDrag(
            button: .left,
            target: target(for: event),
            startScreenPoint: start,
            endScreenPoint: end,
            fallbackWindowFrame: event.windowFrame.cgRect,
            approachTracking: tracking(for: event),
            onDragDown: {
                // The real drag runs after this visual pass on the background
                // executor, so UI animation never pulls AX/CG work onto main.
            },
            onDragMove: { _, _ in },
            onDragUp: { _ in }
        )
    }

    @MainActor
    private func target(for event: ComputerUseVisualEffectEvent) -> CursorAnchor {
        .window(number: event.windowID, layer: Int(CGWindowLevelForKey(.normalWindow)))
    }

    @MainActor
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

    @MainActor
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

    private func runOnMain<T>(_ body: @MainActor () throws -> T) throws -> T {
        try lock.withLock {
            try withoutActuallyEscaping(body) { escapable in
                if Thread.isMainThread {
                    let unchecked = unsafeBitCast(escapable, to: (() throws -> T).self)
                    return try unchecked()
                } else {
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
    private let body: @MainActor () throws -> T
    var result: Result<T, Error>?

    init(_ body: @escaping @MainActor () throws -> T) {
        self.body = body
    }

    func run() {
        let unchecked = unsafeBitCast(body, to: (() throws -> T).self)
        result = Result { try unchecked() }
    }
}

private final class VisualEffectActionBox<T>: @unchecked Sendable {
    private let action: () throws -> T

    init(_ action: @escaping () throws -> T) {
        self.action = action
    }

    func call() throws -> T {
        try action()
    }
}
