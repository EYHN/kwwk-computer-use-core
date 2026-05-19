import ApplicationServices
import Foundation

struct PopupMenuCandidate {
    let element: AXUIElement
    let frame: CGRect
}

extension ComputerUseCore {
    /// Status menu extras only appear directly under a menu bar (depth 2 from the app root).
    private static let statusMenuExtraMaxDepth = 2

    static func statusMenuExtraCandidates(in appElement: AXUIElement) -> [AXUIElement] {
        collectStatusMenuExtras(in: appElement)
    }

    static func popupMenuCandidate(in appElement: AXUIElement) -> PopupMenuCandidate? {
        let roots = cuElements(from: cuRawAttribute(appElement, name: kAXFocusedWindowAttribute as String)) +
            cuElements(from: cuRawAttribute(appElement, name: kAXFocusedUIElementAttribute as String))
        return popupMenuCandidate(near: roots)
    }

    static func popupMenuCandidate(
        near roots: [AXUIElement],
        requireVisibleItems: Bool = true,
        matching targetFrame: CGRect? = nil
    ) -> PopupMenuCandidate? {
        var stack = roots
        var visited = Set<CFHashCode>()
        var best: PopupMenuCandidate?

        while let element = stack.popLast() {
            let identifier = CFHash(element)
            if visited.contains(identifier) {
                continue
            }
            visited.insert(identifier)

            let role = cuAttribute(element, name: kAXRoleAttribute as String) as String? ?? ""
            if role == (kAXMenuRole as String),
               let frame = cuFrame(element),
               (requireVisibleItems ? popupMenuHasVisibleItems(element) : popupMenuHasItems(element)),
               (matchesTargetFrame(frame, targetFrame) || isTransientPopupMenu(element)) {
                let candidate = PopupMenuCandidate(element: element, frame: frame)
                if best == nil ||
                    isBetterPopupMenuCandidate(
                        candidateFrame: frame,
                        candidate: element,
                        currentFrame: best!.frame,
                        current: best!.element,
                        requireVisibleItems: requireVisibleItems,
                        targetFrame: targetFrame
                    ) {
                    best = candidate
                }
            }

            stack.append(contentsOf: popupMenuSearchChildren(element))
        }

        return best
    }

    static func activeMenuBarItemCandidate(in appElement: AXUIElement) -> PopupMenuCandidate? {
        guard let menuBar = cuAttribute(appElement, name: kAXMenuBarAttribute as String) as AXUIElement? else {
            return nil
        }

        let items = cuChildElements(menuBar).filter { element in
            let role = cuAttribute(element, name: kAXRoleAttribute as String) as String? ?? ""
            return role == (kAXMenuBarItemRole as String) && cuTitle(element) != "Apple"
        }

        for item in items where cuBoolAttribute(item, name: kAXSelectedAttribute as String) == true {
            let menus = cuChildElements(item).filter { child in
                let role = cuAttribute(child, name: kAXRoleAttribute as String) as String? ?? ""
                return role == (kAXMenuRole as String) && popupMenuHasItems(child)
            }
            guard menus.contains(where: popupMenuHasVisibleItems) else {
                continue
            }
            let frames = ([cuFrame(item)] + menus.map(cuFrame)).compactMap { $0 }
            let frame = frames.reduce(CGRect.null) { partial, next in
                partial.isNull ? next : partial.union(next)
            }
            if frame.isNull == false {
                return PopupMenuCandidate(element: item, frame: frame)
            }
        }

        return nil
    }

    static func activeStatusMenuItemCandidate(in appElement: AXUIElement) -> PopupMenuCandidate? {
        activeStatusMenuItemCandidate(in: statusMenuExtraCandidates(in: appElement))
    }

    static func activeStatusMenuItemCandidate(in statusMenuExtras: [AXUIElement]) -> PopupMenuCandidate? {
        for item in statusMenuExtras {
            let menus = cuChildElements(item).filter { child in
                let role = cuAttribute(child, name: kAXRoleAttribute as String) as String? ?? ""
                return role == (kAXMenuRole as String) && popupMenuHasItems(child)
            }
            guard menus.isEmpty == false else {
                continue
            }

            let hasVisibleMenu = menus.contains {
                cuElements(from: cuRawAttribute($0, name: "AXVisibleChildren")).isEmpty == false
            }
            let isActive = cuBoolAttribute(item, name: kAXSelectedAttribute as String) == true ||
                cuBoolAttribute(item, name: kAXFocusedAttribute as String) == true ||
                hasVisibleMenu
            guard isActive else {
                continue
            }

            let frames = ([cuFrame(item)] + menus.map(cuFrame)).compactMap { $0 }
            let frame = frames.reduce(CGRect.null) { partial, next in
                partial.isNull ? next : partial.union(next)
            }
            if frame.isNull == false {
                return PopupMenuCandidate(element: item, frame: frame)
            }
        }

        return nil
    }

