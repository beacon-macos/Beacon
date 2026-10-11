import AppKit
import Foundation
import Testing
@testable import Beacon

@MainActor
struct ClipboardHistoryTests {

    private static let safari = ClipboardHistory.Source(name: "Safari", bundleIdentifier: "com.apple.Safari")

    @MainActor
    private struct Fixture {
        let history: ClipboardHistory
        let pasteboard: NSPasteboard
        let defaults: UserDefaults
        let storageURL: URL
        let directory: URL

        func copy(_ text: String, markedAs types: [NSPasteboard.PasteboardType] = []) {
            pasteboard.declareTypes([.string] + types, owner: nil)
            pasteboard.setString(text, forType: .string)
            for type in types {
                pasteboard.setData(Data(), forType: type)
            }
            history.checkPasteboard()
        }

        func restoredHistory() async -> ClipboardHistory {
            let history = ClipboardHistory(pasteboard: pasteboard, storageURL: storageURL, defaults: defaults)
            await history.load()
            return history
        }

        func cleanUp() {
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test func copiedTextIsRecordedNewestFirstWithoutDuplicates() async throws {
        let fixture = try await makeFixture(named: #function)
        defer { fixture.cleanUp() }

        fixture.copy("one")
        fixture.copy("two")
        fixture.history.checkPasteboard()
        #expect(fixture.history.entries.map(\.text) == ["two", "one"])

        fixture.copy("one")
        #expect(fixture.history.entries.map(\.text) == ["one", "two"])
        #expect(fixture.history.entries.allSatisfy { $0.source == Self.safari })
    }

    @Test func privateBlankFileAndOversizedCopiesAreSkipped() async throws {
        let fixture = try await makeFixture(named: #function)
        defer { fixture.cleanUp() }

        fixture.copy("hunter2", markedAs: [NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")])
        fixture.copy("one-time code", markedAs: [NSPasteboard.PasteboardType("org.nspasteboard.TransientType")])
        fixture.copy(" \n\t ")
        fixture.copy("Report.pdf", markedAs: [.fileURL])
        fixture.copy(String(repeating: "a", count: ClipboardHistory.maximumTextLength + 1))
        #expect(fixture.history.entries.isEmpty)

        fixture.copy(String(repeating: "a", count: ClipboardHistory.maximumTextLength))
        #expect(fixture.history.entries.count == 1)
    }

    @Test func onlyTheNewestEntriesAreKept() async throws {
        let fixture = try await makeFixture(named: #function)
        defer { fixture.cleanUp() }

        for number in 1...(ClipboardHistory.maximumEntryCount + 5) {
            fixture.copy("item \(number)")
        }

        #expect(fixture.history.entries.count == ClipboardHistory.maximumEntryCount)
        #expect(fixture.history.entries.first?.text == "item \(ClipboardHistory.maximumEntryCount + 5)")
        #expect(fixture.history.entries.last?.text == "item 6")
    }

    @Test func historyIsSavedAndRestored() async throws {
        let fixture = try await makeFixture(named: #function)
        defer { fixture.cleanUp() }

        fixture.copy("one")
        fixture.copy("two")
        try await waitUntil { savedTexts(at: fixture.storageURL) == ["two", "one"] }

        let restored = await fixture.restoredHistory()
        #expect(restored.entries.map(\.id) == fixture.history.entries.map(\.id))
        #expect(restored.entries.map(\.text) == ["two", "one"])
        #expect(restored.entries.allSatisfy { $0.source == Self.safari })

        fixture.history.remove(try #require(fixture.history.entries.first))
        try await waitUntil { savedTexts(at: fixture.storageURL) == ["one"] }

        fixture.history.clear()
        try await waitUntil { !FileManager.default.fileExists(atPath: fixture.storageURL.path) }
    }

    @Test func turningHistoryOffDeletesItAndStopsRecording() async throws {
        let fixture = try await makeFixture(named: #function)
        defer { fixture.cleanUp() }

        fixture.copy("one")
        try await waitUntil { savedTexts(at: fixture.storageURL) == ["one"] }

        fixture.history.isEnabled = false
        #expect(fixture.history.entries.isEmpty)
        try await waitUntil { !FileManager.default.fileExists(atPath: fixture.storageURL.path) }

        fixture.copy("two")
        #expect(fixture.history.entries.isEmpty)
        let restored = await fixture.restoredHistory()
        #expect(!restored.isEnabled)
    }

    @Test func nothingIsRecordedBeforeTheSavedHistoryLoads() async throws {
        let fixture = try await makeFixture(named: #function, loads: false)
        defer { fixture.cleanUp() }
        try JSONEncoder().encode([
            ClipboardHistory.Entry(id: UUID(), text: "saved", date: .now, source: nil)
        ]).write(to: fixture.storageURL)

        fixture.copy("early")
        fixture.history.copy("from Beacon")
        #expect(fixture.history.entries.isEmpty)

        await fixture.history.load()
        fixture.copy("late")
        #expect(fixture.history.entries.map(\.text) == ["late", "saved"])
    }

    @Test func searchMatchesEveryWordAnywhereInTheText() async throws {
        let fixture = try await makeFixture(named: #function)
        defer { fixture.cleanUp() }

        fixture.copy("Hello Wörld from Beacon")
        fixture.copy("first line\nsecond line with café")

        #expect(fixture.history.entries(matching: "").count == 2)
        #expect(fixture.history.entries(matching: "  beacon WORLD ").map(\.text) == ["Hello Wörld from Beacon"])
        #expect(fixture.history.entries(matching: "cafe second").map(\.text) == ["first line\nsecond line with café"])
        #expect(fixture.history.entries(matching: "hello cafe").isEmpty)
    }

    @Test func previewShowsTheTextOnOneLine() {
        #expect(ClipboardHistory.preview(of: "\n\n  first line\n\tsecond   line ") == "first line second line")
        #expect(ClipboardHistory.preview(of: String(repeating: "a", count: 1_000)).count == 300)
    }

    @Test func launcherPageCopiesTheSelectedEntryAndDismisses() async throws {
        let fixture = try await makeFixture(named: #function)
        defer { fixture.cleanUp() }
        let model = LauncherModel(defaults: fixture.defaults, clipboardHistory: fixture.history)
        var dismissalCount = 0
        model.onDismiss = { dismissalCount += 1 }
        fixture.copy("alpha")
        fixture.copy("beta")

        model.query = "clipboard history"
        try #require(model.results.first?.id == LauncherModel.clipboardHistoryResultID)
        model.runSelected()
        #expect(model.isShowingClipboardHistory)
        #expect(model.query.isEmpty)
        #expect(model.results.map(\.title) == ["beta", "alpha"])
        #expect(model.results.allSatisfy { $0.subtitle.hasPrefix("Safari · ") })
        #expect(dismissalCount == 0)

        model.moveSelection(by: 1)
        model.runSelected()
        #expect(dismissalCount == 1)
        #expect(fixture.pasteboard.string(forType: .string) == "alpha")
        #expect(fixture.history.entries.map(\.text) == ["alpha", "beta"])
        #expect(fixture.history.entries.first?.source == Self.safari)
    }

    @Test func launcherPageFiltersAndDeletesEntries() async throws {
        let fixture = try await makeFixture(named: #function)
        defer { fixture.cleanUp() }
        let model = LauncherModel(defaults: fixture.defaults, clipboardHistory: fixture.history)
        fixture.copy("alpha")
        fixture.copy("beta")

        model.openClipboardHistory()
        #expect(!model.toggleFavoriteForSelection())
        model.query = "alp"
        #expect(model.results.map(\.title) == ["alpha"])

        #expect(model.removeSelectedClipboardEntry())
        #expect(model.results.isEmpty)
        #expect(fixture.history.entries.map(\.text) == ["beta"])
        #expect(!model.removeSelectedClipboardEntry())

        fixture.copy("gamma")
        model.query = ""
        #expect(model.results.map(\.title) == ["gamma", "beta"])

        model.goBack()
        #expect(!model.isShowingPage)
        #expect(!model.removeSelectedClipboardEntry())
    }

    @Test func copiedCalculationIsRecordedFromBeacon() async throws {
        let fixture = try await makeFixture(named: #function)
        defer { fixture.cleanUp() }
        let model = LauncherModel(
            defaults: fixture.defaults,
            clipboardHistory: fixture.history,
            locale: Locale(identifier: "en_US")
        )

        model.query = "2+2"
        try #require(model.results.first?.id == LauncherModel.calculationResultID)
        model.runSelected()

        #expect(fixture.pasteboard.string(forType: .string) == "4")
        #expect(fixture.history.entries.map(\.text) == ["4"])
        #expect(fixture.history.entries.first?.source?.name == "Beacon")
    }

    private func makeFixture(named name: String, loads: Bool = true) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BeaconClipboardHistoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = "ClipboardHistoryTests.\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let pasteboard = NSPasteboard.withUniqueName()
        let storageURL = directory.appending(path: "ClipboardHistory.json")
        let history = ClipboardHistory(
            pasteboard: pasteboard,
            storageURL: storageURL,
            defaults: defaults,
            frontmostSource: { Self.safari }
        )
        if loads {
            await history.load()
        }
        return Fixture(
            history: history,
            pasteboard: pasteboard,
            defaults: defaults,
            storageURL: storageURL,
            directory: directory
        )
    }

    private func savedTexts(at url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([ClipboardHistory.Entry].self, from: data).map(\.text)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
