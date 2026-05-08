import Foundation

struct ComputerUseSnapshotFile: Codable {
    var metadata: ComputerUseSnapshotMetadata
}

enum ComputerUseSnapshotStore {
    static var rootURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "kwwk-computer-use-core",
            isDirectory: true
        )
    }

    static func ensureRootDirectory() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    static func metadataURL(for snapshotID: String) -> URL {
        rootURL.appendingPathComponent("\(snapshotID).json")
    }

    static func screenshotURL(for snapshotID: String, pathExtension: String = "png") -> URL {
        let ext = pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "png"
            : pathExtension
        return rootURL.appendingPathComponent("\(snapshotID).\(ext)")
    }

    static func save(snapshot: RuntimeAppSnapshot) throws -> ComputerUseSnapshotMetadata {
        try ensureRootDirectory()

        let snapshotID = UUID().uuidString.lowercased()
        let screenshotPath: String?
        let screenshotSize: CGSizeCodable?

        if let sourceScreenshotURL = snapshot.screenshotURL {
            let targetURL = screenshotURL(
                for: snapshotID,
                pathExtension: sourceScreenshotURL.pathExtension
            )
            if FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.removeItem(at: targetURL)
            }
            try FileManager.default.copyItem(at: sourceScreenshotURL, to: targetURL)
            screenshotPath = targetURL.path
            screenshotSize = snapshot.screenshotSize.map(CGSizeCodable.init)
        } else {
            screenshotPath = nil
            screenshotSize = nil
        }

        let metadata = ComputerUseSnapshotMetadata(
            id: snapshotID,
            createdAt: Date(),
            appName: snapshot.app.localizedName ?? snapshot.app.bundleIdentifier ?? "Unknown",
            bundleID: snapshot.app.bundleIdentifier ?? "",
            pid: snapshot.app.processIdentifier,
            windowTitle: snapshot.windowTitle,
            windowID: snapshot.windowID,
            windowFrame: CGRectCodable(snapshot.windowFrame),
            screenshotPath: screenshotPath,
            screenshotSize: screenshotSize,
            fingerprint: snapshot.fingerprint,
            nodeSignatures: nodeSignatures(for: snapshot.nodes)
        )

        let data = try JSONEncoder.computerUse.encode(ComputerUseSnapshotFile(metadata: metadata))
        try data.write(to: metadataURL(for: snapshotID), options: .atomic)
        return metadata
    }

    static func load(snapshotID: String) throws -> ComputerUseSnapshotMetadata {
        let url = metadataURL(for: snapshotID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ComputerUseError.snapshotNotFound(snapshotID)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.computerUse.decode(ComputerUseSnapshotFile.self, from: data).metadata
    }
}

extension JSONEncoder {
    static var computerUse: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var computerUse: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
