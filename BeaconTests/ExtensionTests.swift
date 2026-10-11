import Foundation
import Observation
import SQLite3
import Testing
@testable import Beacon

struct ExtensionTests {

    private static let script = """
        beacon.registerCommand("open-recent", () => [
          { title: "Alpha", subtitle: "~/alpha", action: { type: "open", target: "~/alpha", application: "com.example.editor" } },
          { title: "Beta", action: { type: "open", target: "https://example.com/beta" } },
        ]);
        """

    @Test func manifestValidationRejectsUnsafeIdentifiersAndScriptNames() throws {
        try manifest().validate()

        for invalidManifest in [
            manifest(id: "../escape"),
            manifest(id: "Upper"),
            manifest(id: "-leading"),
            manifest(main: "../main.js"),
            manifest(main: "folder/main.js"),
            manifest(main: ".hidden.js"),
            manifest(main: "main.sh"),
            manifest(commandIDs: []),
            manifest(commandIDs: ["has space"])
        ] {
            #expect(throws: ExtensionError.self) { try invalidManifest.validate() }
        }
    }

    @Test func versionsCompareNumerically() {
        #expect("1.10.0".isNewerVersion(than: "1.9.0"))
        #expect("2.0".isNewerVersion(than: "1.9.9"))
        #expect(!"1.0.0".isNewerVersion(than: "1.0.0"))
        #expect(!"1.2.0".isNewerVersion(than: "1.10.0"))
    }

