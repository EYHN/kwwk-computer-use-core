import AppKit
import Foundation

final class FrontmostApplicationMonitor: @unchecked Sendable {
    typealias Handler = @Sendable (pid_t) -> Void

    final class ObserverToken: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.kwwk.computer-use.frontmost-monitor-token")
        private var cancellation: (@Sendable () -> Void)?

        init(cancellation: @escaping @Sendable () -> Void) {
            self.cancellation = cancellation
        }

        func cancel() {
            let cancellation = queue.sync {
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

    private let stateQueue = DispatchQueue(label: "com.kwwk.computer-use.frontmost-monitor")
    private var handlers: [UUID: Handler] = [:]
    private var workspaceObserver: NSObjectProtocol?

    init() {
        installWorkspaceObserver()
    }

    private func installWorkspaceObserver() {
        let install = {
            self.workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
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
                self?.stateQueue.async { [weak self] in
                    self?.notifyFrontmostPID(pid)
                }
            }
        }

        runWorkspaceNotificationCenterOperation(install)
    }

    func observe(_ handler: @escaping Handler) -> ObserverToken {
        let id = UUID()
        stateQueue.sync {
            handlers[id] = handler
        }

        return ObserverToken { [weak self] in
            self?.removeObserver(id: id)
        }
    }

    private func removeObserver(id: UUID) {
        stateQueue.sync {
            handlers[id] = nil
        }
    }

    private func notifyFrontmostPID(_ pid: pid_t) {
        let currentHandlers = Array(handlers.values)
        for handler in currentHandlers {
            handler(pid)
        }
    }

    deinit {
        guard let workspaceObserver else { return }
        let remove = {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        runWorkspaceNotificationCenterOperation(remove)
    }

    private func runWorkspaceNotificationCenterOperation(_ operation: @escaping () -> Void) {
        if Thread.isMainThread {
            operation()
        } else {
            DispatchQueue.main.sync(execute: operation)
        }
    }
}
