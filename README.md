# Beacon

Beacon is a fast, native application launcher for macOS. Open it from anywhere with a global keyboard shortcut, search installed apps and common destinations, then press Return to launch the selected result.

<img width="766" height="546" alt="image" src="https://github.com/user-attachments/assets/0d85ee99-caac-4c68-9706-3f0f1478a089" />

## Features

- Native SwiftUI and AppKit interface
- Global launcher shortcut (`⌥ Space` by default), including double-tap modifier support
- Search across system and user Applications folders
- Case-insensitive, diacritic-insensitive fuzzy matching
- Quick access to Applications
- Web search fallback in the default browser
- Extensions managed from the launcher, such as opening recent Visual Studio Code projects
- Keyboard navigation with the arrow keys and Return
- Configurable shortcut and manual application reindexing
- Menu-bar operation with no Dock icon

## Requirements

- macOS 26.0 or later
- Xcode 26 or later

## Build and run

1. Clone the repository:

   ```sh
   git clone https://github.com/dhkey/Beacon.git
   cd Beacon
   ```

2. Open `Beacon.xcodeproj` in Xcode.
3. Select the **Beacon** scheme and run the project.

You can also build from the command line:

```sh
xcodebuild -project Beacon.xcodeproj -scheme Beacon -configuration Debug build
```

## Releases

Every push and pull request to `master` is built and tested by GitHub Actions. Every merge to `master` that contains a releasable change automatically creates a GitHub Release containing universal DMG, PKG, and ZIP packages.

### How the version is chosen

The workflow reads the Conventional Commits messages merged since the latest `vMAJOR.MINOR.PATCH` tag. Because pull requests are squash-merged, these are the pull request titles:

| Commits since the last release | Next version |
| --- | --- |
| `type!:` in a title, or a `BREAKING CHANGE:` footer | major, for example `v1.2.0` → `v2.0.0` |
| `feat` | minor, for example `v1.2.0` → `v1.3.0` |
| `fix` or `perf` | patch, for example `v1.2.0` → `v1.2.1` |
| only `docs`, `ci`, `chore`, `refactor`, `test`, `style`, or `build` | no release |

The workflow creates the tag on the merged commit, publishes the release with generated notes, and builds the app with the matching version. Follow the run in [GitHub Actions](https://github.com/dhkey/Beacon/actions); when it succeeds, the new version appears on the [Releases page](https://github.com/dhkey/Beacon/releases). If a run fails, nothing is tagged, and the next releasable merge includes those changes.

### Release manually

To publish a release that the commit history would not produce, such as one containing only documentation changes, push an annotated tag in the exact `vMAJOR.MINOR.PATCH` format on a commit in `master`:

```sh
git tag -a v1.2.1 -m "Beacon 1.2.1"
git push origin v1.2.1
```

## Install a release

1. Download the DMG from the [latest GitHub Release](https://github.com/dhkey/Beacon/releases/latest).
2. Open the DMG and drag **Beacon** into the **Applications** folder.
3. In Applications, Control-click **Beacon**, choose **Open**, and confirm the macOS security prompt.

The PKG provides a guided installer, while the ZIP contains the standalone application. The packages are ad-hoc signed because the project does not use a paid Apple Developer account, so the first-launch security confirmation is unavoidable. Developer ID signing and notarization can be added later without changing the release process.

## Usage

1. Press `⌥ Space` to show or hide Beacon.
2. Type an application or command name.
3. Use `↑` and `↓` to move through results.
4. Press `Return` to open the selected result, or `Esc` to dismiss Beacon.

Open **Beacon Settings** from the launcher or menu-bar item to record a different global shortcut or rebuild the application index.

## Extensions

Extensions add commands to the launcher. Manage them on the launcher's **Extensions** page: search for **Manage Extensions**, or click **Manage Extensions** in Beacon Settings. Press `Return` to install or update the selected extension, `⌘⌫` to uninstall it, and `Esc` to go back. Beacon downloads extensions from the [beacon-macos/extensions](https://github.com/beacon-macos/extensions) repository, which also documents how to write one.

For example, the **Visual Studio Code** extension adds an **Open Recent Project** command. Run it, type to filter your recent projects and workspaces, and press `Return` to open the selected one in Visual Studio Code. Press `Esc` to go back to all results.

Extensions are JavaScript files that Beacon runs with access to your files, so install only extensions you trust.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, testing instructions, and pull request guidelines.

## Tests

Run the unit and UI test targets with:

```sh
xcodebuild test -project Beacon.xcodeproj -scheme Beacon -destination 'platform=macOS'
```

## Project structure

```text
Beacon/
├── BeaconApp.swift                 # App lifecycle and menu-bar entry
├── ContentView.swift               # Launcher interface
├── Extension.swift                 # Extension manifest, catalog, and item models
├── ExtensionManager.swift          # Extension installation and updates
├── ExtensionRuntime.swift          # JavaScriptCore runtime for extension commands
├── KeyboardShortcut.swift          # Shortcut representation and registration
├── LauncherModel.swift             # Indexing, matching, and launch behavior
├── LauncherPanelController.swift   # Floating launcher panel
└── SettingsView.swift              # Shortcut and indexing settings
```

Beacon indexes application metadata locally. A web-search result opens Google in your default browser only when you choose it. Beacon contacts GitHub only to show and install extensions on the Extensions page.
