import AppKit
import Carbon

private let probeName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Probe"
private let logURL = URL(fileURLWithPath: "/private/tmp/\(probeName).activation.log")

private final class ProbeAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var clickCount = 0
    private var statusItem: NSStatusItem!
    private var windowMenu: NSMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = makeMainMenu()
        createStatusItem()
        createWindow()
        installStateObservers()
        writeLog("launched")
        writeState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        writeState()
    }

    func windowDidBecomeMain(_ notification: Notification) {
        writeState()
    }

    func windowDidResignKey(_ notification: Notification) {
        writeState()
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        clickCount += 1
        writeLog("buttonPressed clicks=\(clickCount)")
        writeState()
    }

    @objc private func menuChoicePicked(_ sender: NSMenuItem) {
        writeLog("windowMenuPicked title=\(sender.title)")
    }

    @objc private func appMenuPicked(_ sender: NSMenuItem) {
        writeLog("appMenuPicked title=\(sender.title)")
    }

    @objc private func statusMenuPicked(_ sender: NSMenuItem) {
        writeLog("statusMenuPicked title=\(sender.title)")
    }

    @objc private func terminate(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu(title: "Main Menu")

        let appItem = NSMenuItem(title: probeName, action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: probeName)
        appMenu.addItem(NSMenuItem(
            title: "\(probeName) Probe About",
            action: #selector(appMenuPicked(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(
            title: "Quit \(probeName)",
            action: #selector(terminate(_:)),
            keyEquivalent: "q"
        ))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let toolsItem = NSMenuItem(title: "Probe Tools", action: nil, keyEquivalent: "")
        let toolsMenu = NSMenu(title: "Probe Tools")
        toolsMenu.addItem(NSMenuItem(
            title: "Probe Tool One",
            action: #selector(appMenuPicked(_:)),
            keyEquivalent: ""
        ))
        toolsMenu.addItem(NSMenuItem(
            title: "Probe Tool Two",
            action: #selector(appMenuPicked(_:)),
            keyEquivalent: ""
        ))
        toolsItem.submenu = toolsMenu
        mainMenu.addItem(toolsItem)

        return mainMenu
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: statusSymbolName, accessibilityDescription: "\(probeName) Status")
        statusItem.button?.title = ""
        statusItem.button?.setAccessibilityIdentifier("probe-status-item")

        let menu = NSMenu(title: "\(probeName) Status Menu")
        menu.addItem(NSMenuItem(
            title: "\(probeName) Status One",
            action: #selector(statusMenuPicked(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "\(probeName) Status Two",
            action: #selector(statusMenuPicked(_:)),
            keyEquivalent: ""
        ))
        statusItem.menu = menu
    }

    private func createWindow() {
        let frame = NSRect(origin: windowOrigin, size: NSSize(width: 560, height: 320))
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(probeName) AppKit Activation Probe"
        window.delegate = self

        let root = ProbeRootView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
        root.autoresizingMask = [.width, .height]

        let title = NSTextField(labelWithString: "\(probeName) Main Window")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.frame = NSRect(x: 28, y: 250, width: 360, height: 28)
        title.setAccessibilityIdentifier("probe-title")
        root.addSubview(title)

        let input = NSTextField(string: "")
        input.placeholderString = "Probe input"
        input.frame = NSRect(x: 28, y: 188, width: 260, height: 28)
        input.setAccessibilityIdentifier("probe-input")
        root.addSubview(input)

        let button = ProbeButton(title: "Probe Button", target: self, action: #selector(buttonPressed(_:)))
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 28, y: 36, width: 160, height: 34)
        button.setAccessibilityIdentifier("probe-button")
        root.addSubview(button)

        let menuButton = ProbeMenuButton(title: "Choose", target: self, action: #selector(openWindowMenu(_:)))
        menuButton.bezelStyle = .rounded
        menuButton.frame = NSRect(x: 220, y: 36, width: 190, height: 34)
        menuButton.setAccessibilityIdentifier("probe-menu-button")
        windowMenu = NSMenu(title: "Probe Window Menu")
        windowMenu.addItem(NSMenuItem(title: "First Choice", action: #selector(menuChoicePicked(_:)), keyEquivalent: ""))
        windowMenu.addItem(NSMenuItem(title: "Second Choice", action: #selector(menuChoicePicked(_:)), keyEquivalent: ""))
        windowMenu.items.forEach { item in item.target = self }
        menuButton.menu = windowMenu
        root.addSubview(menuButton)

        window.contentView = root
        window.makeKeyAndOrderFront(nil)
    }

    private func installStateObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in self?.writeState() }
        center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in self?.writeState() }
    }

    @objc private func openWindowMenu(_ sender: ProbeMenuButton) {
        writeLog("openWindowMenu")
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: sender.bounds.midX, y: sender.bounds.midY),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: sender.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        if let event {
            NSMenu.popUpContextMenu(windowMenu, with: event, for: sender)
        } else {
            windowMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        }
        writeLog("openWindowMenu returned")
    }

    private var windowOrigin: NSPoint {
        switch probeName.suffix(1) {
        case "A":
            NSPoint(x: 160, y: 420)
        case "B":
            NSPoint(x: 300, y: 300)
        case "C":
            NSPoint(x: 440, y: 180)
        default:
            NSPoint(x: 240, y: 260)
        }
    }

    private var statusSymbolName: String {
        switch probeName.suffix(1) {
        case "A": "a.circle"
        case "B": "b.circle"
        case "C": "c.circle"
        default: "circle"
        }
    }

    private func writeState() {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil"
        writeLog(
            "isActive=\(NSApp.isActive) isKey=\(window?.isKeyWindow == true) " +
            "isMain=\(window?.isMainWindow == true) front=\(front) clicks=\(clickCount)"
        )
    }

    private func writeLog(_ message: String) {
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        if FileManager.default.fileExists(atPath: logURL.path) == false {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
            return
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        }
    }
}

private final class ProbeRootView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        appendProbeLog("root.mouseDown loc=(\(Int(location.x)),\(Int(location.y)))")
        super.mouseDown(with: event)
    }
}

private final class ProbeButton: NSButton {
    override func mouseDown(with event: NSEvent) {
        let location = superview?.convert(event.locationInWindow, from: nil) ?? .zero
        appendProbeLog("button.mouseDown loc=(\(Int(location.x)),\(Int(location.y)))")
        super.mouseDown(with: event)
    }
}

private final class ProbeMenuButton: NSButton {
    override func accessibilityRole() -> NSAccessibility.Role? {
        .menuButton
    }

    override func accessibilityPerformPress() -> Bool {
        appendProbeLog("menuButton.accessibilityPerformPress")
        DispatchQueue.main.async { [weak self] in
            self?.performClick(nil)
        }
        return true
    }
}

private func appendProbeLog(_ message: String) {
    let line = "\(Date().timeIntervalSince1970) \(message)\n"
    if FileManager.default.fileExists(atPath: logURL.path) == false {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
        return
    }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
        try? handle.close()
    }
}

private let delegate = ProbeAppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
