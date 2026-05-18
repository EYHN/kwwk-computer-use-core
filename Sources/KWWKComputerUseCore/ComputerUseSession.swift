import AppKit
import ApplicationServices
import Foundation

public final class ComputerUseSession: @unchecked Sendable {
    private struct ObservationKey: Hashable {
        let pid: pid_t
        let windowID: Int
    }

    private struct Observation {
        let sequence: Int
        let labels: [HarnessLabelEntry]
    }

    private struct ActiveTarget {
        let pid: pid_t
        let windowNumber: Int
        var backgroundActivation: BackgroundActivationSession?
        var backgroundActivated: Bool

        func matches(_ snapshot: RuntimeAppSnapshot) -> Bool {
            pid == snapshot.app.processIdentifier && windowNumber == snapshot.windowID
        }
    }

    private let lock = NSLock()
    private let actionLock = NSLock()
    private var activeTarget: ActiveTarget?
    private var visualEffectHookStorage: ComputerUseVisualEffectHook?
    private var observationSequence = 0
    private var initialObservations: [ObservationKey: Observation] = [:]
    private var previousObservations: [ObservationKey: Observation] = [:]
    private var recentActions: [String] = []
    private var latestSnapshotMetadata: ComputerUseSnapshotMetadata?
    private let frontmostMonitor = FrontmostApplicationMonitor()
    private var frontmostObserver: FrontmostApplicationMonitor.ObserverToken?
    private var finished = false

    public init() {
        frontmostObserver = frontmostMonitor.observe { [weak self] pid in
            self?.frontmostApplicationDidChange(pid: pid)
        }
    }

    public var visualEffectHook: ComputerUseVisualEffectHook? {
        get {
            lock.withLock { visualEffectHookStorage }
        }
        set {
            lock.withLock { visualEffectHookStorage = newValue }
        }
    }

    deinit {
        finish()
    }

    public func finish() {
        let result: (
            ActiveTarget?,
            ComputerUseVisualEffectHook?,
            FrontmostApplicationMonitor.ObserverToken?
        ) = actionLock.withLock {
            lock.withLock {
                guard !finished else { return (nil, nil, nil) }
                finished = true
                let target = activeTarget
                let hook = visualEffectHookStorage
                let observer = frontmostObserver
                activeTarget = nil
                visualEffectHookStorage = nil
                frontmostObserver = nil
                return (target, hook, observer)
            }
        }
        restoreAndFinish(result.0)
        result.1?.finish()
        result.2?.cancel()
    }

    func visualEffectEvent(
        action: ComputerUseVisualEffectAction,
        snapshot: RuntimeAppSnapshot,
        startPoint: CGPoint? = nil,
        endPoint: CGPoint? = nil,
        detail: String? = nil
    ) -> ComputerUseVisualEffectEvent {
        ComputerUseVisualEffectEvent(
            action: action,
            windowID: snapshot.windowID,
            windowFrame: CGRectCodable(snapshot.windowFrame),
            startPoint: startPoint.map { CGPointCodable($0) },
            endPoint: endPoint.map { CGPointCodable($0) },
            detail: detail
        )
    }

    func performWithBackgroundActivation<T>(
        on snapshot: RuntimeAppSnapshot,
        visualEffect event: ComputerUseVisualEffectEvent? = nil,
        _ body: () throws -> T
    ) throws -> T {
        try actionLock.withLock {
            let prepared: (ActiveTarget, ComputerUseVisualEffectHook?) = try lock.withLock {
                guard !finished else {
                    throw ComputerUseError.invalidArgument("computer use session is already finished")
                }

                let (target, _) = try prepareTargetForAction(snapshot)
                target.backgroundActivation?.beginTargetDelivery()
                return (target, visualEffectHookStorage)
            }

            defer {
                prepared.0.backgroundActivation?.holdFocusSuppressionUntilFinish()
            }

            if let event, let hook = prepared.1 {
                return try hook.perform(event, action: body)
            }
            return try body()
        }
    }

    func performWithBackgroundActivation<T>(
        on snapshot: RuntimeAppSnapshot,
        _ body: () throws -> T
    ) throws -> T {
        try performWithBackgroundActivation(on: snapshot, visualEffect: nil, body)
    }

