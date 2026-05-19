import ApplicationServices
import Foundation

private let chromiumAXObserverNoopCallback: AXObserverCallbackWithInfo = { _, _, _, _, _ in }

final class ChromiumAccessibilityActivation: @unchecked Sendable {
    static let shared = ChromiumAccessibilityActivation()

    private typealias AddNotificationAndCheckRemoteFn = @convention(c) (
        AXObserver,
        AXUIElement,
        CFString,
        UnsafeMutableRawPointer?
    ) -> AXError

    private static let addNotificationAndCheckRemote: AddNotificationAndCheckRemoteFn? = {
        _ = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
            RTLD_LAZY
        )

        for name in [
            "_AXObserverAddNotificationAndCheckRemote",
            "AXObserverAddNotificationAndCheckRemote",
        ] {
            if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) {
                return unsafeBitCast(symbol, to: AddNotificationAndCheckRemoteFn.self)
            }
        }
        return nil
    }()

    private var activatedPIDs = Set<pid_t>()
    private var observers: [pid_t: AXObserver] = [:]

    func activateIfNeeded(pid: pid_t, root: AXUIElement) {
        let alreadyActivated = activatedPIDs.contains(pid)

        guard assertChromiumAccessibility(root: root) else {
            return
        }

        guard !alreadyActivated else {
            return
        }

        let inserted = activatedPIDs.insert(pid).inserted
        guard inserted else {
            return
        }

        registerObserver(pid: pid, root: root)
        waitForActivation(duration: 0.5)
    }

    private func assertChromiumAccessibility(root: AXUIElement) -> Bool {
        let attributes = [
            "AXManualAccessibility",
            "AXEnhancedUserInterface",
        ]

        var accepted = false
        for attribute in attributes {
            let result = AXUIElementSetAttributeValue(
                root,
                attribute as CFString,
                kCFBooleanTrue
            )
            accepted = accepted || result == .success
        }
        return accepted
    }

    private func registerObserver(pid: pid_t, root: AXUIElement) {
        var observer: AXObserver?
        guard AXObserverCreateWithInfoCallback(
            pid,
            chromiumAXObserverNoopCallback,
            &observer
        ) == .success, let observer else {
            return
        }

        if let source = AXObserverGetRunLoopSource(observer) as CFRunLoopSource? {
            CoreRunLoopThread.shared.addSource(source, mode: CFRunLoopMode.defaultMode)
        }

        for notification in notifications {
            _ = addNotification(observer: observer, element: root, notification: notification)
        }

        observers[pid] = observer
    }

    private func addNotification(
        observer: AXObserver,
        element: AXUIElement,
        notification: CFString
    ) -> AXError {
        if let fn = Self.addNotificationAndCheckRemote {
            return fn(observer, element, notification, nil)
        }
        return AXObserverAddNotification(observer, element, notification, nil)
    }

    private func waitForActivation(duration: TimeInterval) {
        Thread.sleep(forTimeInterval: duration)
    }

    private let notifications: [CFString] = [
        kAXFocusedUIElementChangedNotification as CFString,
        kAXFocusedWindowChangedNotification as CFString,
        kAXApplicationActivatedNotification as CFString,
        kAXApplicationDeactivatedNotification as CFString,
        kAXApplicationHiddenNotification as CFString,
        kAXApplicationShownNotification as CFString,
        kAXWindowCreatedNotification as CFString,
        kAXWindowMovedNotification as CFString,
        kAXWindowResizedNotification as CFString,
        kAXValueChangedNotification as CFString,
        kAXTitleChangedNotification as CFString,
        kAXSelectedChildrenChangedNotification as CFString,
        kAXLayoutChangedNotification as CFString,
    ]
}
