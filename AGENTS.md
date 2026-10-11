# AGENTS.md

This file contains repository-specific guidance for coding agents working on Beacon.

Read [`CONTRIBUTING.md`](CONTRIBUTING.md) as well. It is the source of truth for branch names, commit messages, scopes, pull request titles, and the test commands, and it applies to agents exactly as it applies to human contributors.

## Project overview

Beacon is a native macOS application launcher written in Swift with SwiftUI and AppKit. It runs as a menu-bar accessory, presents a floating launcher panel, indexes local applications, registers a global keyboard shortcut, and opens the selected application or destination.

The project intentionally has no third-party dependencies.

## Requirements

- macOS 26.0 or later
- Xcode 26 or later
- Use the `Beacon` scheme in `Beacon.xcodeproj`

## Important files

- `Beacon/BeaconApp.swift`: application lifecycle, menu-bar entry, and service wiring
- `Beacon/ContentView.swift`: launcher interface, the extensions page, and keyboard interaction
- `Beacon/LauncherModel.swift`: indexing, search, selection, commands, and launching
- `Beacon/LauncherPanelController.swift`: floating AppKit panel behavior
- `Beacon/KeyboardShortcut.swift`: shortcut representation and global registration
- `Beacon/SettingsView.swift`: appearance and shortcut settings, and a link to the extensions page
- `Beacon/Extension.swift`: extension manifest, catalog, item, and action models
- `Beacon/ExtensionManager.swift`: installing, updating, and removing extensions from `beacon-macos/extensions`
- `Beacon/ExtensionRuntime.swift`: JavaScriptCore runtime and host API for extension commands
- `Beacon/Calculator.swift`: arithmetic evaluation and number formatting for the calculator result
- `Beacon/CurrencyConversion.swift`: currency conversion queries and currency names in every language
- `Beacon/ExchangeRates.swift`: downloading and caching daily exchange rates
- `BeaconTests/BeaconTests.swift`, `BeaconTests/ExtensionTests.swift`, `BeaconTests/CalculatorTests.swift`: unit tests using Swift Testing
- `BeaconUITests/`: UI test target
- `.github/workflows/build-and-release.yml`: CI builds and automatic releases on merges to `master`

## Working rules

- Read the relevant implementation and tests before changing behavior.
- Name branches, commits, and pull requests as `CONTRIBUTING.md` specifies: `feat/theme-settings`, `feat(settings): add theme setting with light and dark appearances`.
- Keep changes focused and preserve unrelated user modifications in the worktree.
- Follow the style of the surrounding Swift code; do not add a new architecture, package, or dependency unless the task requires it.
- Keep UI-bound mutable state and AppKit interactions on `@MainActor`.
- Keep slow filesystem discovery and extension scripts away from the main actor.
- Keep the extension host API in `ExtensionRuntime.swift` small and read-only; document any change to it in the `beacon-macos/extensions` CONTRIBUTING guide.
- Preserve keyboard-first behavior: arrow-key navigation, Return to launch, Escape to dismiss, and the configurable global shortcut.
- Preserve accessibility labels and identifiers when changing interactive UI.
- Add or update tests for search normalization, ranking, selection, persistence, and other testable behavior changes.
- Do not edit or commit `xcuserdata`, DerivedData, build products, or generated release packages.
- Do not change signing, entitlements, the deployment target, bundle identifiers, or release behavior unless explicitly requested.
- Do not create or push tags or publish a GitHub Release unless explicitly requested.

## Build and test

Run the unit tests used by CI:

```sh
xcodebuild test \
  -project Beacon.xcodeproj \
  -scheme Beacon \
  -destination 'platform=macOS' \
  -derivedDataPath test-build \
  -only-testing:BeaconTests \
  CODE_SIGNING_ALLOWED=NO
```

Run all configured tests when a change affects user-interface behavior:

```sh
xcodebuild test \
  -project Beacon.xcodeproj \
  -scheme Beacon \
  -destination 'platform=macOS'
```

For UI changes, also launch the app and manually verify the affected flow when the environment permits it.

## Before handing off

- Review `git diff` and ensure only intended files changed.
- Run `git diff --check`.
- Run the most relevant tests, or clearly state why they could not be run.
- Summarize the behavior changed and the verification performed.
