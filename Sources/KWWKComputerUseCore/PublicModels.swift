import CoreGraphics
import Foundation

public struct ComputerUseSnapshotMetadata: Codable, Equatable, Sendable {
    public var id: String
    public var createdAt: Date
    public var appName: String
    public var bundleID: String
    public var pid: pid_t
    public var windowTitle: String
    public var windowID: Int
    public var windowFrame: CGRectCodable
    public var screenshotPath: String?
    public var screenshotSize: CGSizeCodable?
    public var fingerprint: String
    public var nodeSignatures: [CachedNodeSignature]

    public init(
        id: String,
        createdAt: Date,
        appName: String,
        bundleID: String,
        pid: pid_t,
        windowTitle: String,
        windowID: Int,
        windowFrame: CGRectCodable,
        screenshotPath: String?,
        screenshotSize: CGSizeCodable?,
        fingerprint: String,
        nodeSignatures: [CachedNodeSignature]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.appName = appName
        self.bundleID = bundleID
        self.pid = pid
        self.windowTitle = windowTitle
        self.windowID = windowID
        self.windowFrame = windowFrame
        self.screenshotPath = screenshotPath
        self.screenshotSize = screenshotSize
        self.fingerprint = fingerprint
        self.nodeSignatures = nodeSignatures
    }
}

public struct CachedNodeSignature: Codable, Equatable, Sendable {
    public var depth: Int
    public var role: String
    public var subrole: String
    public var title: String
    public var description: String?
    public var identifier: String
    public var childIndexAmongSameRole: Int

    public init(
        depth: Int,
        role: String,
        subrole: String,
        title: String,
        description: String?,
        identifier: String,
        childIndexAmongSameRole: Int
    ) {
        self.depth = depth
        self.role = role
        self.subrole = subrole
        self.title = title
        self.description = description
        self.identifier = identifier
        self.childIndexAmongSameRole = childIndexAmongSameRole
    }
}

public struct CGRectCodable: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

public struct CGPointCodable: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

public struct CGSizeCodable: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(_ size: CGSize) {
        width = size.width
        height = size.height
    }

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var cgSize: CGSize {
        CGSize(width: width, height: height)
    }
}

public enum ComputerUseError: Error, CustomStringConvertible, LocalizedError {
    case accessibilityPermissionDenied
    case appNotFound(String)
    case appNotRunning(String)
    case windowNotFound(app: String, title: String?)
    case snapshotNotFound(String)
    case staleState(appName: String)
    case screenshotUnavailable(windowID: Int)
    case coordinateActionRequiresScreenshot
    case elementNotFound(Int)
    case elementFrameUnavailable(Int)
    case elementNotSettable(Int)
    case elementNotScrollable(Int)
    case focusedElementUnavailable
    case secondaryActionNotFound(elementIndex: Int, action: String)
    case unsupportedKey(String)
    case invalidArgument(String)
    case snapshotStoreFailure(String)

    public var description: String {
        switch self {
        case .accessibilityPermissionDenied:
            return "Accessibility permission is required. Grant Accessibility access to the current process in System Settings > Privacy & Security > Accessibility."
        case let .appNotFound(app):
            return "appNotFound \(app)"
        case let .appNotRunning(app):
            return "appNotRunning \(app)"
        case let .windowNotFound(app, title):
            if let title, title.isEmpty == false {
                return "windowNotFound app=\(app) title~\"\(title)\""
            }
            return "windowNotFound app=\(app)"
        case let .snapshotNotFound(id):
            return "snapshotNotFound \(id)"
        case let .staleState(appName):
            return "The user changed '\(appName)'. Re-query the latest state with get-app-state before sending more actions."
        case let .screenshotUnavailable(windowID):
            return "screenshotUnavailable windowID=\(windowID)"
        case .coordinateActionRequiresScreenshot:
            return "coordinateActionRequiresScreenshot: call get-app-state with include_screenshot=true before coordinate click/drag"
        case let .elementNotFound(index):
            return "elementNotFound \(index)"
        case let .elementFrameUnavailable(index):
            return "elementFrameUnavailable \(index)"
        case let .elementNotSettable(index):
            return "elementNotSettable \(index)"
        case let .elementNotScrollable(index):
            return "elementNotScrollable \(index)"
        case .focusedElementUnavailable:
            return "focusedElementUnavailable"
        case let .secondaryActionNotFound(elementIndex, action):
            return "secondaryActionNotFound element=\(elementIndex) action=\"\(action)\""
        case let .unsupportedKey(key):
            return "unsupportedKey \(key)"
        case let .invalidArgument(message):
            return "invalidArgument \(message)"
        case let .snapshotStoreFailure(message):
            return "snapshotStoreFailure \(message)"
        }
    }