    func prepareForSnapshotCapture(on snapshot: RuntimeAppSnapshot) throws -> Bool {
        try actionLock.withLock {
            try lock.withLock {
                guard !finished else {
                    throw ComputerUseError.invalidArgument("computer use session is already finished")
                }

                let (target, activated) = try prepareTargetForAction(snapshot)
                if activated {
                    target.backgroundActivation?.holdFocusSuppressionUntilFinish()
                }
                return activated
            }
        }
    }

    func recordAction(_ description: String) {
        lock.withLock {
            guard !finished else { return }
            recentActions.append(description)
            if recentActions.count > 12 {
                recentActions.removeFirst(recentActions.count - 12)
            }
        }
    }

    func recordSnapshot(_ metadata: ComputerUseSnapshotMetadata?) {
        guard let metadata else { return }
        lock.withLock {
            guard !finished else { return }
            latestSnapshotMetadata = metadata
        }
    }

    func requireLatestSnapshot(action: String) throws -> ComputerUseSnapshotMetadata {
        try lock.withLock {
            guard !finished else {
                throw ComputerUseError.invalidArgument("computer use session is already finished")
            }
            guard let latestSnapshotMetadata else {
                throw ComputerUseError.invalidArgument("\(action) requires a prior get-app-state result")
            }
            return latestSnapshotMetadata
        }
    }

    func annotateObservation(_ output: ComputerUseCommandOutput) -> ComputerUseCommandOutput {
        guard let metadata = output.metadata else {
            return output
        }

        let annotation = lock.withLock {
            guard !finished else { return "" }
            observationSequence += 1
            let key = ObservationKey(pid: metadata.pid, windowID: metadata.windowID)
            let labels = harnessLabelEntries(from: metadata)
            let observation = Observation(
                sequence: observationSequence,
                labels: labels
            )
            let initial = initialObservations[key] ?? observation
            let previous = previousObservations[key]
            initialObservations[key] = initial
            previousObservations[key] = observation

            return harnessAnnotation(
                metadata: metadata,
                observationSequence: observation.sequence,
                initialLabels: initial.labels,
                previousLabels: previous?.labels,
                recentActions: recentActions
            )
        }

        guard annotation.isEmpty == false else {
            return output
        }

        return ComputerUseCommandOutput(
            text: output.text + "\n" + annotation,
            metadata: metadata
        )
    }

    private func prepareTargetForAction(_ snapshot: RuntimeAppSnapshot) throws -> (ActiveTarget, Bool) {
        let appIsFrontmost = isTargetAppFrontmost(snapshot)

        if var activeTarget, activeTarget.matches(snapshot) {
            let activated = try prepareActivationIfNeeded(
                for: snapshot,
                target: &activeTarget,
                appIsFrontmost: appIsFrontmost
            )
            self.activeTarget = activeTarget
            return (activeTarget, activated)
        }

        replaceActiveTarget(nil)

        var activeTarget = ActiveTarget(
            pid: snapshot.app.processIdentifier,
            windowNumber: snapshot.windowID,
            backgroundActivation: nil,
            backgroundActivated: false
        )
        let activated = try prepareActivationIfNeeded(
            for: snapshot,
            target: &activeTarget,
            appIsFrontmost: appIsFrontmost
        )
        self.activeTarget = activeTarget
        return (activeTarget, activated)
    }

    private func replaceActiveTarget(_ next: ActiveTarget?) {
        let previousTarget = activeTarget
        activeTarget = next
        restoreAndFinish(previousTarget)
    }

    private func frontmostApplicationDidChange(pid: pid_t) {
        let target = actionLock.withLock {
            lock.withLock {
                guard !finished,
                      var activeTarget,
                      activeTarget.pid == pid,
                      activeTarget.backgroundActivation != nil
                else {
                    return nil as ActiveTarget?
                }

                let previousLease = activeTarget
                activeTarget.backgroundActivation = nil
                activeTarget.backgroundActivated = false
                self.activeTarget = activeTarget
                return previousLease
            }
        }

        restoreAndFinish(target)
    }

