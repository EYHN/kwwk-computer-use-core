import ApplicationServices
import CoreGraphics
import Foundation

func stableRectString(_ rect: CGRect) -> String {
    "\(round(rect.origin.x * 100) / 100),\(round(rect.origin.y * 100) / 100),\(round(rect.width * 100) / 100),\(round(rect.height * 100) / 100)"
}

func stableFingerprintValue(for node: RuntimeAXNode) -> String {
    if node.role == kAXStaticTextRole as String {
        return ""
    }

    if node.isValueSettable {
        return stringifyValue(node.value)
    }

    let valueRelevantRoles: Set<String> = [
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        kAXSliderRole as String,
        kAXScrollBarRole as String,
    ]
    switch node.role {
    case let role where valueRelevantRoles.contains(role):
        return stringifyValue(node.value)
    default:
        return ""
    }
}

func stableFingerprintURL(for node: RuntimeAXNode) -> String {
    guard node.role == kAXTextFieldRole as String else {
        return ""
    }
    return node.url?.absoluteString ?? ""
}

func parentIndicesFromDepths(_ depths: [Int]) -> [Int?] {
    var parents: [Int?] = Array(repeating: nil, count: depths.count)
    var stack: [Int] = []
    for i in 0 ..< depths.count {
        while let top = stack.last, depths[top] >= depths[i] {
            stack.removeLast()
        }
        parents[i] = stack.last
        stack.append(i)
    }
    return parents
}

func childIndicesAmongSameRole(
    roles: [String],
    subroles: [String],
    parents: [Int?]
) -> [Int] {
    var counts: [Int: [String: Int]] = [:]
    var result: [Int] = Array(repeating: 0, count: roles.count)
    for i in 0 ..< roles.count {
        let parentKey = parents[i] ?? -1
        let bucketKey = "\(roles[i])|\(subroles[i])"
        let next = counts[parentKey, default: [:]][bucketKey, default: 0]
        result[i] = next
        counts[parentKey, default: [:]][bucketKey] = next + 1
    }
    return result
}

func nodeSignatures(for nodes: [RuntimeAXNode]) -> [CachedNodeSignature] {
    let depths = nodes.map(\.depth)
    let roles = nodes.map(\.role)
    let subroles = nodes.map(\.subrole)
    let parents = parentIndicesFromDepths(depths)
    let childIndices = childIndicesAmongSameRole(
        roles: roles,
        subroles: subroles,
        parents: parents
    )
    return nodes.enumerated().map { i, node in
        CachedNodeSignature(
            depth: node.depth,
            role: node.role,
            subrole: node.subrole,
            title: node.title,
            description: node.description.isEmpty ? nil : node.description,
            identifier: node.identifier,
            childIndexAmongSameRole: childIndices[i]
        )
    }
}

func resolveFreshElementIndex(
    cachedIndex: Int,
    cached: [CachedNodeSignature],
    fresh: [RuntimeAXNode]
) -> Int? {
    guard cachedIndex >= 0, cachedIndex < cached.count, !fresh.isEmpty else {
        return nil
    }

    let cachedParents = parentIndicesFromDepths(cached.map(\.depth))
    var path: [CachedNodeSignature] = []
    var cursor: Int? = cachedIndex
    while let c = cursor {
        path.append(cached[c])
        cursor = cachedParents[c]
    }
    path.reverse()

    let freshDepths = fresh.map(\.depth)
    let freshParents = parentIndicesFromDepths(freshDepths)
    let freshChildIndices = childIndicesAmongSameRole(
        roles: fresh.map(\.role),
        subroles: fresh.map(\.subrole),
        parents: freshParents
    )

    guard let rootStep = path.first else {
        return nil
    }

    let rootCandidates = fresh.indices.filter {
        fresh[$0].depth == rootStep.depth &&
            matchScore(
                candidate: fresh[$0],
                childIndex: freshChildIndices[$0],
                target: rootStep
            ) >= 0
    }

    for rootCandidate in rootCandidates {
        var freshCursor = rootCandidate
        var matched = true
        for step in path.dropFirst() {
            let children = (0 ..< fresh.count).filter { freshParents[$0] == freshCursor }
            var bestScore = Int.min
            var best: Int?
            for child in children {
                let s = matchScore(
                    candidate: fresh[child],
                    childIndex: freshChildIndices[child],
                    target: step
                )
                if s > bestScore {
                    bestScore = s
                    best = child
                }
            }
            guard let best, bestScore >= 0 else {
                matched = false
                break
            }
            freshCursor = best
        }
        if matched {
            return freshCursor
        }
    }

    return nil
}

private func matchScore(
    candidate: RuntimeAXNode,
    childIndex: Int,
    target: CachedNodeSignature
) -> Int {
    guard candidate.role == target.role else { return Int.min }
    var score = 0

    if !target.subrole.isEmpty {
        if candidate.subrole == target.subrole { score += 2 }
        else if !candidate.subrole.isEmpty { score -= 2 }
    } else if !candidate.subrole.isEmpty {
        score -= 1
    }

    if !target.identifier.isEmpty {
        if candidate.identifier == target.identifier { score += 4 }
        else if !candidate.identifier.isEmpty { score -= 3 }
    }

    if !target.title.isEmpty {
        if candidate.title == target.title { score += 3 }
        else if !candidate.title.isEmpty { score -= 2 }
    }

    if let description = target.description, !description.isEmpty {
        if candidate.description == description { score += 3 }
        else if !candidate.description.isEmpty { score -= 2 }
    }

    if childIndex == target.childIndexAmongSameRole { score += 1 }

    return score
}
