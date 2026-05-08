# KWWKComputerUseCore

[![CI](https://github.com/EYHN/kwwk-computer-use-core/actions/workflows/ci.yml/badge.svg)](https://github.com/EYHN/kwwk-computer-use-core/actions/workflows/ci.yml)

Swift macOS computer-use runtime for driving native apps through Accessibility
snapshots and background input delivery.

This package contains only the core runtime: action functions, snapshot/session
management, background mouse/keyboard dispatch, screenshot capture, and app/window
discovery. It intentionally does not depend on kwwk, agent frameworks, or AI SDKs.

## Requirements

- macOS 14 or newer.
- Swift 6.1 or newer.
- Accessibility permission for the calling process.

## Installation

Add the package to `Package.swift`:

```swift
.package(url: "https://github.com/EYHN/kwwk-computer-use-core.git", branch: "main")
```

Then add `KWWKComputerUseCore` to your target dependencies:

```swift
.product(name: "KWWKComputerUseCore", package: "kwwk-computer-use-core")
```

After version tags are published, prefer a semver requirement:

```swift
.package(url: "https://github.com/EYHN/kwwk-computer-use-core.git", from: "0.1.0")
```

## Usage

Structured product integration:

```swift
import KWWKComputerUseCore

let cu = ComputerUseClient()
defer { cu.finish() }

let state = try cu.state(app: "Google Chrome")
let button = state.nodes.first {
    $0.role == "AXButton" && $0.title == "Reload"
}

if let button {
    try await cu.click(snapshotID: state.metadata.id, elementIndex: button.index)
}
```

Agent-facing formatted output:

```swift
import KWWKComputerUseCore

let cu = ComputerUseClient()
defer { cu.finish() }

let state = try cu.getAppState(app: "Google Chrome")
let snapshotID = state.metadata!.id

try await cu.click(snapshotID: snapshotID, elementIndex: 171)
try await cu.pressKey(snapshotID: snapshotID, key: "Escape")
```

## Actions

- `listApps()`
- `apps()`
- `runningApps()`
- `openApp(_:)`
- `listWindows(app:)`
- `windows(app:)`
- `getAppState(app:windowTitle:includeScreenshot:)`
- `state(app:windowTitle:includeScreenshot:)`
- `click(snapshotID:elementIndex:)`
- `click(snapshotID:x:y:)`
- `typeText(snapshotID:text:elementIndex:)`
- `setValue(snapshotID:elementIndex:value:)`
- `pressKey(snapshotID:key:)`
- `scroll(snapshotID:elementIndex:direction:pages:)`
- `performSecondaryAction(snapshotID:elementIndex:action:)`
- `drag(snapshotID:fromX:fromY:toX:toY:)`

The calling process needs macOS Accessibility permission for most actions.
Use `apps()`, `runningApps()`, `windows(app:)`, and `state(app:)` when
integrating from product code that needs structured values instead of
agent-facing formatted text.
Coordinate `click` and `drag` calls require a snapshot captured with
`includeScreenshot: true`; element-index actions only need the snapshot metadata.

## Testing

Run the default test suite:

```bash
swift package describe
swift test --explicit-target-dependency-import-check error
swift build -c release --explicit-target-dependency-import-check error
```

The default tests avoid real GUI side effects. End-to-end GUI probe tests are
available for local development:

```bash
KWWK_COMPUTER_USE_CORE_RUN_GUI_PROBE_TESTS=1 swift test --filter InProcessComputerUseBehaviorTests
```

Those tests require Accessibility permission and prebuilt probe apps under
`/private/tmp/kwwk-activation-probe`.

## Architecture

`ComputerUseClient` is the product-facing facade. It owns a
`ComputerUseSession`, so a sequence of actions can share background activation
and focus suppression state.

Lower-level callers can use `ComputerUseAction` directly when they need to
manage sessions themselves. The library intentionally returns
`ComputerUseCommandOutput` with both formatted text and structured metadata so
agent adapters can choose their own schema without coupling the core package to
any one framework.

## License

MIT
