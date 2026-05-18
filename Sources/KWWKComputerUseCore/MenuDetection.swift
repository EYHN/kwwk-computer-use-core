import ApplicationServices
import Foundation

struct PopupMenuCandidate {
    let element: AXUIElement
    let frame: CGRect
}

extension ComputerUseCore {
    static func popupMenuCandidate(in appElement: AXUIElement) -> PopupMenuCandidate? {
        let roots = cuElements(from: cuRawAttribute(appElement, name: kAXFocusedWindowAttribute as String)) +
            cuElements(from: cuRawAttribute(appElement, name: kAXWindowsAttribute as String)) +
            cuElements(from: cuRawAttribute(appElement, name: kAXFocusedUIElementAttribute as String))
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
               popupMenuHasItems(element),
               isTransientPopupMenu(element) {
                let candidate = PopupMenuCandidate(element: element, frame: frame)
                if best == nil || menuItemCount(in: element) > menuItemCount(in: best!.element) {
                    best = candidate
                }
            }

            stack.append(contentsOf: cuChildElements(element))
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
            guard menus.isEmpty == false else {
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
        for item in statusMenuExtraCandidates(in: appElement) {
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

    static func statusMenuExtraCandidates(in appElement: AXUIElement) -> [AXUIElement] {
        var stack = [appElement]
        var visited = Set<CFHashCode>()
        var result: [AXUIElement] = []

        while let element = stack.popLast() {
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

            stack.append(contentsOf: cuChildElements(element))
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

    private static func menuItemCount(in menu: AXUIElement) -> Int {
        cuMenuChildren(menu).filter { child in
            let role = cuAttribute(child, name: kAXRoleAttribute as String) as String? ?? ""
            return role == (kAXMenuItemRole as String) || !cuTitle(child).isEmpty || !cuDescription(child).isEmpty
        }.count
    }
}
