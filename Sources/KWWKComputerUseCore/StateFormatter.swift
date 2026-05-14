import ApplicationServices
import Foundation

enum ComputerUseStateFormatter {
    private static let primaryLabelLimit = 240
    private static let detailValueLimit = 500
    private static let selectedTextLimit = 2_000

    static func format(snapshot: RuntimeAppSnapshot) -> String {
        let appName = snapshot.app.localizedName ?? snapshot.app.bundleIdentifier ?? "Unknown"
        let focusedLine = if let focusedIndex = snapshot.focusedElementIndex,
                             let focusedNode = try? snapshot.node(index: focusedIndex)
        {
            "\nThe focused UI element is \(focusedIndex) \(describeRole(focusedNode.role))."
        } else {
            ""
        }

        let selectedTextLine = if let selectedText = snapshot.selectedText, selectedText.isEmpty == false {
            """

            Selected text: ```
            \(truncate(selectedText, limit: selectedTextLimit))
            ```
            """
        } else {
            ""
        }

        let lines = snapshot.nodes.map(format(node:))
        return """
        App=\(snapshot.app.bundleIdentifier ?? appName) (pid \(snapshot.app.processIdentifier))
        Window: "\(snapshot.windowTitle)", App: \(appName).
        \(lines.joined(separator: "\n"))\(focusedLine)\(selectedTextLine)
        """
    }

    private static func format(node: RuntimeAXNode) -> String {
        let indent = String(repeating: "\t", count: node.depth)
        let stateDescription = describeStates(node)
        let primary = primaryLabel(for: node)
        let suffixParts = describeDetails(node, primaryLabel: primary)
        let suffix = suffixParts.isEmpty ? "" : " " + suffixParts.joined(separator: ", ")
        let label = displayLabel(for: node)
        let labelPart = [label, primary].filter { !$0.isEmpty }.joined(separator: " ")
        return "\(indent)\(node.index)\(labelPart.isEmpty ? "" : " \(labelPart)")\(stateDescription)\(suffix)"
    }

    private static func displayLabel(for node: RuntimeAXNode) -> String {
        if node.role == kAXMenuBarItemRole as String,
           node.title.isEmpty == false {
            return node.title
        }
        if node.role == kAXMenuItemRole as String,
           node.title.isEmpty == false {
            return ""
        }
        return describeRole(node.role)
    }

    private static func primaryLabel(for node: RuntimeAXNode) -> String {
        if node.role == kAXMenuItemRole as String ||
            node.role == kAXMenuBarItemRole as String {
            return ""
        }

        let valueString = stringifyValue(node.value)
        let candidates = [
            node.title,
            node.description,
            node.help,
            valueString,
            meaningfulIdentifier(node.identifier) ?? "",
        ]

        let primary = candidates
            .map { truncate(normalizeDisplay($0), limit: primaryLabelLimit) }
            .first { !$0.isEmpty } ?? ""

        guard let collectionSummary = node.collectionSummary else {
            return primary
        }

        if primary.isEmpty {
            return "(\(collectionSummary))"
        }
        return "\(primary) (\(collectionSummary))"
    }

    private static func describeStates(_ node: RuntimeAXNode) -> String {
        var states: [String] = []

        if node.enabled == false {
            states.append("disabled")
        }
        if node.selected == true {
            states.append("selected")
        }
        if node.expanded == true {
            states.append("expanded")
        }
        if node.isValueSettable {
            states.append("settable")
        }
        if let valueTypeDescription = node.valueTypeDescription, node.isValueSettable {
            states.append(valueTypeDescription)
        }

        guard states.isEmpty == false else {
            return ""
        }
        return " (\(states.joined(separator: ", ")))"
    }

    private static func describeDetails(_ node: RuntimeAXNode, primaryLabel: String) -> [String] {
        var details: [String] = []

        if node.title.isEmpty == false,
           node.role != kAXMenuBarItemRole as String,
           !primaryLabelContains(node.title, primaryLabel: primaryLabel)
        {
            details.append(truncate(normalizeDisplay(node.title), limit: detailValueLimit))
        }

        if node.description.isEmpty == false,
           node.description != node.title,
           !primaryLabelContains(node.description, primaryLabel: primaryLabel)
        {
            details.append("Description: \(truncate(normalizeDisplay(node.description), limit: detailValueLimit))")
        }

        if let identifier = meaningfulIdentifier(node.identifier),
           !primaryLabelContains(identifier, primaryLabel: primaryLabel) {
            details.append("ID: \(truncate(identifier, limit: detailValueLimit))")
        }

        if node.help.isEmpty == false,
           !primaryLabelContains(node.help, primaryLabel: primaryLabel) {
            details.append("Help: \(truncate(normalizeDisplay(node.help), limit: detailValueLimit))")
        }

        if let url = node.url {
            details.append("URL: \(truncate(url.absoluteString, limit: detailValueLimit))")
        }

        if ProcessInfo.processInfo.environment["KWWK_COMPUTER_USE_CORE_INCLUDE_FRAMES"] == "1",
           let frame = node.frame
        {
            details.append("Frame: \(stableRectString(frame))")
        }

        let valueString = stringifyValue(node.value)
        if valueString.isEmpty == false,
           valueString != node.title,
           !primaryLabelContains(valueString, primaryLabel: primaryLabel)
        {
            details.append("Value: \(truncate(normalizeDisplay(valueString), limit: detailValueLimit))")
        }

        let secondaryActions = node.actions
            .map(displayName(forAction:))
            .filter(isUsefulSecondaryAction)

        if secondaryActions.isEmpty == false {
            details.append("Secondary Actions: \(secondaryActions.joined(separator: ", "))")
        }

        return details
    }

    private static func normalizeDisplay(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else {
            return value
        }
        let omitted = value.count - limit
        let prefixLength = max(0, limit - 24)
        let prefix = value.prefix(prefixLength)
        return "\(prefix)… [truncated \(omitted) chars]"
    }

    private static func primaryLabelContains(_ value: String, primaryLabel: String) -> Bool {
        let normalizedValue = normalizeDisplay(value)
        guard !normalizedValue.isEmpty else { return true }
        return normalizeDisplay(primaryLabel).contains(normalizedValue)
    }

    private static func meaningfulIdentifier(_ identifier: String) -> String? {
        let value = normalizeDisplay(identifier)
        guard !value.isEmpty,
              !value.hasPrefix("_NS:"),
              !value.hasPrefix("AutomaticTableColumnIdentifier.") else {
            return nil
        }
        return value
    }

    private static func isUsefulSecondaryAction(_ action: String) -> Bool {
        let normalized = action
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !normalized.isEmpty,
              normalized.count <= 80,
              !normalized.contains("Target:"),
              !normalized.contains("Selector:") else {
            return false
        }

        switch normalized.lowercased() {
        case "press",
             "cancel",
             "confirm",
             "pick",
             "show menu",
             "show default u i",
             "show default ui",
             "show alternate u i",
             "show alternate ui",
             "scroll to visible",
             "scroll left",
             "scroll right":
            return false
        default:
            return true
        }
    }
}
