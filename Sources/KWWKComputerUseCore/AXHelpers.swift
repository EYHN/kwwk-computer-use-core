import AppKit
import ApplicationServices
import Foundation

func cuRawAttribute(_ element: AXUIElement, name: String) -> Any? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard error == .success else {
        return nil
    }
    return value
}

func cuAttribute<T>(_ element: AXUIElement, name: String) -> T? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard error == .success else {
        return nil
    }
    return value as? T
}

func cuBoolAttribute(_ element: AXUIElement, name: String) -> Bool? {
    cuAttribute(element, name: name) as Bool?
}

func cuTitle(_ element: AXUIElement) -> String {
    cuAttribute(element, name: kAXTitleAttribute as String) as String? ?? ""
}

func cuDescription(_ element: AXUIElement) -> String {
    cuAttribute(element, name: kAXDescriptionAttribute as String) as String? ?? ""
}

func cuActions(_ element: AXUIElement) -> [String] {
    var value: CFArray?
    let error = AXUIElementCopyActionNames(element, &value)
    guard error == .success else {
        return []
    }
    return value as? [String] ?? []
}

func cuFrame(_ element: AXUIElement) -> CGRect? {
    guard
        let positionValue = cuAttribute(element, name: kAXPositionAttribute as String) as AXValue?,
        let sizeValue = cuAttribute(element, name: kAXSizeAttribute as String) as AXValue?,
        let position = cuCGPoint(from: positionValue),
        let size = cuCGSize(from: sizeValue)
    else {
        return nil
    }

    return CGRect(origin: position, size: size)
}

private let cuChildRelationshipAttributes: [String] = [
    kAXChildrenAttribute as String,
]

func cuChildElements(_ element: AXUIElement) -> [AXUIElement] {
    var result: [AXUIElement] = []

    func append(_ child: AXUIElement) {
        guard !result.contains(where: { CFEqual($0, child) }) else { return }
        result.append(child)
    }

    for attribute in cuChildRelationshipAttributes {
        guard let value = cuRawAttribute(element, name: attribute) else {
            continue
        }

        if let child = cuAXElement(from: value) {
            append(child)
        } else if CFGetTypeID(value as CFTypeRef) == CFArrayGetTypeID(),
                  let children = value as? [AXUIElement]
        {
            children.forEach(append)
        }
    }

    return result
}

func cuElements(from value: Any?) -> [AXUIElement] {
    guard let value else { return [] }
    if let element = cuAXElement(from: value) {
        return [element]
    }
    if CFGetTypeID(value as CFTypeRef) == CFArrayGetTypeID(),
       let children = value as? [AXUIElement] {
        return children
    }
    return []
}

func cuAXValue(from value: Any) -> AXValue? {
    guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else {
        return nil
    }
    // CoreFoundation casts between CF object types are not meaningfully conditional in Swift.
    // The CFTypeID guard above is the runtime type check that makes this bridge safe.
    return (value as! AXValue)
}

func cuAXElement(from value: Any) -> AXUIElement? {
    guard CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else {
        return nil
    }
    // CoreFoundation casts between CF object types are not meaningfully conditional in Swift.
    // The CFTypeID guard above is the runtime type check that makes this bridge safe.
    return (value as! AXUIElement)
}

func cuMenuChildren(_ element: AXUIElement) -> [AXUIElement] {
    let visible = cuElements(from: cuRawAttribute(element, name: "AXVisibleChildren"))
    if visible.isEmpty == false {
        return visible
    }
    return cuChildElements(element)
}

func cuChildElementsForWalk(_ element: AXUIElement, role: String) -> [AXUIElement] {
    if role == (kAXMenuRole as String) {
        return cuMenuChildren(element)
    }
    if role == (kAXMenuBarRole as String) {
        return cuChildElements(element).filter { child in
            let childRole = cuAttribute(child, name: kAXRoleAttribute as String) as String? ?? ""
            return childRole != (kAXMenuBarItemRole as String) || cuTitle(child) != "Apple"
        }
    }
    return cuChildElements(element)
}

func cuShouldSkipChildWalk(role: String, element: AXUIElement) -> Bool {
    guard role == (kAXMenuRole as String) else {
        return false
    }

    guard let visibleChildren = cuRawAttribute(element, name: "AXVisibleChildren") else {
        return true
    }
    guard CFGetTypeID(visibleChildren as CFTypeRef) == CFArrayGetTypeID(),
          let children = visibleChildren as? [AXUIElement]
    else {
        return true
    }
    return children.isEmpty
}

func cuFrameIsVisible(_ frame: CGRect?, in visibleFrame: CGRect) -> Bool {
    guard let frame else {
        return false
    }
    guard frame.width > 0, frame.height > 0, visibleFrame.width > 0, visibleFrame.height > 0 else {
        return false
    }
    return frame.intersects(visibleFrame.insetBy(dx: -1, dy: -1))
}