    public var errorDescription: String? {
        description
    }
}

public struct RunningAppDescriptor: Equatable, Sendable {
    public var name: String
    public var bundleID: String
    public var pid: pid_t
    public var isActive: Bool

    public init(name: String, bundleID: String, pid: pid_t, isActive: Bool) {
        self.name = name
        self.bundleID = bundleID
        self.pid = pid
        self.isActive = isActive
    }
}

public struct ComputerUseAppDescriptor: Equatable, Sendable {
    public var name: String
    public var bundleID: String
    public var pid: pid_t?
    public var isRunning: Bool
    public var isFrontmost: Bool
    public var lastUsedDate: Date?
    public var useCount: Int?

    public init(
        name: String,
        bundleID: String,
        pid: pid_t?,
        isRunning: Bool,
        isFrontmost: Bool,
        lastUsedDate: Date?,
        useCount: Int?
    ) {
        self.name = name
        self.bundleID = bundleID
        self.pid = pid
        self.isRunning = isRunning
        self.isFrontmost = isFrontmost
        self.lastUsedDate = lastUsedDate
        self.useCount = useCount
    }
}

public struct ComputerUseWindowDescriptor: Equatable, Sendable {
    public var appName: String
    public var bundleID: String
    public var pid: pid_t
    public var windowID: Int
    public var title: String
    public var isMain: Bool

    public init(
        appName: String,
        bundleID: String,
        pid: pid_t,
        windowID: Int,
        title: String,
        isMain: Bool
    ) {
        self.appName = appName
        self.bundleID = bundleID
        self.pid = pid
        self.windowID = windowID
        self.title = title
        self.isMain = isMain
    }
}

public struct ComputerUseState: Codable, Equatable, Sendable {
    public var metadata: ComputerUseSnapshotMetadata
    public var focusedElementIndex: Int?
    public var selectedText: String?
    public var nodes: [ComputerUseNode]

    public init(
        metadata: ComputerUseSnapshotMetadata,
        focusedElementIndex: Int?,
        selectedText: String?,
        nodes: [ComputerUseNode]
    ) {
        self.metadata = metadata
        self.focusedElementIndex = focusedElementIndex
        self.selectedText = selectedText
        self.nodes = nodes
    }
}

public struct ComputerUseNode: Codable, Equatable, Sendable {
    public var index: Int
    public var parentIndex: Int?
    public var depth: Int
    public var role: String
    public var subrole: String
    public var title: String
    public var description: String
    public var value: String?
    public var help: String
    public var identifier: String
    public var url: String?
    public var enabled: Bool?
    public var selected: Bool?
    public var expanded: Bool?
    public var focused: Bool?
    public var frame: CGRectCodable?
    public var actions: [String]
    public var isValueSettable: Bool
    public var valueTypeDescription: String?

    public init(
        index: Int,
        parentIndex: Int?,
        depth: Int,
        role: String,
        subrole: String,
        title: String,
        description: String,
        value: String?,
        help: String,
        identifier: String,
        url: String?,
        enabled: Bool?,
        selected: Bool?,
        expanded: Bool?,
        focused: Bool?,
        frame: CGRectCodable?,
        actions: [String],
        isValueSettable: Bool,
        valueTypeDescription: String?
    ) {
        self.index = index
        self.parentIndex = parentIndex
        self.depth = depth
        self.role = role
        self.subrole = subrole
        self.title = title
        self.description = description
        self.value = value
        self.help = help
        self.identifier = identifier
        self.url = url
        self.enabled = enabled
        self.selected = selected
        self.expanded = expanded
        self.focused = focused
        self.frame = frame
        self.actions = actions
        self.isValueSettable = isValueSettable
        self.valueTypeDescription = valueTypeDescription
    }
}

public struct ComputerUseCommandOutput: Codable, Sendable {
    public var text: String
    public var metadata: ComputerUseSnapshotMetadata?

    public init(text: String, metadata: ComputerUseSnapshotMetadata? = nil) {
        self.text = text
        self.metadata = metadata
    }
}
