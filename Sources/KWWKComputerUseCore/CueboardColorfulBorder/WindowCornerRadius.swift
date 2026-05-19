import AppKit
import CoreFoundation
import Darwin

// MARK: - SkyLight Private API for Window Corner Radii

private struct SkyLightWindowQuery {
    typealias MainConnectionIDFn = @convention(c) () -> Int32
    typealias WindowQueryWindowsFn = @convention(c) (Int32, CFArray, Int32) -> CFTypeRef?
    typealias WindowQueryResultCopyWindowsFn = @convention(c) (CFTypeRef) -> CFTypeRef?
    typealias WindowIteratorAdvanceFn = @convention(c) (CFTypeRef) -> Bool
    typealias WindowIteratorGetResolvedCornerRadiiFn = @convention(c) (CFTypeRef) -> CFArray?

    static let shared: SkyLightWindowQuery? = SkyLightWindowQuery()

    let mainConnectionID: MainConnectionIDFn
    let windowQueryWindows: WindowQueryWindowsFn
    let windowQueryResultCopyWindows: WindowQueryResultCopyWindowsFn
    let windowIteratorAdvance: WindowIteratorAdvanceFn
    let windowIteratorGetResolvedCornerRadii: WindowIteratorGetResolvedCornerRadiiFn

    init?() {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        guard
            let mainConnectionID = Self.load("SLSMainConnectionID", as: MainConnectionIDFn.self),
            let windowQueryWindows = Self.load("SLSWindowQueryWindows", as: WindowQueryWindowsFn.self),
            let windowQueryResultCopyWindows = Self.load("SLSWindowQueryResultCopyWindows", as: WindowQueryResultCopyWindowsFn.self),
            let windowIteratorAdvance = Self.load("SLSWindowIteratorAdvance", as: WindowIteratorAdvanceFn.self),
            let windowIteratorGetResolvedCornerRadii = Self.load(
                "SLSWindowIteratorGetResolvedCornerRadii",
                as: WindowIteratorGetResolvedCornerRadiiFn.self
            )
        else {
            return nil
        }

        self.mainConnectionID = mainConnectionID
        self.windowQueryWindows = windowQueryWindows
        self.windowQueryResultCopyWindows = windowQueryResultCopyWindows
        self.windowIteratorAdvance = windowIteratorAdvance
        self.windowIteratorGetResolvedCornerRadii = windowIteratorGetResolvedCornerRadii
    }

    private static func load<T>(_ name: String, as _: T.Type) -> T? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
            return nil
        }
        return unsafeBitCast(symbol, to: T.self)
    }
}

/// Queries the WindowServer for the resolved corner radii of the given window.
/// Returns the maximum corner radius, or `nil` if the query fails.
func queryWindowCornerRadius(windowNumber: Int) -> CGFloat? {
    guard let skyLight = SkyLightWindowQuery.shared else { return nil }

    let cid = skyLight.mainConnectionID()
    let windowIDs = [NSNumber(value: Int32(windowNumber))] as CFArray

    guard let queryResult = skyLight.windowQueryWindows(cid, windowIDs, 1),
          let iterator = skyLight.windowQueryResultCopyWindows(queryResult)
    else { return nil }

    guard skyLight.windowIteratorAdvance(iterator) else { return nil }

    guard let radiiArray = skyLight.windowIteratorGetResolvedCornerRadii(iterator) else { return nil }
    let count = CFArrayGetCount(radiiArray)
    guard count > 0 else { return nil }

    var maxRadius: Double = 0
    for index in 0 ..< count {
        let number = unsafeBitCast(CFArrayGetValueAtIndex(radiiArray, index), to: CFNumber.self)
        var value: Double = 0
        CFNumberGetValue(number, .float64Type, &value)
        maxRadius = max(maxRadius, value)
    }

    return maxRadius > 0 ? CGFloat(maxRadius) : nil
}
