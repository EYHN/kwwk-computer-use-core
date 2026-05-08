# MacComputerUse

Swift macOS computer-use runtime for driving native apps through Accessibility
snapshots and background input delivery.

This package contains only the core runtime: action functions, snapshot/session
management, background mouse/keyboard dispatch, screenshot capture, and app/window
discovery. It intentionally does not depend on kwwk, agent frameworks, or AI SDKs.

## Usage

```swift
import MacComputerUse

let cu = ComputerUseClient()

let state = try cu.getAppState(app: "Google Chrome")
let snapshotID = state.metadata!.id

try await cu.click(snapshotID: snapshotID, elementIndex: 171)
try await cu.pressKey(snapshotID: snapshotID, key: "Escape")

cu.finish()
```

## Actions

- `listApps()`
- `openApp(_:)`
- `listWindows(app:)`
- `getAppState(app:windowTitle:includeScreenshot:)`
- `click(snapshotID:elementIndex:)`
- `click(snapshotID:x:y:)`
- `typeText(snapshotID:text:elementIndex:)`
- `setValue(snapshotID:elementIndex:value:)`
- `pressKey(snapshotID:key:)`
- `scroll(snapshotID:elementIndex:direction:pages:)`
- `performSecondaryAction(snapshotID:elementIndex:action:)`
- `drag(snapshotID:fromX:fromY:toX:toY:)`

The calling process needs macOS Accessibility permission for most actions.
