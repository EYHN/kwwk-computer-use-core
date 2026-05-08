@preconcurrency import AppKit
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
    private var glow = WindowGlowOverlay()
    private var pointer = VirtualPointerOverlay()

    public init() {}

    public func perform<T>(
        _ event: ComputerUseVisualEffectEvent,
        action: () throws -> T
    ) throws -> T {
        runOnMain {
            self.glow.attach(toWindowID: event.windowID, fallbackAXFrame: event.windowFrame.cgRect)
            self.pointer.animate(for: event)
        }

        let result = try action()

        runOnMain {
            self.pointer.holdBriefly()
        }
        return result
    }

    public func finish() {
        runOnMain {
            self.pointer.tearDown()
            self.glow.tearDown()
        }
    }

    private func runOnMain(_ body: @MainActor @escaping () -> Void) {
        lock.withLock {
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    body()
                }
            } else {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        body()
                    }
                }
            }
        }
    }
}

@MainActor
private final class WindowGlowOverlay {
    private var panel: NSPanel?
    private var view: WindowGlowView?

    func attach(toWindowID windowID: Int, fallbackAXFrame: CGRect) {
        ensurePanel()
        guard let panel, let view else { return }

        let axFrame = windowBounds(windowID: windowID) ?? fallbackAXFrame
        let appKitFrame = appKitRect(fromAXRect: axFrame).insetBy(dx: -6, dy: -6)
        view.cornerRadius = 14
        panel.setFrame(appKitFrame, display: true)
        panel.alphaValue = 1
        panel.order(.above, relativeTo: windowID)
        view.needsDisplay = true
    }

    func tearDown() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        view = nil
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let view = WindowGlowView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let panel = NSPanel(
            contentRect: view.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = view
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.panel = panel
        self.view = view
    }

    private func windowBounds(windowID: Int) -> CGRect? {
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            CGWindowID(windowID)
        ) as? [[String: Any]],
            let info = infos.first,
            let bounds = info[kCGWindowBounds as String] as? [String: Any],
            let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else {
            return nil
        }
        return rect
    }
}

@MainActor
private final class WindowGlowView: NSView {
    var cornerRadius: CGFloat = 14

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 8, dy: 8)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.systemTeal.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 3
        path.stroke()

        NSGraphicsContext.saveGraphicsState()
        NSShadow().apply {
            $0.shadowBlurRadius = 18
            $0.shadowColor = NSColor.systemTeal.withAlphaComponent(0.45)
            $0.shadowOffset = .zero
        }
        NSColor.systemTeal.withAlphaComponent(0.32).setStroke()
        path.lineWidth = 5
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor
private final class VirtualPointerOverlay {
    private var panel: NSPanel?
    private var view: VirtualPointerView?
    private var currentPoint: CGPoint?

    func animate(for event: ComputerUseVisualEffectEvent) {
        guard let destination = primaryPoint(for: event) else {
            holdBriefly()
            return
        }
        ensurePanel()
        guard let panel else { return }

        let start = currentPoint ?? CGPoint(
            x: destination.x - 120,
            y: destination.y + 80
        )
        let duration = event.action == .targetWindow ? 0.12 : 0.26
        let steps = max(1, Int(duration / 0.012))
        for step in 0 ... steps {
            let t = CGFloat(step) / CGFloat(steps)
            let eased = 1 - pow(1 - t, 3)
            let point = CGPoint(
                x: start.x + ((destination.x - start.x) * eased),
                y: start.y + ((destination.y - start.y) * eased)
            )
            movePanel(panel, to: point)
            pumpRunLoop(for: 0.012)
        }

        if let endPoint = event.endPoint?.cgPoint {
            let endDestination = appKitScreenPoint(
                fromWindowLocal: Point<WindowLocalSpace>(endPoint),
                windowFrame: event.windowFrame.cgRect
            ).cgPoint
            animateLine(from: destination, to: endDestination, duration: 0.18)
        }
        currentPoint = event.endPoint.map {
            appKitScreenPoint(
                fromWindowLocal: Point<WindowLocalSpace>($0.cgPoint),
                windowFrame: event.windowFrame.cgRect
            ).cgPoint
        } ?? destination
    }

    func holdBriefly() {
        pumpRunLoop(for: 0.05)
    }

    func tearDown() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        view = nil
        currentPoint = nil
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let view = VirtualPointerView(frame: CGRect(x: 0, y: 0, width: 34, height: 34))
        let panel = NSPanel(
            contentRect: view.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = view
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.orderFrontRegardless()
        self.panel = panel
        self.view = view
    }

    private func primaryPoint(for event: ComputerUseVisualEffectEvent) -> CGPoint? {
        guard let point = event.startPoint?.cgPoint else {
            return appKitRect(fromAXRect: event.windowFrame.cgRect).center
        }
        return appKitScreenPoint(
            fromWindowLocal: Point<WindowLocalSpace>(point),
            windowFrame: event.windowFrame.cgRect
        ).cgPoint
    }

    private func animateLine(from start: CGPoint, to end: CGPoint, duration: TimeInterval) {
        guard let panel else { return }
        let steps = max(1, Int(duration / 0.012))
        for step in 1 ... steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(
                x: start.x + ((end.x - start.x) * t),
                y: start.y + ((end.y - start.y) * t)
            )
            movePanel(panel, to: point)
            pumpRunLoop(for: 0.012)
        }
    }

    private func movePanel(_ panel: NSPanel, to point: CGPoint) {
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(x: point.x - 3, y: point.y - size.height + 3))
        panel.orderFrontRegardless()
        view?.needsDisplay = true
    }
}

private final class VirtualPointerView: NSView {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 4, y: 30))
        path.line(to: CGPoint(x: 4, y: 3))
        path.line(to: CGPoint(x: 24, y: 21))
        path.line(to: CGPoint(x: 14, y: 22))
        path.line(to: CGPoint(x: 20, y: 33))
        path.line(to: CGPoint(x: 15, y: 34))
        path.line(to: CGPoint(x: 10, y: 23))
        path.close()

        NSColor.white.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.8).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}

private extension NSShadow {
    func apply(_ configure: (NSShadow) -> Void) {
        configure(self)
        set()
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private func appKitRect(fromAXRect rect: CGRect) -> CGRect {
    let topLeft = appKitScreenPoint(from: Point<AXScreenSpace>(CGPoint(x: rect.minX, y: rect.minY))).cgPoint
    let bottomRight = appKitScreenPoint(from: Point<AXScreenSpace>(CGPoint(x: rect.maxX, y: rect.maxY))).cgPoint
    return CGRect(
        x: topLeft.x,
        y: bottomRight.y,
        width: bottomRight.x - topLeft.x,
        height: topLeft.y - bottomRight.y
    )
}

private func pumpRunLoop(for duration: TimeInterval) {
    let end = Date().addingTimeInterval(duration)
    while Date() < end {
        RunLoop.current.run(mode: .default, before: min(end, Date().addingTimeInterval(0.004)))
        RunLoop.current.run(mode: .eventTracking, before: min(end, Date().addingTimeInterval(0.004)))
    }
}
