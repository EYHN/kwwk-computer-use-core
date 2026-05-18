import CoreGraphics
import Darwin
import Foundation

enum BackgroundWindowLocalEvent {
    private typealias SetWindowLocationFn = @convention(c) (CGEvent, CGPoint) -> Void

    private static let setWindowLocation: SetWindowLocationFn? = {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetWindowLocationFn.self)
    }()

    @discardableResult
    static func setPoint(_ point: CGPoint, on event: CGEvent) -> Bool {
        guard let setWindowLocation else { return false }
        setWindowLocation(event, point)
        return true
    }
}