    private func prepareActivationIfNeeded(
        for snapshot: RuntimeAppSnapshot,
        target: inout ActiveTarget,
        appIsFrontmost: Bool
    ) throws -> Bool {
        guard snapshot.windowID > 0 else {
            return false
        }

        let windowIsMain = isTargetWindowMain(snapshot)

        if appIsFrontmost {
            releaseBackgroundActivation(&target)
            target.backgroundActivated = false
        }

        let needsActivation = if appIsFrontmost {
            !windowIsMain
        } else {
            !target.backgroundActivated || !windowIsMain
        }

        guard needsActivation else { return false }

        if appIsFrontmost {
            BackgroundActivationSession.activateWindow(
                targetPID: snapshot.app.processIdentifier,
                windowNumber: snapshot.windowID,
                windowFrame: snapshot.windowFrame
            )
        } else {
            let activation = try ensureBackgroundActivation(for: snapshot, target: &target)
            activation.activateWindow(
                windowNumber: snapshot.windowID,
                windowFrame: snapshot.windowFrame
            )
            target.backgroundActivated = true
        }
        return true
    }

    private func ensureBackgroundActivation(
        for snapshot: RuntimeAppSnapshot,
        target: inout ActiveTarget
    ) throws -> BackgroundActivationSession {
        if let activation = target.backgroundActivation {
            return activation
        }

        let activation = try BackgroundActivationSession.start(
            targetPID: snapshot.app.processIdentifier
        )
        activation.beginTargetDelivery()
        target.backgroundActivation = activation
        return activation
    }

    private func releaseBackgroundActivation(_ target: inout ActiveTarget) {
        guard target.backgroundActivation != nil else { return }
        let lease = target
        target.backgroundActivation = nil
        target.backgroundActivated = false
        restoreAndFinish(lease)
    }

    private func isTargetAppFrontmost(_ snapshot: RuntimeAppSnapshot) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.app.processIdentifier
    }

    private func isTargetWindowMain(_ snapshot: RuntimeAppSnapshot) -> Bool {
        if cuBoolAttribute(snapshot.windowElement, name: kAXMainAttribute as String) == true {
            return true
        }

        if let mainWindow = cuAttribute(
            snapshot.appElement,
            name: kAXMainWindowAttribute as String
        ) as AXUIElement?, CFEqual(mainWindow, snapshot.windowElement) {
            return true
        }

        return false
    }

    private func restoreAndFinish(_ target: ActiveTarget?) {
        guard let target else { return }
        guard let activation = target.backgroundActivation else { return }
        activation.restoreBackgroundActivationIfNeeded(
            windowNumber: target.windowNumber
        )
        activation.finish()
    }
}

struct HarnessLabelEntry: Equatable, Sendable {
    var key: String
    var display: String
}

func harnessAnnotation(
    metadata: ComputerUseSnapshotMetadata,
    observationSequence: Int,
    initialLabels: [HarnessLabelEntry],
    previousLabels: [HarnessLabelEntry]?,
    recentActions: [String]
) -> String {
    let candidateLines = harnessCandidateLines(from: metadata)
    let sincePrevious = harnessDeltaLines(
        current: harnessLabelEntries(from: metadata),
        baseline: previousLabels
    )
    let sinceInitial = harnessDeltaLines(
        current: harnessLabelEntries(from: metadata),
        baseline: initialLabels
    )

    var lines: [String] = [
        "<computer_use_harness>",
        "Observation #\(observationSequence) for \(metadata.appName) window_id=\(metadata.windowID).",
        "For traversal, keep your own visited set using stable visible labels/descriptions, not element indexes.",
        "If the task requires clicking/opening rows, count a row as visited only after a successful action result or current selected/opened state confirms it.",
    ]

    if recentActions.isEmpty == false {
        lines.append("<recent_actions>")
        lines.append(contentsOf: recentActions.suffix(8).map { "- \($0)" })
        lines.append("</recent_actions>")
    }

    if candidateLines.isEmpty == false {
        lines.append("<candidate_targets>")
        lines.append(contentsOf: candidateLines)
        lines.append("</candidate_targets>")
    }

    lines.append("<state_delta since=\"previous\">")
    lines.append("The following is an incremental difference from the previous element tree, with + and - representing added and removed stable labels.")
    lines.append(contentsOf: sincePrevious)
    lines.append("</state_delta>")

    lines.append("<state_delta since=\"initial\">")
    lines.append("The following is a cumulative difference from the initial element tree, with + and - representing added and removed stable labels.")
    lines.append(contentsOf: sinceInitial)
    lines.append("</state_delta>")
    lines.append("</computer_use_harness>")
    return lines.joined(separator: "\n")
}