    private static func collectStatusMenuExtras(in appElement: AXUIElement) -> [AXUIElement] {
        var stack: [(AXUIElement, Int)] = [(appElement, 0)]
        var visited = Set<CFHashCode>()
        var result: [AXUIElement] = []

        while let (element, depth) = stack.popLast() {
            let identifier = CFHash(element)
            if visited.contains(identifier) {
                continue
            }
            visited.insert(identifier)

            let role = cuAttribute(element, name: kAXRoleAttribute as String) as String? ?? ""
            let subrole = cuAttribute(element, name: kAXSubroleAttribute as String) as String? ?? ""
            if role == (kAXMenuBarItemRole as String),
               subrole == "AXMenuExtra",
               let frame = cuFrame(element),
               frame.minY <= 45,
               frame.width > 0,
               frame.height > 0 {
                result.append(element)
                continue
            }

            guard depth < statusMenuExtraMaxDepth else {
                continue
            }

            for child in cuChildElements(element) {
                stack.append((child, depth + 1))
            }
        }

        return result
    }

    private static func isTransientPopupMenu(_ menu: AXUIElement) -> Bool {
        var current: AXUIElement? = menu
        var visited = Set<CFHashCode>()

        while let element = current {
            let identifier = CFHash(element)
            if visited.contains(identifier) {
                return false
            }
            visited.insert(identifier)

            let role = cuAttribute(element, name: kAXRoleAttribute as String) as String? ?? ""
            if role == (kAXMenuBarItemRole as String) ||
                role == (kAXMenuItemRole as String) ||
                role == (kAXPopUpButtonRole as String) ||
                role == "AXMenuButton" {
                return true
            }

            if role == "AXWebArea" ||
                role == (kAXWindowRole as String) {
                return false
            }

            current = cuAttribute(element, name: kAXParentAttribute as String) as AXUIElement?
        }

        return false
    }

    private static func popupMenuHasItems(_ menu: AXUIElement) -> Bool {
        menuItemCount(in: menu) > 0
    }

    private static func matchesTargetFrame(_ frame: CGRect, _ targetFrame: CGRect?) -> Bool {
        guard let targetFrame else {
            return false
        }
        return frameDistance(frame, targetFrame) == 0
    }

    private static func popupMenuSearchChildren(_ element: AXUIElement) -> [AXUIElement] {
        cuChildElements(element) + cuElements(from: cuRawAttribute(element, name: "AXMenu"))
    }

    private static func isBetterPopupMenuCandidate(
        candidateFrame: CGRect,
        candidate: AXUIElement,
        currentFrame: CGRect,
        current: AXUIElement,
        requireVisibleItems: Bool,
        targetFrame: CGRect?
    ) -> Bool {
        if let targetFrame {
            let candidateDistance = frameDistance(candidateFrame, targetFrame)
            let currentDistance = frameDistance(currentFrame, targetFrame)
            if candidateDistance != currentDistance {
                return candidateDistance < currentDistance
            }
        }

        let candidateCount = menuItemCount(in: candidate)
        let currentCount = menuItemCount(in: current)
        if requireVisibleItems {
            return candidateCount > currentCount
        }
        return candidateCount < currentCount
    }

    private static func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        if lhs.intersects(rhs) {
            return 0
        }
        return hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
    }

    private static func popupMenuHasVisibleItems(_ menu: AXUIElement) -> Bool {
        let visibleChildren = cuElements(from: cuRawAttribute(menu, name: "AXVisibleChildren"))
        guard visibleChildren.isEmpty == false else {
            return false
        }
        return visibleChildren.contains { child in
            let role = cuAttribute(child, name: kAXRoleAttribute as String) as String? ?? ""
            return role == (kAXMenuItemRole as String) || !cuTitle(child).isEmpty || !cuDescription(child).isEmpty
        }
    }

    private static func menuItemCount(in menu: AXUIElement) -> Int {
        cuMenuChildren(menu).filter { child in
            let role = cuAttribute(child, name: kAXRoleAttribute as String) as String? ?? ""
            return role == (kAXMenuItemRole as String) || !cuTitle(child).isEmpty || !cuDescription(child).isEmpty
        }.count
    }
}
