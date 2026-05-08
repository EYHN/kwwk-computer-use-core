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
        let node = ComputerUseNode(
            index: 0,
            parentIndex: nil,
            depth: 0,
            role: "AXWindow",
            subrole: "",
            title: "Main",
            description: "",
            value: nil,
            help: "",
            identifier: "main-window",
            url: nil,
            enabled: true,
            selected: nil,
            expanded: nil,
            focused: true,
            frame: frame,
            actions: ["AXPress"],
            isValueSettable: false,
            valueTypeDescription: nil
        )
        let state = ComputerUseState(
            metadata: metadata,
            focusedElementIndex: 0,
            selectedText: nil,
            nodes: [node]
        )

        #expect(metadata.nodeSignatures == [signature])
        #expect(metadata.windowFrame == frame)
        #expect(metadata.screenshotSize == size)
        #expect(app.isRunning)
        #expect(!runningApp.isActive)
        #expect(window.isMain)
        #expect(state.nodes == [node])
    }

    @Test("client exposes structured app queries")
    func clientExposesStructuredAppQueries() {
        let client = ComputerUseClient()
        defer { client.finish() }

        _ = client.apps()
        _ = client.runningApps()
    }

    @Test("structured state is codable across integration boundaries")
    func structuredStateIsCodableAcrossIntegrationBoundaries() throws {
        let signature = CachedNodeSignature(
            depth: 1,
            role: "AXButton",
            subrole: "",
            title: "Reload",
            description: "Reload this page",
            identifier: "reload-button",
            childIndexAmongSameRole: 2
        )
        let metadata = ComputerUseSnapshotMetadata(
            id: "snapshot",
            createdAt: Date(timeIntervalSince1970: 0),
            appName: "Chrome",
            bundleID: "com.google.Chrome",
            pid: 321,
            windowTitle: "Example",
            windowID: 654,
            windowFrame: CGRectCodable(x: 0, y: 0, width: 1200, height: 800),
            screenshotPath: "/tmp/snapshot.jpg",
            screenshotSize: CGSizeCodable(width: 600, height: 400),
            fingerprint: "abc123",
            nodeSignatures: [signature]
        )
        let node = ComputerUseNode(
            index: 4,
            parentIndex: 1,
            depth: 2,
            role: "AXButton",
            subrole: "",
            title: "Reload",
            description: "Reload this page",
            value: nil,
            help: "Reload",
            identifier: "reload-button",
            url: nil,
            enabled: true,
            selected: false,
            expanded: nil,
            focused: nil,
            frame: CGRectCodable(x: 10, y: 20, width: 30, height: 40),
            actions: ["AXPress"],
            isValueSettable: false,
            valueTypeDescription: nil
        )
        let state = ComputerUseState(
            metadata: metadata,
            focusedElementIndex: nil,
            selectedText: nil,
            nodes: [node]
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ComputerUseState.self, from: data)

        #expect(decoded == state)
    }

    @Test("computer use errors provide localized descriptions")
    func computerUseErrorsProvideLocalizedDescriptions() {
        let error = ComputerUseError.coordinateActionRequiresScreenshot

        #expect(error.errorDescription == error.description)
        #expect((error as NSError).localizedDescription == error.description)
    }

    @Test("visual effect hook wraps actions and finishes with session")
    func visualEffectHookWrapsActionsAndFinishesWithSession() throws {
        let hook = RecordingVisualEffectHook()
        let event = ComputerUseVisualEffectEvent(
            action: .click,
            windowID: 42,
            windowFrame: CGRectCodable(x: 0, y: 0, width: 100, height: 80),
            startPoint: CGPointCodable(x: 10, y: 12)
        )
        var actionDidRun = false

        let result = try hook.perform(event) {
            actionDidRun = hook.events == [.click]
            return "done"
        }
        hook.finish()

        #expect(result == "done")
        #expect(actionDidRun)
        #expect(hook.events == [.click])
        #expect(hook.didFinish)

        let session = ComputerUseSession()
        session.visualEffectHook = hook
        hook.didFinish = false
        session.finish()
        #expect(session.visualEffectHook == nil)
        #expect(hook.didFinish)
    }
}

private final class RecordingVisualEffectHook: ComputerUseVisualEffectHook {
    var events: [ComputerUseVisualEffectAction] = []
    var didFinish = false

    func perform<T>(
        _ event: ComputerUseVisualEffectEvent,
        action: () throws -> T
    ) throws -> T {
        events.append(event.action)
        return try action()
    }

    func finish() {
        didFinish = true
    }
}
