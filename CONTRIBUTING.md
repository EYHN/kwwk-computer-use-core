# Contributing

KWWKComputerUseCore is a macOS-only Swift package. Keep the core library independent
from any agent framework, model provider, or application-specific adapter.

## Development

Run the default test suite and release build before submitting changes:

```bash
swift package describe
swift test --explicit-target-dependency-import-check error
swift build -c release --explicit-target-dependency-import-check error
```

These keep the package manifest parseable, keep declared SwiftPM dependencies
honest, and cover both debug test execution and release compilation. The
default suite is designed to be safe on developer machines and CI. Tests that
drive real GUI applications are gated behind an environment variable:

```bash
KWWK_COMPUTER_USE_CORE_RUN_GUI_PROBE_TESTS=1 swift test --filter InProcessComputerUseBehaviorTests
```

GUI probe tests require:

- macOS Accessibility permission for the test process.
- Probe apps under `/private/tmp/kwwk-activation-probe`.
- A local desktop session. They are not expected to pass on generic CI runners.

## Design Guidelines

- Keep `Sources/KWWKComputerUseCore` free of kwwk, agent, and AI SDK dependencies.
- Prefer public APIs that are usable directly from product code.
- Preserve the snapshot/session model: actions should validate against fresh
  state before acting.
- Keep background behavior explicit and covered by tests when it changes.
- Add narrowly scoped comments only for non-obvious macOS Accessibility or event
  delivery behavior.
