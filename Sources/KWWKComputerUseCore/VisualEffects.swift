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

public enum ComputerUseVisualEffectSurfaceKind: String, Codable, Equatable, Sendable {
    case window
    case status
    case menu
}

extension ComputerUseVisualEffectSurfaceKind {
    init(_ runtimeKind: RuntimeSurfaceKind) {
        switch runtimeKind {
        case .window:
            self = .window
        case .status:
            self = .status
        case .menu:
            self = .menu
        }
    }
}

public struct ComputerUseVisualEffectEvent: Codable, Equatable, Sendable {
    public var action: ComputerUseVisualEffectAction
    public var surfaceKind: ComputerUseVisualEffectSurfaceKind
    public var windowID: Int
    public var windowFrame: CGRectCodable
    public var startPoint: CGPointCodable?
    public var endPoint: CGPointCodable?
    public var detail: String?

    public init(
        action: ComputerUseVisualEffectAction,
        surfaceKind: ComputerUseVisualEffectSurfaceKind = .window,
        windowID: Int,
        windowFrame: CGRectCodable,
        startPoint: CGPointCodable? = nil,
        endPoint: CGPointCodable? = nil,
        detail: String? = nil
    ) {
        self.action = action
        self.surfaceKind = surfaceKind
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
    private var borderOverlay: BorderOverlay?

    public init() {}

    public func perform<T>(
        _ event: ComputerUseVisualEffectEvent,
        action: () throws -> T
    ) throws -> T {
        try withoutActuallyEscaping(action) { escapableAction in
            let actionBox = VisualEffectActionBox(escapableAction)
            switch event.action {
            case .drag:
                try runOnMain {
                    self.attachOverlay(for: event)
                    try self.runDrag(event)
                }
                return try actionBox.call()
            case .click:
                return try runActionAfterApproach(event, kind: .click(button: .left), actionBox: actionBox)
            case .scroll:
                return try runActionAfterApproach(event, kind: .scroll(direction: event.detail ?? ""), actionBox: actionBox)
            case .accessibilityAction:
                return try runActionAfterApproach(event, kind: .accessibilityAction, actionBox: actionBox)
            case .targetWindow:
                return try runActionAfterApproach(event, kind: .accessibilityAction, actionBox: actionBox)
            case .keyboard:
                try runOnMain {
                    self.attachOverlay(for: event)
                }
                return try actionBox.call()
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
    private func attachOverlay(for event: ComputerUseVisualEffectEvent) {
        guard event.surfaceKind == .window else {
            borderOverlay?.detach()
            return
        }
        ensureBorderOverlay().attach(toCGWindow: CGWindowID(event.windowID))
    }

    private func runActionAfterApproach<T>(
        _ event: ComputerUseVisualEffectEvent,
        kind: ActionOverlayKind,
        actionBox: VisualEffectActionBox<T>
    ) throws -> T {
        try runOnMain {
            self.attachOverlay(for: event)
            try self.runActionApproach(event, kind: kind)
        }

        do {
            let result = try actionBox.call()
            try runOnMain {
                DaemonCursor.shared.holdAfterAction()
            }
            return result
        } catch {
            try? runOnMain {
                DaemonCursor.shared.holdAfterAction()
            }
            throw error
        }
    }

    @MainActor
    private func runActionApproach(
        _ event: ComputerUseVisualEffectEvent,
        kind: ActionOverlayKind
    ) throws {
        try DaemonCursor.shared.runApproachToActionTarget(
            kind: kind,
            target: target(for: event),
            fallbackScreenPoint: screenPoint(for: event.startPoint, windowFrame: event.windowFrame.cgRect),
            fallbackWindowFrame: event.windowFrame.cgRect,
            tracking: tracking(for: event)
        )
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
