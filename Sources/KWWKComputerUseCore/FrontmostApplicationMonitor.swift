import AppKit
import Foundation

final class FrontmostApplicationMonitor: @unchecked Sendable {
    typealias Handler = @Sendable (pid_t) -> Void

    final class ObserverToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancellation: (@Sendable () -> Void)?

        init(cancellation: @escaping @Sendable () -> Void) {
            self.cancellation = cancellation
        }

        func cancel() {
            let cancellation = lock.withLock {
                let value = self.cancellation
                self.cancellation = nil
                return value
            }
            cancellation?()
        }

        deinit {
            cancel()
        }
    }

    static let shared = FrontmostApplicationMonitor()

    private let lock = NSLock()
    private let notifyQueue = DispatchQueue(label: "com.kwwk.computer-use.frontmost-monitor")
    private var handlers: [UUID: Handler] = [:]
    private var workspaceObserver: NSObjectProtocol?

    private init() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else {
                return
            }
            let pid = app.processIdentifier
            self?.notifyQueue.async { [weak self] in
                self?.notifyFrontmostPID(pid)
            }
        }
    }

    func observe(_ handler: @escaping Handler) -> ObserverToken {
        let id = UUID()
        lock.withLock {
            handlers[id] = handler
        }

        return ObserverToken { [weak self] in
            self?.removeObserver(id: id)
        }
    }

    private func removeObserver(id: UUID) {
        lock.withLock {
            handlers[id] = nil
        }
    }

    private func notifyFrontmostPID(_ pid: pid_t) {
        let currentHandlers = lock.withLock {
            Array(handlers.values)
        }
        for handler in currentHandlers {
            handler(pid)
        }
    }

    deinit {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
    }
}
