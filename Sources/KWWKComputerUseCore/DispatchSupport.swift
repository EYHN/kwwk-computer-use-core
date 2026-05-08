import AppKit
import ApplicationServices
import Darwin
import Foundation

enum UIElementError: Error, CustomStringConvertible {
    case permissionDenied
    case synthesizedEventCreationFailed(type: String)
    case axError(AXError, action: String)

    var description: String {
        switch self {
        case .permissionDenied:
            "Accessibility permission is required for this process"
        case let .synthesizedEventCreationFailed(type):
            "synthesizedEventCreationFailed type=\(type)"
        case let .axError(error, action):
            "AXError(\(error.rawValue)) for action \(action)"
        }
    }
}

public enum MouseButton: String, Sendable, Equatable {
    case left
    case right
    case middle
}

func translatedWindowLocalPoint(
    screenPoint point: CGPoint,
    windowFrame: CGRect
) -> CGPoint {
    windowLocalPoint(
        fromAXScreen: Point<AXScreenSpace>(point),
        windowFrame: windowFrame
    ).cgPoint
}

func translatedWindowLocalPoint(
    fromAppKitScreenPoint point: CGPoint,
    windowFrame: CGRect
) -> CGPoint {
    windowLocalPoint(
        fromAppKitScreen: Point<AppKitScreenSpace>(point),
        windowFrame: windowFrame
    ).cgPoint
}

public func overlayScreenPointForLocalPoint(
    windowLocalPoint point: CGPoint,
    windowFrame: CGRect
) -> CGPoint {
    appKitScreenPoint(
        fromWindowLocal: Point<WindowLocalSpace>(point),
        windowFrame: windowFrame
    ).cgPoint
}

public func overlayScreenPointForAXFrame(_ frame: CGRect) -> CGPoint {
    appKitScreenPoint(
        from: Point<AXScreenSpace>(x: frame.midX, y: frame.midY)
    ).cgPoint
}
