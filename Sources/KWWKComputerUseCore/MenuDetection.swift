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
            let frame = cuFrame(item) ?? menus.compactMap(cuFrame).first
            if let frame {
                return PopupMenuCandidate(element: item, frame: frame)
            }
        }

        return nil
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
