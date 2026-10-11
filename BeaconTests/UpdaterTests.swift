import Foundation
import Testing
@testable import Beacon

struct UpdaterTests {

    private static let bundleIdentifier = "com.dhkey.Beacon"

    private enum Signature {
        case valid
        case missing
        case broken
    }

    @Test func releaseUsesTheTaggedArchiveAndItsDigest() throws {
        let release = try Updater.release(from: feed(tag: "v1.5.0", assets: [
            ("Beacon-v1.5.0.dmg", "https://example.com/Beacon-v1.5.0.dmg", "sha256:00"),
            ("Beacon-v1.5.0.zip", "https://example.com/Beacon-v1.5.0.zip", "sha256:ABC123")
        ]))
        #expect(release.version == "1.5.0")
        #expect(release.pageURL == URL(string: "https://github.com/beacon-macos/Beacon/releases/tag/v1.5.0"))
        #expect(release.archive == Updater.Release.Archive(
            url: URL(string: "https://example.com/Beacon-v1.5.0.zip")!,
            sha256: "abc123"
        ))

        let withoutDigest = try Updater.release(from: feed(tag: "v1.5.0", assets: [
            ("Beacon-v1.5.0.zip", "https://example.com/Beacon-v1.5.0.zip", nil)
        ]))
        #expect(withoutDigest.archive == nil)
        #expect(try Updater.release(from: feed(tag: "v1.5.0", assets: [])).archive == nil)
    }

    @Test @MainActor func checkOffersOnlyNewerReleases() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedURL = directory.appending(path: "latest.json")
        try feed(tag: "v1.5.0", assets: [
            ("Beacon-v1.5.0.zip", "https://example.com/Beacon-v1.5.0.zip", "sha256:00")
        ]).write(to: feedURL)

        let updater = updater(currentVersion: "1.4.0", feedURL: feedURL, in: directory, named: #function)
        await updater.checkForUpdates()
        #expect(updater.release?.version == "1.5.0")
        #expect(updater.phase == .idle)
        #expect(updater.lastCheckDate != nil)
        #expect(updater.checkErrorMessage == nil)

        let current = self.updater(currentVersion: "1.5.0", feedURL: feedURL, in: directory, named: #function + ".current")
        await current.checkForUpdates()
        #expect(current.release == nil)

        let offline = self.updater(
            currentVersion: "1.4.0",
            feedURL: directory.appending(path: "missing.json"),
            in: directory,
            named: #function + ".offline"
        )
        await offline.checkForUpdates()
        #expect(offline.release == nil)
        #expect(offline.checkErrorMessage != nil)
    }

    @Test @MainActor func launcherShowsTheUpdateAfterTheFavorites() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedURL = directory.appending(path: "latest.json")
        try feed(tag: "v1.5.0", assets: [
            ("Beacon-v1.5.0.zip", "https://example.com/Beacon-v1.5.0.zip", "sha256:00")
        ]).write(to: feedURL)
        let defaults = isolatedDefaults(named: #function)
        defaults.set([LauncherModel.settingsResultID, "command:applications"], forKey: "launcherFavoriteIDs")
        let updater = updater(currentVersion: "1.4.0", feedURL: feedURL, in: directory, named: #function + ".updater")
        let model = LauncherModel(defaults: defaults, updater: updater)

        #expect(model.results.map(\.id) == [LauncherModel.settingsResultID, "command:applications"])

        model.query = "check for updates"
        #expect(model.results.first?.id == LauncherModel.updateResultID)
        #expect(model.results.first?.target == .checkForUpdates)
        #expect(!model.toggleFavoriteForSelection())

        model.runSelected()
        try await waitUntil { updater.release != nil }

        model.query = ""
        #expect(model.results.map(\.id) == [
            LauncherModel.settingsResultID,
            "command:applications",
            LauncherModel.updateResultID
        ])
        #expect(model.results.last?.title == "Beacon 1.5.0 is available")
        #expect(model.results.last?.subtitle == "Press Return to update and relaunch Beacon")
        #expect(model.results.last?.target == .update)
        model.selectResult(at: 2)
        #expect(!model.toggleFavoriteForSelection())
    }

    @Test @MainActor func automaticUpdateIsPreparedAndReplacesTheApplication() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let applicationURL = try makeApplication(version: "1.4.0", in: directory.appending(path: "Installed"))
        let feedURL = try publish(version: "1.5.0", in: directory)
        let updater = Updater(
            defaults: isolatedDefaults(named: #function),
            currentVersion: "1.4.0",
            applicationURL: applicationURL,
            bundleIdentifier: Self.bundleIdentifier,
            latestReleaseURL: feedURL
        )
        var preparedCount = 0
        updater.onUpdatePrepared = { preparedCount += 1 }
        updater.automaticallyInstallsUpdates = true

        await updater.checkForUpdates()
        #expect(updater.phase == .ready)
        #expect(preparedCount == 1)
        #expect(try version(of: applicationURL) == "1.4.0")

        try updater.installPreparedUpdate()
        #expect(updater.phase == .installed)
        #expect(try version(of: applicationURL) == "1.5.0")
    }

    @Test @MainActor func updatesThatDoNotMatchTheReleaseAreRejected() async throws {
        let cases: [(String, applicationVersion: String, bundleIdentifier: String, signature: Signature, digest: String?, UpdateError)] = [
            ("digest", "1.5.0", Self.bundleIdentifier, .valid, "sha256:00", .damagedArchive),
            ("version", "1.6.0", Self.bundleIdentifier, .valid, nil, .unexpectedApplication),
            ("bundle", "1.5.0", "com.example.Other", .valid, nil, .unexpectedApplication),
            ("unsigned", "1.5.0", Self.bundleIdentifier, .missing, nil, .invalidSignature),
            ("tampered", "1.5.0", Self.bundleIdentifier, .broken, nil, .invalidSignature)
        ]
        for (name, applicationVersion, bundleIdentifier, signature, digest, error) in cases {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let applicationURL = try makeApplication(version: "1.4.0", in: directory.appending(path: "Installed"))
            let feedURL = try publish(
                version: "1.5.0",
                applicationVersion: applicationVersion,
                bundleIdentifier: bundleIdentifier,
                signature: signature,
                digest: digest,
                in: directory
            )
            let updater = Updater(
                defaults: isolatedDefaults(named: #function + name),
                currentVersion: "1.4.0",
                applicationURL: applicationURL,
                bundleIdentifier: Self.bundleIdentifier,
                latestReleaseURL: feedURL
            )

            await updater.checkForUpdates()
            await updater.prepareUpdate()
            #expect(updater.phase == .failed(error.localizedDescription), "\(name)")
            #expect(!updater.canInstallUpdate, "\(name)")
            #expect(try version(of: applicationURL) == "1.4.0", "\(name)")
        }
    }

    @MainActor
    private func updater(currentVersion: String, feedURL: URL, in directory: URL, named name: String) -> Updater {
        let applicationURL = directory.appending(path: "Beacon.app", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: applicationURL, withIntermediateDirectories: true)
        return Updater(
            defaults: isolatedDefaults(named: name),
            currentVersion: currentVersion,
            applicationURL: applicationURL,
            bundleIdentifier: Self.bundleIdentifier,
            latestReleaseURL: feedURL
        )
    }

    /// Publishes a release the way the release workflow does: a zipped, ad-hoc signed `Beacon.app` and its digest.
    private func publish(
        version: String,
        applicationVersion: String? = nil,
        bundleIdentifier: String = Self.bundleIdentifier,
        signature: Signature = .valid,
        digest: String? = nil,
        in directory: URL
    ) throws -> URL {
        let releaseURL = directory.appending(path: "Release", directoryHint: .isDirectory)
        let applicationURL = try makeApplication(
            version: applicationVersion ?? version,
            bundleIdentifier: bundleIdentifier,
            signature: signature,
            in: releaseURL
        )
        let archiveURL = releaseURL.appending(path: "Beacon-v\(version).zip")
        try run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", applicationURL.path, archiveURL.path)
        let archiveDigest = try run("/usr/bin/shasum", "-a", "256", archiveURL.path).prefix(64)

        let feedURL = directory.appending(path: "latest.json")
        try feed(tag: "v\(version)", assets: [
            (archiveURL.lastPathComponent, archiveURL.absoluteString, digest ?? "sha256:\(archiveDigest)")
        ]).write(to: feedURL)
        return feedURL
    }

    private func makeApplication(
        version: String,
        bundleIdentifier: String = Self.bundleIdentifier,
        signature: Signature = .missing,
        in directory: URL
    ) throws -> URL {
        let applicationURL = directory.appending(path: "Beacon.app", directoryHint: .isDirectory)
        let executableURL = applicationURL.appending(path: "Contents/MacOS/Beacon")
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        let info = [
            "CFBundleExecutable": "Beacon",
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: applicationURL.appending(path: "Contents/Info.plist"))

        if signature != .missing {
            try run("/usr/bin/codesign", "--force", "--sign", "-", applicationURL.path)
        }
        if signature == .broken {
            try "#!/bin/sh\nexit 1\n".write(to: executableURL, atomically: false, encoding: .utf8)
        }
        return applicationURL
    }

    private func version(of applicationURL: URL) throws -> String? {
        let data = try Data(contentsOf: applicationURL.appending(path: "Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return info?["CFBundleShortVersionString"] as? String
    }

    private func feed(tag: String, assets: [(name: String, url: String, digest: String?)]) throws -> Data {
        let feed: [String: Any] = [
            "tag_name": tag,
            "html_url": "https://github.com/beacon-macos/Beacon/releases/tag/\(tag)",
            "assets": assets.map { asset in
                var object = ["name": asset.name, "browser_download_url": asset.url]
                object["digest"] = asset.digest
                return object
            }
        ]
        return try JSONSerialization.data(withJSONObject: feed)
    }

    @discardableResult
    private func run(_ executablePath: String, _ arguments: String...) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: executablePath)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(executablePath) \(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self)
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
            .appending(path: "BeaconUpdaterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private func isolatedDefaults(named name: String) -> UserDefaults {
        let suiteName = "UpdaterTests.\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
