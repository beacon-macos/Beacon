//
//  BeaconApp.swift
//  Beacon
//
//  Created by Denys Yazan on 22.08.2026.
//

import AppKit
import SwiftUI

@main
struct BeaconApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Beacon", systemImage: "sparkle.magnifyingglass") {
            Button("Open Beacon") {
                appDelegate.showLauncher()
            }
            .keyboardShortcut(" ", modifiers: [.command])
            Divider()
            SettingsLink {
                Text("Settings…")
            }
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }

        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: LauncherModel

    private static let applicationIndexCheckInterval: TimeInterval = 24 * 60 * 60

    private var panelController: LauncherPanelController?
    private var applicationIndexTimer: Timer?
    private let hotKeyManager = GlobalHotKeyManager()
    private var isDuplicateInstance = false

    override init() {
        model = Self.makeModel()
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningUnitTests else { return }
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        isDuplicateInstance = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { $0.processIdentifier != currentProcessIdentifier }
        if isDuplicateInstance { NSApp.terminate(nil) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isDuplicateInstance else { return }
        NSApp.setActivationPolicy(.accessory)
        NSWindow.allowsAutomaticWindowTabbing = false

        panelController = LauncherPanelController(model: model)
        model.onDismiss = { [weak self] in
            self?.panelController?.hide()
        }
        hotKeyManager.onPressed = { [weak self] in
            self?.showLauncher()
        }
        applyShortcut(model.shortcut)
        model.onShortcutChanged = { [weak self] shortcut in
            self?.applyShortcut(shortcut)
        }

        model.loadApplications()
        model.extensions.loadInstalledExtensions()
        applicationIndexTimer = Timer.scheduledTimer(
            withTimeInterval: Self.applicationIndexCheckInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.model.checkForNewApplications()
            }
        }
        showLauncher()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard model.shortcut.doubleTapModifier != nil,
              model.shortcutRegistrationError != nil else { return }
        applyShortcut(model.shortcut)
    }

    func showLauncher() {
        panelController?.toggle()
    }

    private func applyShortcut(_ shortcut: KeyboardShortcut) {
        model.shortcutRegistrationError = hotKeyManager.register(shortcut: shortcut)
    }

    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static func makeModel() -> LauncherModel {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["BEACON_UI_TESTING"] == "1" {
            let suiteName = "BeaconUITests"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)

            if let favoriteIDs = environment["BEACON_UI_TEST_FAVORITE_IDS"] {
                defaults.set(
                    favoriteIDs.split(separator: "\n").map(String.init),
                    forKey: "launcherFavoriteIDs"
                )
            }
            let extensionsDirectory = environment["BEACON_UI_TEST_EXTENSIONS_DIRECTORY"]
                .map { URL(filePath: $0, directoryHint: .isDirectory) }
                ?? FileManager.default.temporaryDirectory.appending(path: "BeaconUITests-\(UUID().uuidString)")
            return LauncherModel(defaults: defaults, extensions: ExtensionManager(directory: extensionsDirectory))
        }
#endif
        return LauncherModel()
    }
}
