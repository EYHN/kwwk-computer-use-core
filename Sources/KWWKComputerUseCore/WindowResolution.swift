import AppKit
import ApplicationServices
import Foundation

private struct WindowCandidate {
    let element: AXUIElement
    let title: String
    let frame: CGRect
    let cgWindow: CUWindowSnapshot
    let isMain: Bool
    let isFocused: Bool
}

extension ComputerUseCore {
    static func listWindows(appIdentifier: String) throws -> [ComputerUseWindowDescriptor] {
        guard AXIsProcessTrusted() else {
            throw ComputerUseError.accessibilityPermissionDenied
        }

        let app = try resolveRunningApplication(matching: appIdentifier)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        ChromiumAccessibilityActivation.shared.activateIfNeeded(
            pid: app.processIdentifier,
            root: appElement
        )

        let appName = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
        let bundleID = app.bundleIdentifier ?? ""
        return windowCandidates(in: appElement, app: app).map { candidate in
            ComputerUseWindowDescriptor(
                appName: appName,
                bundleID: bundleID,
                pid: app.processIdentifier,
                windowID: candidate.cgWindow.windowID,
                title: candidate.title,
                isMain: candidate.isMain
            )
        }
    }

    static func resolveRunningApplication(matching identifier: String) throws -> NSRunningApplication {
        if let app = resolveRunningApplicationIfAvailable(matching: identifier) {
            return app
        }

        throw ComputerUseError.appNotRunning(identifier)
    }

    static func resolveWindow(
        in appElement: AXUIElement,
        app: NSRunningApplication,
        titleSubstring: String?,
        preferredWindowID: Int?,
        preferredWindowFrame: CGRect? = nil
    ) throws -> (element: AXUIElement, title: String, frame: CGRect, cgWindow: CUWindowSnapshot) {
        let candidates = windowCandidates(
            in: appElement,
            app: app,
            preferredWindowID: preferredWindowID
        )

        if let preferredWindowID,
           let exact = candidates.first(where: { $0.cgWindow.windowID == preferredWindowID })
        {
            return resolvedWindow(exact)
        }

        if let preferredWindowFrame,
           let best = bestCandidateByFrame(candidates, hint: preferredWindowFrame)
        {
            return resolvedWindow(best)
        }

        let filtered: [WindowCandidate] = if let titleSubstring, titleSubstring.isEmpty == false {
            candidates.filter { candidate in
                candidate.title.localizedCaseInsensitiveContains(titleSubstring)
            }
        } else {
            candidates
        }

        if let main = filtered.first(where: { $0.isMain }) {
            return resolvedWindow(main)
        }

        if let focused = filtered.first(where: { $0.isFocused }) {
            return resolvedWindow(focused)
        }

        if let first = filtered.first {
            return resolvedWindow(first)
        }

        throw ComputerUseError.windowNotFound(
            app: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
            title: titleSubstring
        )
    }

    private static func windowCandidates(
        in appElement: AXUIElement,
        app: NSRunningApplication,
        preferredWindowID: Int? = nil
    ) -> [WindowCandidate] {
        let windows = mergeAXWindowCandidates(
            listedWindows: cuAttribute(appElement, name: kAXWindowsAttribute as String) as [AXUIElement]? ?? [],
            focusedWindow: cuAttribute(appElement, name: kAXFocusedWindowAttribute as String) as AXUIElement?,
            mainWindow: cuAttribute(appElement, name: kAXMainWindowAttribute as String) as AXUIElement?
        )
        let cgWindows = cuCGWindows(for: app.processIdentifier)

        var candidates: [WindowCandidate] = []

        for window in windows {
            guard let frame = cuFrame(window) else {
                continue
            }

            let title = cuTitle(window)
            let matchingWindow = matchCGWindow(
                axWindow: window,
                candidates: cgWindows,
                preferredWindowID: preferredWindowID,
                title: title,
                frame: frame
            )

            guard let cgWindow = matchingWindow else {
                continue
            }

            candidates.append(WindowCandidate(
                element: window,
                title: title,
                frame: frame,
                cgWindow: cgWindow,
                isMain: cuBoolAttribute(window, name: kAXMainAttribute as String) == true,
                isFocused: cuBoolAttribute(window, name: kAXFocusedAttribute as String) == true
            ))
        }

        return candidates
    }

    private static func resolvedWindow(
        _ candidate: WindowCandidate
    ) -> (element: AXUIElement, title: String, frame: CGRect, cgWindow: CUWindowSnapshot) {
        (candidate.element, candidate.title, candidate.frame, candidate.cgWindow)
    }

    private static func bestCandidateByFrame(
        _ candidates: [WindowCandidate],
        hint: CGRect
    ) -> WindowCandidate? {
        func score(_ frame: CGRect) -> CGFloat {
            let dx = frame.midX - hint.midX
            let dy = frame.midY - hint.midY
            let dw = frame.width - hint.width
            let dh = frame.height - hint.height
            return sqrt(dx * dx + dy * dy) + abs(dw) + abs(dh)
        }
        return candidates
            .map { ($0, score($0.frame)) }
            .min(by: { $0.1 < $1.1 })?.0
    }

    private static func matchCGWindow(
        axWindow: AXUIElement,
        candidates: [CUWindowSnapshot],
        preferredWindowID: Int?,
        title: String,
        frame: CGRect
    ) -> CUWindowSnapshot? {
        if let exactWindowID = AXWindowIDResolver.cgWindowID(forAXWindow: axWindow),
           let exact = candidates.first(where: { $0.windowID == Int(exactWindowID) })
        {
            return exact
        }

        if let preferredWindowID,
           let preferred = candidates.first(where: { $0.windowID == preferredWindowID }),
           nearlyEqualRects(preferred.bounds, frame, tolerance: 4)
        {
            return preferred
        }

        if title.isEmpty == false {
            let sameTitle = candidates.filter {
                $0.name.localizedCaseInsensitiveContains(title)
            }
            if let frameMatch = sameTitle.first(where: {
                nearlyEqualRects($0.bounds, frame)
            }) {
                return frameMatch
            }
            if let firstTitle = sameTitle.first {
                return firstTitle
            }
        }

        return candidates.first(where: { nearlyEqualRects($0.bounds, frame) }) ??
            candidates.first(where: { $0.layer == 0 })
    }
}
