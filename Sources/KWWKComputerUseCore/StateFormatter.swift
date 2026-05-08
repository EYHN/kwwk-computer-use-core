import ApplicationServices
import Foundation

enum ComputerUseStateFormatter {
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
            \(selectedText)
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
        let suffixParts = describeDetails(node)
        let suffix = suffixParts.isEmpty ? "" : " " + suffixParts.joined(separator: ", ")
        let label = displayLabel(for: node)
        let labelPart = label.isEmpty ? "" : " \(label)"
        return "\(indent)\(node.index)\(labelPart)\(stateDescription)\(suffix)"
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

    private static func describeDetails(_ node: RuntimeAXNode) -> [String] {
        var details: [String] = []

        if node.title.isEmpty == false,
           node.role != kAXMenuBarItemRole as String
        {
            details.append(node.title)
        }

        if node.description.isEmpty == false,
           node.description != node.title
        {
            details.append("Description: \(node.description)")
        }

        if node.identifier.isEmpty == false {
            details.append("ID: \(node.identifier)")
        }

        if node.help.isEmpty == false {
            details.append("Help: \(node.help)")
        }

        if let url = node.url {
            details.append("URL: \(url.absoluteString)")
        }

        if ProcessInfo.processInfo.environment["KWWK_COMPUTER_USE_CORE_INCLUDE_FRAMES"] == "1",
           let frame = node.frame
        {
            details.append("Frame: \(stableRectString(frame))")
        }

        let valueString = stringifyValue(node.value)
        if valueString.isEmpty == false,
           valueString != node.title
        {
            details.append("Value: \(valueString)")
        }

        let secondaryActions = node.actions
            .map(displayName(forAction:))
            .filter { $0.caseInsensitiveCompare("Press") != .orderedSame }

        if secondaryActions.isEmpty == false {
            details.append("Secondary Actions: \(secondaryActions.joined(separator: ", "))")
        }

        return details
    }
}
