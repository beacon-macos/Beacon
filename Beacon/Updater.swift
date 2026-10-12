import AppKit
import CryptoKit
import Foundation
import Observation
import Security

/// Checks GitHub for a newer Beacon release and installs it in place of the running application.
@MainActor
@Observable
final class Updater {
    nonisolated struct Release: Equatable, Sendable {
        struct Archive: Equatable, Sendable {
            let url: URL
            let sha256: String
            let signatureURL: URL
        }

        let version: String
        let pageURL: URL
        /// The `Beacon-vX.Y.Z.zip` asset, or `nil` when it has not been uploaded yet or has no digest or signature.
        let archive: Archive?
    }

    enum Phase: Equatable {
        case idle
        case downloading
        case ready
        case installed
        case failed(String)
    }

    nonisolated static let repositoryName = "beacon-macos/Beacon"
    nonisolated static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repositoryName)/releases/latest")!
    /// The Ed25519 key that verifies update archives. The release workflow signs each one with the matching private key.
    nonisolated static let signingPublicKey = Data(base64Encoded: "BHeWSrn9TMPFv0mFDulL4HYu+hxmWhefW325sEPZ8bo=")!
    /// Tells the relaunched application to start without showing the launcher.
    nonisolated static let backgroundRelaunchArgument = "--updated-in-background"

    /// The newest release when it is newer than the running version.
    private(set) var release: Release?
    private(set) var phase = Phase.idle
    private(set) var isChecking = false
    private(set) var checkErrorMessage: String?
    private(set) var lastCheckDate: Date?

    var automaticallyInstallsUpdates: Bool {
        didSet {
            defaults.set(automaticallyInstallsUpdates, forKey: Keys.automaticallyInstallsUpdates)
            if automaticallyInstallsUpdates, canInstallUpdate {
                Task { await prepareUpdate() }
            }
        }
    }

    var onChange: (() -> Void)?
    var onUpdatePrepared: (() -> Void)?

    let currentVersion: String
    private let applicationURL: URL
    private let bundleIdentifier: String?
    private let latestReleaseURL: URL
    private let signingPublicKey: Data
    private let session: URLSession
    private let defaults: UserDefaults
    private var preparation: Task<Void, Never>?
    private var preparedApplicationURL: URL?

    init(
        defaults: UserDefaults = .standard,
        currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        applicationURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        latestReleaseURL: URL = Updater.latestReleaseURL,
        signingPublicKey: Data = Updater.signingPublicKey,
        session: URLSession = .shared
    ) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.applicationURL = applicationURL
        self.bundleIdentifier = bundleIdentifier
        self.latestReleaseURL = latestReleaseURL
        self.signingPublicKey = signingPublicKey
        self.session = session
        automaticallyInstallsUpdates = defaults.bool(forKey: Keys.automaticallyInstallsUpdates)
        lastCheckDate = defaults.object(forKey: Keys.lastCheckDate) as? Date
    }

    /// A read-only disk image, a translocated copy, or an installation owned by another user falls back to the release page.
    var canInstallUpdate: Bool {
        guard release?.archive != nil else { return false }
        if case .failed = phase { return false }
        let fileManager = FileManager.default
        return fileManager.isWritableFile(atPath: applicationURL.path)
            && fileManager.isWritableFile(atPath: applicationURL.deletingLastPathComponent().path)
    }

    func checkForUpdates() async {
        switch phase {
        case .downloading, .ready, .installed: return
        case .idle, .failed: break
        }
        guard !isChecking else { return }
        isChecking = true
        checkErrorMessage = nil
        onChange?()

        do {
            let latestRelease = try Self.release(from: try await download(latestReleaseURL))
            release = latestRelease.version.isNewerVersion(than: currentVersion) ? latestRelease : nil
            phase = .idle
            lastCheckDate = .now
            defaults.set(lastCheckDate, forKey: Keys.lastCheckDate)
        } catch {
            checkErrorMessage = error.localizedDescription
        }
        isChecking = false
        onChange?()

        if automaticallyInstallsUpdates, canInstallUpdate {
            await prepareUpdate()
        }
    }

    /// Downloads and verifies the update without replacing the running application.
    func prepareUpdate() async {
        if let preparation {
            await preparation.value
            return
        }
        guard phase == .idle, canInstallUpdate, let release, let archive = release.archive else { return }

        let task = Task {
            phase = .downloading
            onChange?()
            do {
                let data = try await download(archive.url)
                let signature = try await download(archive.signatureURL)
                let applicationURL = applicationURL
                let bundleIdentifier = bundleIdentifier
                let signingPublicKey = signingPublicKey
                preparedApplicationURL = try await Task.detached(priority: .utility) {
                    try Self.unpack(
                        data,
                        archive: archive,
                        signature: signature,
                        signingPublicKey: signingPublicKey,
                        version: release.version,
                        bundleIdentifier: bundleIdentifier,
                        replacing: applicationURL
                    )
                }.value
                phase = .ready
            } catch {
                phase = .failed(error.localizedDescription)
            }
            onChange?()
            if phase == .ready {
                onUpdatePrepared?()
            }
        }
        preparation = task
        await task.value
        preparation = nil
    }

    func installUpdate() async {
        await prepareUpdate()
        installAndRelaunch(inBackground: false)
    }

    func installAndRelaunch(inBackground: Bool) {
        guard phase == .ready else { return }
        do {
            try installPreparedUpdate()
            try relaunch(inBackground: inBackground)
        } catch {
            phase = .failed(error.localizedDescription)
            onChange?()
        }
    }

    /// The running process keeps its code mapped, so it can be replaced right before relaunching.
    func installPreparedUpdate() throws {
        guard phase == .ready, let preparedApplicationURL else { return }
        _ = try FileManager.default.replaceItemAt(applicationURL, withItemAt: preparedApplicationURL)
        try? FileManager.default.removeItem(at: preparedApplicationURL.deletingLastPathComponent())
        self.preparedApplicationURL = nil
        phase = .installed
        onChange?()
    }

    /// Quits Beacon and opens it again once this process has exited, because a second instance quits immediately.
    private func relaunch(inBackground: Bool) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        // In the background, `open -g` keeps the app the person is typing in active.
        let openArguments = inBackground
            ? ["-g", applicationURL.path, "--args", Self.backgroundRelaunchArgument]
            : [applicationURL.path]
        process.arguments = [
            "-c",
            #"while /bin/kill -0 "$0" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open "$@""#,
            String(ProcessInfo.processInfo.processIdentifier)
        ] + openArguments
        try process.run()
        NSApp.terminate(nil)
    }

    private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateError.download(error.localizedDescription)
        }
        if let response = response as? HTTPURLResponse, response.statusCode != 200 {
            throw UpdateError.download("GitHub returned HTTP \(response.statusCode).")
        }
        return data
    }

    nonisolated static func release(from data: Data) throws -> Release {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let feed = try decoder.decode(Feed.self, from: data)
        let version = feed.tagName.hasPrefix("v") ? String(feed.tagName.dropFirst()) : feed.tagName
        let archiveName = "Beacon-\(feed.tagName).zip"
        let signatureAsset = feed.assets.first { $0.name == archiveName + ".sig" }
        let archive = feed.assets.first { $0.name == archiveName }.flatMap { asset -> Release.Archive? in
            guard let digest = asset.digest, digest.hasPrefix("sha256:"), let signatureAsset else { return nil }
            return Release.Archive(
                url: asset.browserDownloadUrl,
                sha256: String(digest.dropFirst(7)).lowercased(),
                signatureURL: signatureAsset.browserDownloadUrl
            )
        }
        return Release(version: version, pageURL: feed.htmlUrl, archive: archive)
    }

    /// Extracts into a temporary folder on the application's volume so the result can be swapped into place.
    nonisolated static func unpack(
        _ data: Data,
        archive: Release.Archive,
        signature: Data,
        signingPublicKey: Data,
        version: String,
        bundleIdentifier: String?,
        replacing applicationURL: URL
    ) throws -> URL {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == archive.sha256 else { throw UpdateError.damagedArchive }
        // The digest comes from the same GitHub release as the archive, so only the signature shows who built it.
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey),
              publicKey.isValidSignature(signature, for: data) else { throw UpdateError.untrustedArchive }

        let fileManager = FileManager.default
        let directory = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: applicationURL,
            create: true
        )
        do {
            let archiveURL = directory.appending(path: "Update.zip")
            try data.write(to: archiveURL)

            let ditto = Process()
            ditto.executableURL = URL(filePath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", archiveURL.path, directory.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { throw UpdateError.damagedArchive }
            try fileManager.removeItem(at: archiveURL)

            let applications = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "app" }
            guard applications.count == 1, let newApplicationURL = applications.first,
                  let bundle = Bundle(url: newApplicationURL) else { throw UpdateError.missingApplication }
            guard bundle.bundleIdentifier == bundleIdentifier,
                  bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else {
                throw UpdateError.unexpectedApplication
            }

            var staticCode: SecStaticCode?
            let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
            guard SecStaticCodeCreateWithPath(newApplicationURL as CFURL, [], &staticCode) == errSecSuccess,
                  let staticCode,
                  SecStaticCodeCheckValidity(staticCode, flags, nil) == errSecSuccess else {
                throw UpdateError.invalidSignature
            }
            return newApplicationURL
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    private nonisolated struct Feed: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
            let digest: String?
        }

        let tagName: String
        let htmlUrl: URL
        let assets: [Asset]
    }

    private enum Keys {
        static let automaticallyInstallsUpdates = "automaticallyInstallsUpdates"
        static let lastCheckDate = "lastUpdateCheckDate"
    }
}

nonisolated enum UpdateError: LocalizedError, Equatable {
    case download(String)
    case damagedArchive
    case untrustedArchive
    case missingApplication
    case unexpectedApplication
    case invalidSignature

    var errorDescription: String? {
        switch self {
        case .download(let message):
            return "Download failed: \(message)"
        case .damagedArchive:
            return "The downloaded update is damaged."
        case .untrustedArchive:
            return "The downloaded update is not signed by Beacon's release key."
        case .missingApplication:
            return "The downloaded update does not contain Beacon."
        case .unexpectedApplication:
            return "The downloaded update contains a different application or version."
        case .invalidSignature:
            return "The downloaded update has an invalid code signature."
        }
    }
}