func harnessLabelEntries(from metadata: ComputerUseSnapshotMetadata) -> [HarnessLabelEntry] {
    var seen = Set<String>()
    var entries: [HarnessLabelEntry] = []
    for signature in metadata.nodeSignatures {
        let display = harnessDisplayLabel(for: signature)
        guard display.isEmpty == false else { continue }
        let key = harnessStableKey(display)
        guard key.isEmpty == false, seen.insert(key).inserted else { continue }
        entries.append(HarnessLabelEntry(key: key, display: display))
    }
    return entries
}

func harnessCandidateLines(
    from metadata: ComputerUseSnapshotMetadata,
    limit: Int = 64
) -> [String] {
    var seen = Set<String>()
    var lines: [String] = []
    for (index, signature) in metadata.nodeSignatures.enumerated() {
        let display = harnessDisplayLabel(for: signature)
        guard display.isEmpty == false,
              harnessIsCandidateTarget(signature),
              seen.insert(harnessStableKey(display)).inserted
        else {
            continue
        }

        let role = harnessRoleName(signature.role)
        lines.append("- element_index=\(index) \(role) \"\(harnessTruncate(display, maxLength: 160))\"")
        if lines.count >= limit { break }
    }
    return lines
}

private func harnessDeltaLines(
    current: [HarnessLabelEntry],
    baseline: [HarnessLabelEntry]?
) -> [String] {
    guard let baseline else {
        return ["initial observation for this window."]
    }

    let currentKeys = Set(current.map(\.key))
    let baselineKeys = Set(baseline.map(\.key))
    let added = current.filter { !baselineKeys.contains($0.key) }
    let removed = baseline.filter { !currentKeys.contains($0.key) }

    guard added.isEmpty == false || removed.isEmpty == false else {
        return ["no stable label changes."]
    }

    var lines: [String] = []
    if added.isEmpty == false {
        lines.append("+ added:")
        lines.append(contentsOf: added.prefix(16).map {
            "+ \"\(harnessTruncate($0.display, maxLength: 160))\""
        })
        if added.count > 16 {
            lines.append("+ ... \(added.count - 16) more")
        }
    }
    if removed.isEmpty == false {
        lines.append("- removed:")
        lines.append(contentsOf: removed.prefix(16).map {
            "- \"\(harnessTruncate($0.display, maxLength: 160))\""
        })
        if removed.count > 16 {
            lines.append("- ... \(removed.count - 16) more")
        }
    }
    return lines
}

func harnessDisplayLabel(for signature: CachedNodeSignature) -> String {
    let title = harnessNormalizeDisplay(signature.title)
    let description = harnessNormalizeDisplay(signature.description ?? "")
    let identifier = harnessNormalizeDisplay(signature.identifier)

    if description.isEmpty == false,
       (title.isEmpty || description.count > title.count + 8 || description.localizedCaseInsensitiveContains(title)) {
        return description
    }
    if title.isEmpty == false {
        return title
    }
    if description.isEmpty == false {
        return description
    }
    return identifier
}

private func harnessIsCandidateTarget(_ signature: CachedNodeSignature) -> Bool {
    switch signature.role {
    case "AXButton",
         "AXRadioButton",
         "AXCheckBox",
         "AXPopUpButton",
         "AXMenuButton",
         "AXMenuItem",
         "AXLink",
         "AXTextField",
         "AXTextArea",
         "AXComboBox",
         "AXGroup",
         "AXRow",
         "AXCell",
         "AXList",
         "AXOutline",
         "AXTable",
         "AXTabGroup":
        return true
    default:
        return false
    }
}

private func harnessNormalizeDisplay(_ value: String) -> String {
    value
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { $0.isEmpty == false }
        .joined(separator: " ")
}

private func harnessStableKey(_ value: String) -> String {
    harnessNormalizeDisplay(value).lowercased()
}

func harnessRoleName(_ role: String) -> String {
    let stripped = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
    return stripped.isEmpty ? "element" : stripped.lowercased()
}

func harnessTruncate(_ value: String, maxLength: Int) -> String {
    guard value.count > maxLength else { return value }
    let end = value.index(value.startIndex, offsetBy: maxLength)
    return String(value[..<end]) + "..."
}
