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

        let lines = presentationRows(for: snapshot.nodes, focusedIndex: snapshot.focusedElementIndex)
            .map { format(node: $0.node, displayDepth: $0.displayDepth) }
        return """
        App=\(snapshot.app.bundleIdentifier ?? appName) (pid \(snapshot.app.processIdentifier))
        Window: "\(snapshot.windowTitle)", App: \(appName).
        \(lines.joined(separator: "\n"))\(focusedLine)\(selectedTextLine)
        """
    }

    private struct PresentationRow {
        let node: RuntimeAXNode
        let displayDepth: Int
    }

    private static func presentationRows(
        for nodes: [RuntimeAXNode],
        focusedIndex: Int?
    ) -> [PresentationRow] {
        var result: [PresentationRow] = []
        var visibleDepthBySourceDepth: [Int: Int] = [:]
        var lastVisibleAncestorBySourceDepth: [Int: RuntimeAXNode] = [:]
        let singleCellRowCellIndexes = singleCellRowCellIndexes(in: nodes)

        for node in nodes {
            for staleDepth in Array(visibleDepthBySourceDepth.keys) where staleDepth >= node.depth {
                visibleDepthBySourceDepth[staleDepth] = nil
                lastVisibleAncestorBySourceDepth[staleDepth] = nil
            }

            let visibleAncestorDepth = nearestVisibleAncestorDepth(
                forSourceDepth: node.depth,
                visibleDepthBySourceDepth: visibleDepthBySourceDepth
            )
            let parentVisibleDepth = visibleAncestorDepth.map { visibleDepthBySourceDepth[$0] ?? -1 } ?? -1
            let displayDepth = max(0, parentVisibleDepth + 1)
            let parent = visibleAncestorDepth.flatMap { lastVisibleAncestorBySourceDepth[$0] }

            if shouldPresent(
                node,
                focusedIndex: focusedIndex,
                visibleParent: parent,
                collapseSingleCell: singleCellRowCellIndexes.contains(node.index)
            ) {
                result.append(PresentationRow(node: node, displayDepth: displayDepth))
                visibleDepthBySourceDepth[node.depth] = displayDepth
                lastVisibleAncestorBySourceDepth[node.depth] = node
            }
        }

        return result
    }

    private static func nearestVisibleAncestorDepth(
        forSourceDepth sourceDepth: Int,
        visibleDepthBySourceDepth: [Int: Int]
    ) -> Int? {
        guard sourceDepth > 0 else { return nil }
        for depth in stride(from: sourceDepth - 1, through: 0, by: -1) {
            if visibleDepthBySourceDepth[depth] != nil {
                return depth
            }
        }
        return nil
    }

    private static func shouldPresent(
        _ node: RuntimeAXNode,
        focusedIndex: Int?,
        visibleParent: RuntimeAXNode?,
        collapseSingleCell: Bool
    ) -> Bool {
        if node.depth == 0 ||
            node.index == focusedIndex ||
            node.focused == true ||
            node.selected == true ||
            node.isValueSettable {
            return true
        }

        if collapseSingleCell {
            return false
        }

        if isMenuRole(node.role) {
            return true
        }

        if isTableStructureRole(node.role) {
            return true
        }

        if isRedundantLeaf(node, visibleParent: visibleParent) {
            return false
        }

        if isPrimaryControlRole(node.role) {
            return hasDisplaySignal(node) || node.enabled != false
        }

        if isTextRole(node.role) {
            return hasDisplaySignal(node)
        }

        if isImageRole(node.role) {
            return hasStrongDisplaySignal(node)
        }

        if roleCanContainVisibleDescendants(node.role) {
            return hasStrongDisplaySignal(node)
        }

        return hasDisplaySignal(node) || node.enabled == false || node.expanded != nil
    }

    private static func singleCellRowCellIndexes(in nodes: [RuntimeAXNode]) -> Set<Int> {
        var result = Set<Int>()
        for (position, node) in nodes.enumerated() where node.role == kAXRowRole as String {
            var directCellIndexes: [Int] = []
            var cursor = position + 1
            while cursor < nodes.count, nodes[cursor].depth > node.depth {
                let child = nodes[cursor]
                if child.depth == node.depth + 1,
                   child.role == kAXCellRole as String {
                    directCellIndexes.append(child.index)
                }
                cursor += 1
            }
            if directCellIndexes.count == 1,
               let index = directCellIndexes.first {
                result.insert(index)
            }
        }
        return result
    }

    private static func format(node: RuntimeAXNode, displayDepth: Int) -> String {
        let indent = String(repeating: "\t", count: displayDepth)
        let stateDescription = describeStates(node)
        let primary = primaryLabel(for: node)
        let suffixParts = describeDetails(node, primaryLabel: primary)
        let suffix = suffixParts.isEmpty ? "" : " " + suffixParts.joined(separator: ", ")
        let label = displayLabel(for: node)
        let labelPart = [label, primary].filter { !$0.isEmpty }.joined(separator: " ")
        return "\(indent)\(node.index)\(labelPart.isEmpty ? "" : " \(labelPart)")\(stateDescription)\(suffix)"
    }

    private static let primaryControlRoles: Set<String> = [
        kAXButtonRole as String,
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXPopUpButtonRole as String,
        kAXComboBoxRole as String,
        kAXSliderRole as String,
        kAXIncrementorRole as String,
        kAXScrollBarRole as String,
        "AXLink",
        "AXMenuButton",
    ]

    private static func isPrimaryControlRole(_ role: String) -> Bool {
        primaryControlRoles.contains(role)
    }

    private static func isTextRole(_ role: String) -> Bool {
        role == kAXStaticTextRole as String ||
            role == kAXHeadingRole as String
    }

    private static func isTextInputRole(_ role: String) -> Bool {
        role == kAXTextFieldRole as String ||
            role == kAXTextAreaRole as String
    }

    private static func isImageRole(_ role: String) -> Bool {
        role == kAXImageRole as String
    }

    private static func isMenuRole(_ role: String) -> Bool {
        role == kAXMenuBarRole as String ||
            role == kAXMenuRole as String ||
            role == kAXMenuItemRole as String ||
            role == kAXMenuBarItemRole as String
    }

    private static func isTableStructureRole(_ role: String) -> Bool {
        role == kAXRowRole as String ||
            role == kAXCellRole as String ||
            role == kAXColumnRole as String
    }

    private static func hasDisplaySignal(_ node: RuntimeAXNode) -> Bool {
        primaryLabel(for: node).isEmpty == false ||
            describeDetails(node, primaryLabel: "").isEmpty == false ||
            node.enabled == false ||
            node.expanded != nil
    }

    private static func hasStrongDisplaySignal(_ node: RuntimeAXNode) -> Bool {
        primaryLabel(for: node).isEmpty == false ||
            node.url != nil ||
            meaningfulIdentifier(node.identifier) != nil ||
            node.help.isEmpty == false ||
            node.enabled == false ||
            node.expanded != nil ||
            node.collectionSummary != nil
    }

    private static func isRedundantLeaf(_ node: RuntimeAXNode, visibleParent: RuntimeAXNode?) -> Bool {
        guard let visibleParent,
              node.role == kAXStaticTextRole as String || node.role == kAXImageRole as String
        else {
            return false
        }

        let childLabel = normalizeDisplay(primaryLabel(for: node))
        guard childLabel.isEmpty == false else {
            return node.role == kAXImageRole as String
        }

        let parentLabel = normalizeDisplay(primaryLabel(for: visibleParent))
        return parentLabel == childLabel || parentLabel.contains(childLabel)
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
