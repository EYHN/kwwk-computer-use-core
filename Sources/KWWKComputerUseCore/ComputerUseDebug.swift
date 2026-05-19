import Foundation

public enum ComputerUseDebug {
    nonisolated(unsafe) private static var focusEnabledStorage = environmentBool("KWWK_COMPUTER_USE_CORE_DEBUG_FOCUS")

    public static var focusEnabled: Bool {
        get {
            focusEnabledStorage
        }
        set {
            focusEnabledStorage = newValue
        }
    }
}

private func environmentBool(_ key: String) -> Bool {
    guard let raw = ProcessInfo.processInfo.environment[key] else {
        return false
    }
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on":
        return true
    default:
        return false
    }
}