    @Test func actionTargetsResolveToPathsAndURLs() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        #expect(ExtensionAction.url(forTarget: "/tmp/project") == URL(filePath: "/tmp/project"))
        #expect(ExtensionAction.url(forTarget: "~/project")?.path == home + "/project")
        #expect(ExtensionAction.url(forTarget: "vscode://file/tmp/project")?.scheme == "vscode")
        #expect(ExtensionAction.url(forTarget: "relative/project") == nil)
    }

    @Test func runtimeReturnsItemsFromTheRegisteredCommand() throws {
        let items = try ExtensionRuntime.runCommand("open-recent", source: Self.script)

        #expect(items.map(\.title) == ["Alpha", "Beta"])
        #expect(items[0].subtitle == "~/alpha")
        #expect(items[0].action == .open(target: "~/alpha", application: "com.example.editor"))
        #expect(items[1].action == .open(target: "https://example.com/beta", application: nil))
    }

    @Test func runtimeReportsScriptErrorsAndMissingCommands() {
        #expect(throws: ExtensionError.commandNotFound("missing")) {
            try ExtensionRuntime.runCommand("missing", source: Self.script)
        }
        #expect(throws: ExtensionError.self) {
            try ExtensionRuntime.runCommand("broken", source: """
                beacon.registerCommand("broken", () => { throw new Error("boom"); });
                """)
        }
        #expect(throws: ExtensionError.self) {
            try ExtensionRuntime.runCommand("unsupported", source: """
                beacon.registerCommand("unsupported", () => [{ title: "Run", action: { type: "shell" } }]);
                """)
        }
        #expect((try? ExtensionRuntime.runCommand("empty", source: """
            beacon.registerCommand("empty", () => undefined);
            """)) == [])
    }

    @Test func runtimeReadsFilesAndSQLiteDatabases() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let textURL = directory.appending(path: "notes.txt")
        try "Gamma".write(to: textURL, atomically: true, encoding: .utf8)
        let databaseURL = directory.appending(path: "state.db")
        try createDatabase(at: databaseURL, statements: [
            "CREATE TABLE items (name TEXT, position INTEGER)",
            "INSERT INTO items VALUES ('Delta', 2), ('Epsilon', 1)"
        ])

        let items = try ExtensionRuntime.runCommand("read", source: """
            beacon.registerCommand("read", () => {
              const rows = beacon.querySQLite("\(databaseURL.path)", "SELECT name FROM items ORDER BY position");
              const names = [beacon.readFile("\(textURL.path)"), ...rows.map((row) => row.name)];
              if (beacon.readFile("\(directory.path)/missing.txt") !== null) names.push("unexpected");
              if (!beacon.fileExists("\(textURL.path)")) names.push("unexpected");
              return names.map((name) => ({ title: name, action: { type: "open", target: "/" } }));
            });
            """)

        #expect(items.map(\.title) == ["Gamma", "Epsilon", "Delta"])
    }

    @Test func sqliteErrorsCanBeCaughtByTheScript() throws {
        let items = try ExtensionRuntime.runCommand("query", source: """
            beacon.registerCommand("query", () => {
              try {
                beacon.querySQLite("/nonexistent/state.db", "SELECT 1");
                return [];
              } catch (error) {
                return [{ title: "caught", action: { type: "open", target: "/" } }];
              }
            });
            """)

        #expect(items.map(\.title) == ["caught"])
    }

    @Test @MainActor func managerInstallsUpdatesAndUninstallsExtensions() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appending(path: "repository", directoryHint: .isDirectory)
        try publish(manifest(), script: Self.script, version: "1.0.0", to: repository)

        let manager = ExtensionManager(directory: root.appending(path: "installed"), repositoryURL: repository)
        var changeCount = 0
        manager.onInstalledExtensionsChanged = { changeCount += 1 }

        await manager.refreshCatalog()
        #expect(manager.catalogState == .loaded)
        #expect(manager.catalog.map(\.id) == ["test"])

        await manager.install("test")
        #expect(manager.errorMessage == nil)
        #expect(manager.installed.map(\.id) == ["test"])
        #expect(changeCount == 1)
        #expect(!manager.isUpdateAvailable(for: "test"))

        try publish(manifest(version: "1.1.0"), script: Self.script, version: "1.1.0", to: repository)
        await manager.refreshCatalog()
        #expect(manager.isUpdateAvailable(for: "test"))
        await manager.install("test")
        #expect(manager.installedExtension(withID: "test")?.manifest.version == "1.1.0")
        #expect(!manager.isUpdateAvailable(for: "test"))

        let restoredManager = ExtensionManager(directory: manager.directory, repositoryURL: repository)
        restoredManager.loadInstalledExtensions()
        #expect(restoredManager.installed.map(\.manifest.version) == ["1.1.0"])

        manager.uninstall("test")
        #expect(manager.installed.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: manager.directory.path).isEmpty)
    }

    @Test @MainActor func managerRejectsAManifestThatDoesNotMatchTheCatalog() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appending(path: "repository", directoryHint: .isDirectory)
        try publish(manifest(id: "other"), script: Self.script, version: "1.0.0", to: repository, folder: "test")

        let manager = ExtensionManager(directory: root.appending(path: "installed"), repositoryURL: repository)
        await manager.install("test")
        await manager.install("../outside")

        #expect(manager.installed.isEmpty)
        #expect(manager.errorMessage != nil)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "outside").path))
    }

    @Test @MainActor func managerReportsAMissingCatalog() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = ExtensionManager(directory: root.appending(path: "installed"), repositoryURL: root)
        await manager.refreshCatalog()

        guard case .failed = manager.catalogState else {
            Issue.record("Expected the catalog to fail, got \(manager.catalogState)")
            return
        }
    }

    @Test @MainActor func listingsShowCatalogEntriesThenExtensionsMissingFromTheCatalog() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appending(path: "repository", directoryHint: .isDirectory)
        try publish(manifest(version: "1.1.0"), script: Self.script, version: "1.1.0", to: repository)
        let directory = root.appending(path: "installed", directoryHint: .isDirectory)
        try write(manifest(), script: Self.script, to: directory.appending(path: "test", directoryHint: .isDirectory))
        try write(manifest(id: "other"), script: Self.script, to: directory.appending(path: "other", directoryHint: .isDirectory))

        let manager = ExtensionManager(directory: directory, repositoryURL: repository)
        manager.loadInstalledExtensions()
        await manager.refreshCatalog()

        #expect(manager.listings.map(\.id) == ["test", "other"])
        #expect(manager.listings.map(\.version) == ["1.0.0", "1.0.0"])
        #expect(manager.listings.map(\.isInstalled) == [true, true])
        #expect(manager.isUpdateAvailable(for: "test"))
    }

    @Test @MainActor func extensionsPageInstallsUpdatesAndUninstallsTheSelectedExtension() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appending(path: "repository", directoryHint: .isDirectory)
        try publish(manifest(), script: Self.script, version: "1.0.0", to: repository)
        let manager = ExtensionManager(directory: root.appending(path: "installed"), repositoryURL: repository)
        let model = LauncherModel(defaults: isolatedDefaults(named: #function), extensions: manager)
        var dismissalCount = 0
        model.onDismiss = { dismissalCount += 1 }

        model.query = "manage extensions"
        try #require(model.results.first?.id == LauncherModel.extensionsResultID)
        model.runSelected()
        #expect(model.isShowingExtensions)
        #expect(model.query.isEmpty)
        try await waitUntil { !model.results.isEmpty }

        #expect(model.results.map(\.title) == ["Test Extension"])
        #expect(model.selectedExtensionListing?.isInstalled == false)
        #expect(!model.toggleFavoriteForSelection())
        #expect(!model.canReorderFavoriteForSelection)
        #expect(!model.uninstallSelectedExtension())

        var resultsChange = observeChange(of: model)
        model.runSelected()
        try await waitUntil { model.selectedExtensionListing?.isInstalled == true }
        #expect(manager.installed.map(\.id) == ["test"])
        #expect(resultsChange.didChange)

        try publish(manifest(version: "1.1.0"), script: Self.script, version: "1.1.0", to: repository)
        model.refreshExtensionCatalog()
        try await waitUntil { manager.isUpdateAvailable(for: "test") }
        resultsChange = observeChange(of: model)
        model.runSelected()
        try await waitUntil { model.selectedExtensionListing?.version == "1.1.0" }
        #expect(!manager.isUpdateAvailable(for: "test"))
        #expect(resultsChange.didChange)

        #expect(model.uninstallSelectedExtension())
        #expect(manager.installed.isEmpty)
        #expect(model.selectedExtensionListing?.isInstalled == false)

        model.goBack()
        #expect(!model.isShowingExtensions)
        #expect(dismissalCount == 0)
        #expect(model.results.first?.id == LauncherModel.settingsResultID)

        model.goBack()
        #expect(dismissalCount == 1)
    }

    @Test @MainActor func presentingTheLauncherClosesTheExtensionsPage() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try installedManager(in: root)
        let model = LauncherModel(defaults: isolatedDefaults(named: #function), extensions: manager)
        var presentationCount = 0
        model.onPresent = {
            presentationCount += 1
            model.prepareForPresentation()
        }

        model.presentExtensions()
        #expect(presentationCount == 1)
        #expect(model.isShowingExtensions)
        #expect(model.results.map(\.title) == ["Test Extension"])

        model.prepareForPresentation()
        #expect(!model.isShowingExtensions)
    }

    @Test @MainActor func extensionCommandShowsSearchableItemsAndReturnsToResults() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try installedManager(in: root)
        let model = LauncherModel(defaults: isolatedDefaults(named: #function), extensions: manager)
        var dismissalCount = 0
        model.onDismiss = { dismissalCount += 1 }

        model.query = "open recent"
        // Running anything other than the extension command would open the web search in a browser.
        try #require(model.results.first?.id == "extension:test:open-recent")
        #expect(model.results.first?.subtitle == "Test Extension")
        #expect(model.results.first?.isExtensionCommand == true)

        model.runSelected()
        #expect(model.commandSession?.title == "Open Recent")
        #expect(model.commandSession?.placeholder == "Search recent items")
        #expect(model.query.isEmpty)
        try await waitUntilLoaded(model)

        #expect(model.results.map(\.title) == ["Alpha", "Beta"])
        #expect(!model.results.contains { $0.isExtensionCommand })
        #expect(!model.toggleFavoriteForSelection())
        #expect(!model.canReorderFavoriteForSelection)

        model.query = "beta"
        #expect(model.results.map(\.title) == ["Beta"])

        model.goBack()
        #expect(model.commandSession == nil)
        #expect(model.query.isEmpty)
        #expect(dismissalCount == 0)

        model.goBack()
        #expect(dismissalCount == 1)
    }

    @Test @MainActor func failingExtensionCommandShowsItsError() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try installedManager(in: root, script: """
            beacon.registerCommand("open-recent", () => { throw new Error("no recent items"); });
            """)
        let model = LauncherModel(defaults: isolatedDefaults(named: #function), extensions: manager)

        model.runExtensionCommand(extensionID: "test", commandID: "open-recent")
        try await waitUntilLoaded(model)

        #expect(model.results.isEmpty)
        #expect(model.commandSession?.errorMessage?.contains("no recent items") == true)

        model.prepareForPresentation()
        #expect(model.commandSession == nil)
    }

    @Test @MainActor func uninstallingAnExtensionRemovesItsCommands() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try installedManager(in: root)
        let model = LauncherModel(defaults: isolatedDefaults(named: #function), extensions: manager)

        model.query = "open recent"
        #expect(model.results.contains { $0.id == "extension:test:open-recent" })

        manager.uninstall("test")
        #expect(!model.results.contains { $0.id == "extension:test:open-recent" })
    }

    // MARK: - Helpers

    private func manifest(
        id: String = "test",
        version: String = "1.0.0",
        main: String = "main.js",
        commandIDs: [String] = ["open-recent"]
    ) -> ExtensionManifest {
        ExtensionManifest(
            id: id,
            name: "Test Extension",
            description: "An extension used by the tests.",
            version: version,
            main: main,
            commands: commandIDs.map {
                ExtensionManifest.Command(id: $0, title: "Open Recent", placeholder: "Search recent items")
            }
        )
    }

    private func publish(
        _ manifest: ExtensionManifest,
        script: String,
        version: String,
        to repository: URL,
        folder: String? = nil
    ) throws {
        let folderURL = repository.appending(path: "extensions/\(folder ?? manifest.id)", directoryHint: .isDirectory)
        try write(manifest, script: script, to: folderURL)
        let catalog = """
            { "extensions": [
              { "id": "\(folder ?? manifest.id)", "name": "\(manifest.name)", "description": "", "version": "\(version)" }
            ] }
            """
        try catalog.write(to: repository.appending(path: "catalog.json"), atomically: true, encoding: .utf8)
    }

    private func write(_ manifest: ExtensionManifest, script: String, to folderURL: URL) throws {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: folderURL.appending(path: "manifest.json"))
        try script.write(to: folderURL.appending(path: manifest.main), atomically: true, encoding: .utf8)
    }

    @MainActor
    private func installedManager(in root: URL, script: String = Self.script) throws -> ExtensionManager {
        let directory = root.appending(path: "installed", directoryHint: .isDirectory)
        try write(manifest(), script: script, to: directory.appending(path: "test", directoryHint: .isDirectory))
        let manager = ExtensionManager(directory: directory, repositoryURL: root)
        manager.loadInstalledExtensions()
        return manager
    }

    @MainActor
    private func waitUntilLoaded(_ model: LauncherModel) async throws {
        try await waitUntil { model.commandSession?.isLoading == false }
    }

    @MainActor
    private func observeChange(of model: LauncherModel) -> ChangeFlag {
        let flag = ChangeFlag()
        withObservationTracking {
            _ = model.results
        } onChange: {
            MainActor.assumeIsolated { flag.didChange = true }
        }
        return flag
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BeaconExtensionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func createDatabase(at url: URL, statements: [String]) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        for statement in statements {
            guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    @MainActor
    private func isolatedDefaults(named name: String) -> UserDefaults {
        let suiteName = "ExtensionTests.\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class ChangeFlag {
    var didChange = false
}
