import Foundation
import Observation

/// Installs extensions from the Beacon extension repository and keeps track of the installed ones.
///
/// The repository contains a `catalog.json` file and an `extensions` folder with one folder per extension,
/// named after the extension identifier, that holds its `manifest.json` and script.
@MainActor
@Observable
final class ExtensionManager {
    enum CatalogState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    nonisolated static let repositoryName = "beacon-macos/extensions"
    nonisolated static let repositoryURL = URL(string: "https://raw.githubusercontent.com/\(repositoryName)/main/")!

    nonisolated static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Beacon/Extensions", directoryHint: .isDirectory)
    }

    private(set) var installed: [InstalledExtension] = []
    private(set) var catalog: [ExtensionCatalog.Entry] = []
    private(set) var catalogState = CatalogState.idle
    private(set) var busyExtensionIDs: Set<String> = []
    private(set) var errorMessage: String?

    var onInstalledExtensionsChanged: (() -> Void)?

    let directory: URL
    private let repositoryURL: URL
    private let session: URLSession

    init(
        directory: URL = ExtensionManager.defaultDirectory,
        repositoryURL: URL = ExtensionManager.repositoryURL,
        session: URLSession = .shared
    ) {
        self.directory = directory
        self.repositoryURL = repositoryURL
        self.session = session
    }

    func installedExtension(withID id: String) -> InstalledExtension? {
        installed.first { $0.id == id }
    }

    func isUpdateAvailable(for id: String) -> Bool {
        guard let installedVersion = installedExtension(withID: id)?.manifest.version,
              let catalogVersion = catalog.first(where: { $0.id == id })?.version else { return false }
        return catalogVersion.isNewerVersion(than: installedVersion)
    }

    func loadInstalledExtensions() {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        installed = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
                  let manifest = try? JSONDecoder().decode(ExtensionManifest.self, from: data),
                  (try? manifest.validate()) != nil,
                  manifest.id == folder.lastPathComponent else { return nil }
            return InstalledExtension(manifest: manifest, directory: folder)
        }
        .sorted { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
        onInstalledExtensionsChanged?()
    }

    func refreshCatalog() async {
        guard catalogState != .loading else { return }
        catalogState = .loading
        do {
            let data = try await download(repositoryURL.appending(path: "catalog.json"))
            catalog = try JSONDecoder().decode(ExtensionCatalog.self, from: data).extensions
                .filter { ExtensionManifest.isValidIdentifier($0.id) }
            catalogState = .loaded
        } catch {
            catalogState = .failed(error.localizedDescription)
        }
    }

    func install(_ id: String) async {
        guard ExtensionManifest.isValidIdentifier(id), !busyExtensionIDs.contains(id) else { return }
        busyExtensionIDs.insert(id)
        errorMessage = nil
        defer { busyExtensionIDs.remove(id) }

        do {
            let folderURL = repositoryURL.appending(path: "extensions/\(id)", directoryHint: .isDirectory)
            let manifestData = try await download(folderURL.appending(path: "manifest.json"))
            let manifest: ExtensionManifest
            do {
                manifest = try JSONDecoder().decode(ExtensionManifest.self, from: manifestData)
            } catch {
                throw ExtensionError.invalidManifest("manifest.json could not be read.")
            }
            try manifest.validate()
            guard manifest.id == id else {
                throw ExtensionError.invalidManifest("The manifest identifier “\(manifest.id)” does not match “\(id)”.")
            }
            let script = try await download(folderURL.appending(path: manifest.main))
            try store(manifestData: manifestData, script: script, for: manifest)
            loadInstalledExtensions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func uninstall(_ id: String) {
        guard let installedExtension = installedExtension(withID: id) else { return }
        errorMessage = nil
        do {
            try FileManager.default.removeItem(at: installedExtension.directory)
        } catch {
            errorMessage = error.localizedDescription
        }
        loadInstalledExtensions()
    }

    private func store(manifestData: Data, script: Data, for manifest: ExtensionManifest) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let stagingURL = directory.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        do {
            try manifestData.write(to: stagingURL.appending(path: "manifest.json"))
            try script.write(to: stagingURL.appending(path: manifest.main))

            let destinationURL = directory.appending(path: manifest.id, directoryHint: .isDirectory)
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
            } else {
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    private func download(_ url: URL) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ExtensionError.download(error.localizedDescription)
        }
        if let response = response as? HTTPURLResponse, response.statusCode != 200 {
            throw ExtensionError.download("\(url.lastPathComponent) returned HTTP \(response.statusCode).")
        }
        return data
    }
}
