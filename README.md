# Beacon

Beacon is a fast, native application launcher for macOS. Open it from anywhere with a global keyboard shortcut, search installed apps and common destinations, then press Return to launch the selected result.

<img width="766" height="546" alt="image" src="https://github.com/user-attachments/assets/0d85ee99-caac-4c68-9706-3f0f1478a089" />

## Features

- Native SwiftUI and AppKit interface
- Global launcher shortcut (`⌥ Space` by default), including double-tap modifier support
- Search across system and user Applications folders
- Case-insensitive, diacritic-insensitive fuzzy matching
- Quick access to Applications
- Calculator and currency conversion, such as `2+2` or `2$ in uah`, in any language
- Clipboard history for the last 100 texts you copied
- Web search fallback in the default browser
- Extensions managed from the launcher, such as opening recent Visual Studio Code projects
- Keyboard navigation with the arrow keys and Return
- Configurable shortcut and manual application reindexing
- Update notices in the launcher, or automatic updates from GitHub Releases
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

The release job signs the ZIP with the Ed25519 private key in the `UPDATE_SIGNING_KEY` repository secret and publishes the signature next to it as `Beacon-vX.Y.Z.zip.sig`. The release fails when the secret is missing or does not match `signingPublicKey` in `Beacon/Updater.swift`.

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

## Updates

Beacon checks the [latest GitHub Release](https://github.com/beacon-macos/Beacon/releases/latest) when it starts and every six hours. When a newer version is out, it appears as the last result in the launcher. Press `Return` on it to download the update, verify it, and relaunch Beacon with the new version. Search for **Check for Updates** to check right away. Beacon installs an update only when its ZIP is signed with the project's release key, so a release file replaced on GitHub by someone without that key is not installed.

Turn on **Install updates automatically** in Beacon Settings to download new versions in the background and relaunch Beacon while you are not using it. Beacon can replace itself only when it can write to its own application folder. Otherwise, such as after installing with the PKG, the update result opens the release page so you can download the new version yourself.

## Usage

1. Press `⌥ Space` to show or hide Beacon.
2. Type an application or command name.
3. Use `↑` and `↓` to move through results.
4. Press `Return` to open the selected result, or `Esc` to dismiss Beacon.

Open **Beacon Settings** from the launcher or menu-bar item to record a different global shortcut or rebuild the application index.

## Calculator

Type arithmetic, such as `2+2`, `(1 + 2) * 3^2`, `200 + 15%`, or `sqrt(2)`, and the first result shows the answer: **2+2 = 4**. Press `Return` to copy it.

Type a currency conversion in any language, such as `2$ in uah`, `100 евро в долларах`, `50 € en dólares`, or `100美元换人民币`, to convert with the latest daily exchange rates. Without a target currency, as in `€20`, Beacon converts to the currency of your region. Exchange rates come from the free [currency-api](https://github.com/fawazahmed0/exchange-api) feed, and the last downloaded rates keep working offline.

## Clipboard history

Beacon remembers the last 100 texts you copy. Search for **Clipboard History** and press `Return` to open it, type to filter the items, and press `Return` to copy the selected one back to the clipboard. Press `⌘⌫` to delete the selected item, and `Esc` to go back. Add **Clipboard History** to your favorites with `⌘K` to open it with a single `Return`.

Beacon skips passwords and other items that apps such as password managers mark as private, and does not record copied files. The history stays on your Mac. Turn it off, or clear it, under **Clipboard** in Beacon Settings; turning it off deletes the saved history.

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
├── Calculator.swift                # Arithmetic for the calculator result
├── ClipboardHistory.swift          # Clipboard history recording and storage
├── ContentView.swift               # Launcher interface
├── CurrencyConversion.swift        # Currency conversion queries and currency names
├── ExchangeRates.swift             # Exchange rate downloads and cache
├── Extension.swift                 # Extension manifest, catalog, and item models
├── ExtensionManager.swift          # Extension installation and updates
├── ExtensionRuntime.swift          # JavaScriptCore runtime for extension commands
├── KeyboardShortcut.swift          # Shortcut representation and registration
├── LauncherModel.swift             # Indexing, matching, and launch behavior
├── LauncherPanelController.swift   # Floating launcher panel
├── SettingsView.swift              # Shortcut and indexing settings
└── Updater.swift                   # Update checks, installation, and relaunching
```

Beacon indexes application metadata and keeps clipboard history locally. A web-search result opens Google in your default browser only when you choose it. Beacon contacts GitHub only to check for and download Beacon updates and to show and install extensions on the Extensions page, and downloads exchange rates only when you type a currency conversion and the saved rates are over six hours old.