func cuFrameIsMeaningfullyVisible(_ frame: CGRect?, in visibleFrame: CGRect) -> Bool {
    guard let frame,
          frame.width > 0,
          frame.height > 0,
          visibleFrame.width > 0,
          visibleFrame.height > 0,
          let intersection = cuVisibleIntersection(frame, visibleFrame.insetBy(dx: -1, dy: -1))
    else {
        return false
    }

    let frameArea = frame.width * frame.height
    guard frameArea > 0 else {
        return false
    }

    let visibleArea = intersection.width * intersection.height
    let visibleRatio = visibleArea / frameArea
    return visibleRatio >= 0.25 || (intersection.width >= 8 && intersection.height >= 12)
}

func cuVisibleIntersection(_ lhs: CGRect, _ rhs: CGRect) -> CGRect? {
    let intersection = lhs.intersection(rhs)
    guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
        return nil
    }
    return intersection
}

private let rolesThatCanContainVisibleDescendants: Set<String> = [
    kAXApplicationRole as String,
    kAXWindowRole as String,
    kAXGroupRole as String,
    kAXScrollAreaRole as String,
    kAXListRole as String,
    kAXOutlineRole as String,
    kAXTableRole as String,
    kAXRowRole as String,
    kAXColumnRole as String,
    kAXSplitGroupRole as String,
    kAXSplitterRole as String,
    kAXTabGroupRole as String,
    kAXToolbarRole as String,
    "AXWebArea",
    "AXGenericElement",
]

func roleCanContainVisibleDescendants(_ role: String) -> Bool {
    rolesThatCanContainVisibleDescendants.contains(role)
}

private let rolesThatClipVisibleDescendants: Set<String> = [
    kAXScrollAreaRole as String,
    kAXListRole as String,
    kAXOutlineRole as String,
    kAXTableRole as String,
    kAXColumnRole as String,
    kAXTabGroupRole as String,
    "AXWebArea",
]

func roleClipsVisibleDescendants(_ role: String) -> Bool {
    rolesThatClipVisibleDescendants.contains(role)
}

func cuDescendantVisibleClip(
    role: String,
    frame: CGRect?,
    inheritedClip: CGRect
) -> CGRect {
    guard roleClipsVisibleDescendants(role), let frame else {
        return inheritedClip
    }
    return cuVisibleIntersection(frame, inheritedClip) ?? inheritedClip
}

func cuIsAttributeSettable(_ element: AXUIElement, name: String) -> Bool {
    var settable = DarwinBoolean(false)
    let error = AXUIElementIsAttributeSettable(
        element,
        name as CFString,
        &settable
    )
    return error == .success && settable.boolValue
}

func cuCGPoint(from value: AXValue) -> CGPoint? {
    guard AXValueGetType(value) == .cgPoint else {
        return nil
    }

    var point = CGPoint.zero
    return AXValueGetValue(value, .cgPoint, &point) ? point : nil
}

func cuCGSize(from value: AXValue) -> CGSize? {
    guard AXValueGetType(value) == .cgSize else {
        return nil
    }

    var size = CGSize.zero
    return AXValueGetValue(value, .cgSize, &size) ? size : nil
}

func cuCGWindows(for pid: pid_t) -> [CUWindowSnapshot] {
    guard
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
    else {
        return []
    }

    return info.compactMap { entry in
        guard
            let ownerPID = entry[kCGWindowOwnerPID as String] as? Int,
            ownerPID == Int(pid),
            let windowID = entry[kCGWindowNumber as String] as? Int,
            let layer = entry[kCGWindowLayer as String] as? Int
        else {
            return nil
        }

        let ownerName = entry[kCGWindowOwnerName as String] as? String ?? ""
        let name = entry[kCGWindowName as String] as? String ?? ""
        let alpha = entry[kCGWindowAlpha as String] as? Double ?? -1
        let bounds = (entry[kCGWindowBounds as String] as? NSDictionary)
            .flatMap { CGRect(dictionaryRepresentation: $0) } ?? .null

        return CUWindowSnapshot(
            windowID: windowID,
            ownerName: ownerName,
            name: name,
            layer: layer,
            alpha: alpha,
            bounds: bounds
        )
    }
}

func mergeAXWindowCandidates(
    listedWindows: [AXUIElement],
    focusedWindow: AXUIElement?,
    mainWindow: AXUIElement?
) -> [AXUIElement] {
    var merged: [AXUIElement] = []

    for candidate in listedWindows + [focusedWindow, mainWindow].compactMap(\.self) {
        if merged.contains(where: { CFEqual($0, candidate) }) {
            continue
        }
        merged.append(candidate)
    }

    return merged
}
