import Foundation
import Testing
import KWWKComputerUseCore

@Suite("Public computer use API")
struct PublicAPITests {
    @Test("public value types can be constructed without testable import")
    func publicValueTypesCanBeConstructed() {
        let signature = CachedNodeSignature(
            depth: 0,
            role: "AXWindow",
            subrole: "",
            title: "Main",
            description: nil,
            identifier: "main-window",
            childIndexAmongSameRole: 0
        )
        let frame = CGRectCodable(x: 10, y: 20, width: 640, height: 480)
        let size = CGSizeCodable(width: 320, height: 240)
        let metadata = ComputerUseSnapshotMetadata(
            id: "snapshot",
            createdAt: Date(timeIntervalSince1970: 0),
            appName: "Probe",
            bundleID: "dev.kwwk.Probe",
            pid: 123,
            windowTitle: "Main",
            windowID: 456,
            windowFrame: frame,
            screenshotPath: nil,
            screenshotSize: size,
            fingerprint: "fingerprint",
            nodeSignatures: [signature]
        )
        let app = ComputerUseAppDescriptor(
            name: "Probe",
            bundleID: "dev.kwwk.Probe",
            pid: 123,
            isRunning: true,
            isFrontmost: false,
            lastUsedDate: nil,
            useCount: nil
        )
        let runningApp = RunningAppDescriptor(
            name: "Probe",
            bundleID: "dev.kwwk.Probe",
            pid: 123,
            isActive: false
        )
        let window = ComputerUseWindowDescriptor(
            appName: "Probe",
            bundleID: "dev.kwwk.Probe",
            pid: 123,
            windowID: 456,
            title: "Main",
            isMain: true
        )

        #expect(metadata.nodeSignatures == [signature])
        #expect(metadata.windowFrame == frame)
        #expect(metadata.screenshotSize == size)
        #expect(app.isRunning)
        #expect(!runningApp.isActive)
        #expect(window.isMain)
    }

    @Test("client exposes structured app queries")
    func clientExposesStructuredAppQueries() {
        let client = ComputerUseClient()
        defer { client.finish() }

        _ = client.apps()
        _ = client.runningApps()
    }
}
