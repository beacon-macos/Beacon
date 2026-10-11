import AppKit
import Observation
import SwiftUI

struct IndexedApplication: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    let icon: NSImage

    init(url: URL) {
        self.url = url
        name = url.deletingPathExtension().lastPathComponent
        id = url.standardizedFileURL.path
        icon = NSWorkspace.shared.icon(forFile: url.path)
    }

    static func == (lhs: IndexedApplication, rhs: IndexedApplication) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum AppTheme: Int, CaseIterable, Identifiable, Equatable {
    case system
    case light
    case dark

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum BeaconTint {
    case blue
    case green
    case clay
    case sand
}

enum LauncherTarget: Hashable {
    case application(URL)
    case settings
    case extensions
    case url(URL)
    case extensionCommand(extensionID: String, commandID: String)
    case extensionAction(ExtensionAction)
    case extensionListing(ExtensionManager.Listing)
}

/// Compares every property because `@Observable` skips notifying views when `results` is set to an equal value.
struct LauncherResult: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let symbolName: String
    let tint: BeaconTint
    let icon: NSImage?
    let target: LauncherTarget

    var isExtensionCommand: Bool {
        if case .extensionCommand = target { return true }
        return false
    }
}

/// An extension command whose items are shown in place of the regular results.
struct ExtensionCommandSession {
    let extensionName: String
    let title: String
    let placeholder: String
    let icon: NSImage?
    let symbolName: String
    var items: [LauncherResult] = []
    var isLoading = true
    var errorMessage: String?
}

@MainActor
@Observable
final class LauncherModel {
    static let settingsResultID = "command:settings"
    static let extensionsResultID = "command:extensions"

    var query = "" {
        didSet {
            // The search field writes its text back on Return; keep the selection when nothing changed.
            guard query != oldValue else { return }
            selectedIndex = 0
            isSettingsButtonSelected = false
            rebuildResults()
        }
    }
    var results: [LauncherResult] = []
    var selectedIndex = 0
    private(set) var isSettingsButtonSelected = false
    var isIndexing = false
    var shortcutRegistrationError: String?
    private(set) var favoriteIDs: [String]
    private(set) var commandSession: ExtensionCommandSession?
    private(set) var isShowingExtensions = false
    let extensions: ExtensionManager

    var isShowingPage: Bool {
        commandSession != nil || isShowingExtensions
    }

    var canReorderFavoriteForSelection: Bool {
        Self.normalized(query).isEmpty
            && !isShowingPage
            && !isSettingsButtonSelected
            && results.indices.contains(selectedIndex)
    }

    var selectedExtensionListing: ExtensionManager.Listing? {
        guard isShowingExtensions, !isSettingsButtonSelected, results.indices.contains(selectedIndex),
              case .extensionListing(let listing) = results[selectedIndex].target else { return nil }
        return listing
    }

    var onPresent: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onShortcutChanged: ((KeyboardShortcut) -> Void)?

    var shortcut: KeyboardShortcut {
        didSet {
            defaults.set(shortcut.kind.rawValue, forKey: Keys.shortcutKind)
            defaults.set(Int(shortcut.keyCode), forKey: Keys.keyCode)
            defaults.set(Int(shortcut.modifiers), forKey: Keys.modifiers)
            onShortcutChanged?(shortcut)
        }
    }

    var theme: AppTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: Keys.theme)
        }
    }

    private(set) var systemColorScheme: ColorScheme = .light

    var resolvedColorScheme: ColorScheme {
        theme.colorScheme ?? systemColorScheme
    }

    private var applications: [IndexedApplication] = []
    private var extensionCommandResults: [LauncherResult] = []
    private var extensionListingResults: [LauncherResult] = []
    private var commandRunID: UUID?
    private var appearanceObservation: NSKeyValueObservation?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, extensions: ExtensionManager? = nil) {
        self.defaults = defaults
        self.extensions = extensions ?? ExtensionManager()
        if let savedFavoriteIDs = defaults.stringArray(forKey: Keys.favoriteIDs) {
            favoriteIDs = Self.unique(savedFavoriteIDs)
        } else {
            favoriteIDs = [Self.settingsResultID]
        }
        if defaults.object(forKey: Keys.keyCode) != nil {
            shortcut = KeyboardShortcut(
                kind: KeyboardShortcut.Kind(rawValue: defaults.integer(forKey: Keys.shortcutKind)) ?? .keyCombination,
                keyCode: UInt32(defaults.integer(forKey: Keys.keyCode)),
                modifiers: UInt32(defaults.integer(forKey: Keys.modifiers))
            )
        } else {
            shortcut = .default
        }
        if let savedTheme = defaults.object(forKey: Keys.theme) as? Int {
            theme = AppTheme(rawValue: savedTheme) ?? .system
        } else {
            theme = .system
        }
        systemColorScheme = Self.colorScheme(for: NSApplication.shared.effectiveAppearance)
        appearanceObservation = NSApplication.shared.observe(
            \.effectiveAppearance,
            options: [.new]
        ) { [weak self] _, change in
            guard let appearance = change.newValue else { return }
            let scheme = Self.colorScheme(for: appearance)
            Task { @MainActor [weak self] in
                self?.systemColorScheme = scheme
            }
        }
        self.extensions.onInstalledExtensionsChanged = { [weak self] in
            self?.updateExtensionResults()
        }
        updateExtensionResults()
    }

    nonisolated static func colorScheme(for appearance: NSAppearance) -> ColorScheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    func prepareForPresentation() {
        closePage()
        resetQuery()
    }

    func loadApplications() {
        updateApplications(onlyWhenNew: false)
    }

    func checkForNewApplications() {
        updateApplications(onlyWhenNew: true)
    }

    private func updateApplications(onlyWhenNew: Bool) {
        guard !isIndexing else { return }
        isIndexing = true
        let indexedPaths = Set(applications.map(\.id))

        Task {
            let urls = await Task.detached(priority: .utility) {
                Self.discoverApplicationURLs()
            }.value
            if !onlyWhenNew || Self.containsNewApplication(in: urls, indexedPaths: indexedPaths) {
                applications = urls.map(IndexedApplication.init)
                rebuildResults()
            }
            isIndexing = false
        }
    }

    func moveSelection(by offset: Int) {
        guard offset != 0 else { return }
        guard !results.isEmpty else {
            if offset > 0 {
                isSettingsButtonSelected = true
            }
            return
        }

        let currentPosition = isSettingsButtonSelected ? results.count : selectedIndex
        let nextPosition = min(max(currentPosition + offset, 0), results.count)
        isSettingsButtonSelected = nextPosition == results.count
        selectedIndex = min(nextPosition, results.count - 1)
    }

    func selectResult(at index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
        isSettingsButtonSelected = false
    }

    func moveFavoriteForSelection(by offset: Int) {
        guard canReorderFavoriteForSelection, offset != 0 else { return }

        let destinationIndex = selectedIndex + offset
        guard results.indices.contains(destinationIndex) else { return }

        let selectedID = results[selectedIndex].id
        let destinationID = results[destinationIndex].id
        guard let favoriteIndex = favoriteIDs.firstIndex(of: selectedID),
              let destinationFavoriteIndex = favoriteIDs.firstIndex(of: destinationID) else { return }

        favoriteIDs.swapAt(favoriteIndex, destinationFavoriteIndex)
        defaults.set(favoriteIDs, forKey: Keys.favoriteIDs)
        rebuildResults()

        if let reorderedIndex = results.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = reorderedIndex
        }
    }

    func runSelected() {
        if isSettingsButtonSelected {
            openSettings()
            return
        }
        guard results.indices.contains(selectedIndex) else { return }
        run(results[selectedIndex])
    }

    func run(_ result: LauncherResult) {
        switch result.target {
        case .application(let url):
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        case .settings:
            openSettings()
            return
        case .extensions:
            openExtensions()
            return
        case .url(let url):
            NSWorkspace.shared.open(url)
        case .extensionCommand(let extensionID, let commandID):
            runExtensionCommand(extensionID: extensionID, commandID: commandID)
            return
        case .extensionAction(let action):
            perform(action)
        case .extensionListing(let listing):
            if !listing.isInstalled || extensions.isUpdateAvailable(for: listing.id) {
                Task { await extensions.install(listing.id) }
            }
            return
        }
        dismiss()
    }

    func openExtensions() {
        closePage()
        isShowingExtensions = true
        resetQuery()
        refreshExtensionCatalog()
    }

    func presentExtensions() {
        onPresent?()
        openExtensions()
    }

    func refreshExtensionCatalog() {
        Task {
            await extensions.refreshCatalog()
            updateExtensionResults()
        }
    }

    @discardableResult
    func uninstallSelectedExtension() -> Bool {
        guard let listing = selectedExtensionListing,
              listing.isInstalled,
              !extensions.busyExtensionIDs.contains(listing.id) else { return false }
        extensions.uninstall(listing.id)
        return true
    }

    func runExtensionCommand(extensionID: String, commandID: String) {
        guard let installedExtension = extensions.installedExtension(withID: extensionID),
              let command = installedExtension.manifest.commands.first(where: { $0.id == commandID }) else { return }

        let runID = UUID()
        commandRunID = runID
        commandSession = ExtensionCommandSession(
            extensionName: installedExtension.manifest.name,
            title: command.title,
            placeholder: command.placeholder ?? "Search \(command.title)",
            icon: Self.image(for: installedExtension.manifest.icon),
            symbolName: installedExtension.manifest.icon?.symbol ?? Self.extensionSymbolName
        )
        resetQuery()

        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try ExtensionRuntime.runCommand(commandID, in: installedExtension) }
            }.value
            guard commandRunID == runID else { return }
            switch outcome {
            case .success(let items):
                commandSession?.items = items.enumerated().map { index, item in
                    Self.result(for: item, at: index, extensionID: extensionID)
                }
            case .failure(let error):
                commandSession?.errorMessage = error.localizedDescription
            }
            commandSession?.isLoading = false
            rebuildResults()
        }
    }

    /// Leaves the open extension command or extensions page, or dismisses the launcher when neither is open.
    func goBack() {
        guard isShowingPage else {
            dismiss()
            return
        }
        closePage()
        resetQuery()
    }

    private func resetQuery() {
        query = ""
        selectedIndex = 0
        isSettingsButtonSelected = false
        rebuildResults()
    }

    private func closePage() {
        commandRunID = nil
        commandSession = nil
        isShowingExtensions = false
    }

    private func perform(_ action: ExtensionAction) {
        switch action {
        case .open(let target, let application):
            guard let url = ExtensionAction.url(forTarget: target) else { return }
            if let application,
               let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: application) {
                NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: applicationURL,
                    configuration: NSWorkspace.OpenConfiguration(),
                    completionHandler: nil
                )
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func isFavorite(_ result: LauncherResult) -> Bool {
        favoriteIDs.contains(result.id)
    }

    @discardableResult
    func toggleFavoriteForSelection() -> Bool {
        guard !isSettingsButtonSelected, !isShowingPage else { return false }
        guard results.indices.contains(selectedIndex) else { return false }
        let result = results[selectedIndex]
        guard result.id != "command:web-search" else { return false }

        if let index = favoriteIDs.firstIndex(of: result.id) {
            favoriteIDs.remove(at: index)
        } else {
            favoriteIDs.append(result.id)
        }
        defaults.set(favoriteIDs, forKey: Keys.favoriteIDs)

        if Self.normalized(query).isEmpty {
            rebuildResults()
        }
        return true
    }

    func dismiss() {
        onDismiss?()
    }

    func openSettings() {
        dismiss()
        onOpenSettings?()
    }

    func updateShortcut(_ shortcut: KeyboardShortcut) {
        self.shortcut = shortcut
    }

    func resetShortcut() {
        shortcut = .default
    }

    func updateTheme(_ theme: AppTheme) {
        self.theme = theme
    }

    private func rebuildResults() {
        let normalizedQuery = Self.normalized(query)
        if let commandSession {
            results = Self.ranked(commandSession.items, query: normalizedQuery)
            selectedIndex = results.isEmpty ? 0 : min(selectedIndex, results.count - 1)
            return
        }
        if isShowingExtensions {
            results = Self.ranked(extensionListingResults, query: normalizedQuery)
            selectedIndex = results.isEmpty ? 0 : min(selectedIndex, results.count - 1)
            return
        }

        var candidates = commandResults()
        candidates.append(contentsOf: extensionCommandResults)
        candidates.append(contentsOf: applications.map { app in
            LauncherResult(
                id: "app:\(app.id)",
                title: app.name,
                subtitle: "Application",
                symbolName: "app",
                tint: .blue,
                icon: app.icon,
                target: .application(app.url)
            )
        })

        if normalizedQuery.isEmpty {
            let candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
            results = favoriteIDs.compactMap { candidatesByID[$0] }
        } else {
            results = candidates.compactMap { candidate -> (LauncherResult, Int)? in
                guard let score = Self.matchScore(query: normalizedQuery, candidate: Self.normalized(candidate.title + " " + candidate.subtitle)) else {
                    return nil
                }
                return (candidate, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 { return lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending }
                return lhs.1 > rhs.1
            }
            .prefix(30)
            .map(\.0)

            if let webURL = Self.webSearchURL(for: query) {
                results.append(
                    LauncherResult(
                        id: "command:web-search",
                        title: "Search the web for “\(query)”",
                        subtitle: "Open in the default browser",
                        symbolName: "globe",
                        tint: .green,
                        icon: nil,
                        target: .url(webURL)
                    )
                )
            }
        }
        selectedIndex = results.isEmpty ? 0 : min(selectedIndex, results.count - 1)
    }

    private func updateExtensionResults() {
        extensionCommandResults = extensions.installed.flatMap { installedExtension in
            let manifest = installedExtension.manifest
            let icon = Self.image(for: manifest.icon)
            return manifest.commands.map { command in
                LauncherResult(
                    id: "extension:\(manifest.id):\(command.id)",
                    title: command.title,
                    subtitle: command.subtitle ?? manifest.name,
                    symbolName: manifest.icon?.symbol ?? Self.extensionSymbolName,
                    tint: .blue,
                    icon: icon,
                    target: .extensionCommand(extensionID: manifest.id, commandID: command.id)
                )
            }
        }
        extensionListingResults = extensions.listings.map(Self.result(for:))
        if commandSession == nil {
            rebuildResults()
        }
    }

    private func commandResults() -> [LauncherResult] {
        return [
            LauncherResult(
                id: Self.settingsResultID,
                title: "Beacon Settings",
                subtitle: "Shortcut and launcher preferences",
                symbolName: "gearshape.fill",
                tint: .clay,
                icon: nil,
                target: .settings
            ),
            LauncherResult(
                id: Self.extensionsResultID,
                title: "Manage Extensions",
                subtitle: "Install, update, and remove Beacon extensions",
                symbolName: Self.extensionSymbolName,
                tint: .blue,
                icon: nil,
                target: .extensions
            ),
            LauncherResult(
                id: "command:applications",
                title: "Applications",
                subtitle: "Open folder in Finder",
                symbolName: "square.grid.2x2.fill",
                tint: .sand,
                icon: nil,
                target: .url(URL(filePath: "/Applications"))
            )
        ]
    }

    private static let extensionSymbolName = "puzzlepiece.extension.fill"

    private static func result(for item: ExtensionItem, at index: Int, extensionID: String) -> LauncherResult {
        LauncherResult(
            id: "extension-item:\(extensionID):\(index)",
            title: item.title,
            subtitle: item.subtitle ?? "",
            symbolName: item.icon?.symbol ?? "circle.fill",
            tint: .blue,
            icon: image(for: item.icon),
            target: .extensionAction(item.action)
        )
    }

    private static func result(for listing: ExtensionManager.Listing) -> LauncherResult {
        LauncherResult(
            id: "extension-listing:\(listing.id)",
            title: listing.name,
            subtitle: listing.description,
            symbolName: listing.icon?.symbol ?? extensionSymbolName,
            tint: .blue,
            icon: image(for: listing.icon),
            target: .extensionListing(listing)
        )
    }

    static func image(for icon: ExtensionIcon?) -> NSImage? {
        if let bundleIdentifier = icon?.app,
           let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: applicationURL.path)
        }
        if let path = icon?.file {
            let expandedPath = ExtensionRuntime.expandingTilde(in: path)
            guard FileManager.default.fileExists(atPath: expandedPath) else { return nil }
            return NSWorkspace.shared.icon(forFile: expandedPath)
        }
        return nil
    }

    /// Filters items by the query, keeping their original order when nothing is typed or scores tie.
    static func ranked(_ items: [LauncherResult], query: String) -> [LauncherResult] {
        guard !query.isEmpty else { return items }
        return items.enumerated().compactMap { index, item -> (index: Int, item: LauncherResult, score: Int)? in
            guard let score = matchScore(query: query, candidate: normalized(item.title + " " + item.subtitle)) else {
                return nil
            }
            return (index, item, score)
        }
        .sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
        .map(\.item)
    }

    nonisolated static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    nonisolated static func matchScore(query: String, candidate: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        if candidate == query { return 1_000 }
        if candidate.hasPrefix(query) { return 800 - candidate.count }
        if let range = candidate.range(of: query) {
            return 600 - candidate.distance(from: candidate.startIndex, to: range.lowerBound)
        }

        var queryIndex = query.startIndex
        var score = 0
        var lastMatch: String.Index?
        for index in candidate.indices where queryIndex < query.endIndex {
            if candidate[index] == query[queryIndex] {
                score += lastMatch.map { candidate.index(after: $0) == index ? 16 : 5 } ?? 5
                lastMatch = index
                query.formIndex(after: &queryIndex)
            }
        }
        return queryIndex == query.endIndex ? score : nil
    }

    nonisolated static func containsNewApplication(in urls: [URL], indexedPaths: Set<String>) -> Bool {
        urls.contains { !indexedPaths.contains($0.standardizedFileURL.path) }
    }

    nonisolated private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    nonisolated private static func discoverApplicationURLs() -> [URL] {
        let roots = [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            URL(filePath: "/System/Applications", directoryHint: .isDirectory),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory)
        ]
        let keys: [URLResourceKey] = [.isApplicationKey, .isDirectoryKey]
        var found: [String: URL] = [:]

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
                found[url.standardizedFileURL.path] = url
            }
        }
        return found.values.sorted {
            $0.deletingPathExtension().lastPathComponent.localizedStandardCompare(
                $1.deletingPathExtension().lastPathComponent
            ) == .orderedAscending
        }
    }

    nonisolated private static func webSearchURL(for query: String) -> URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    private enum Keys {
        static let shortcutKind = "launcherShortcutKind"
        static let keyCode = "launcherShortcutKeyCode"
        static let modifiers = "launcherShortcutModifiers"
        static let favoriteIDs = "launcherFavoriteIDs"
        static let theme = "launcherTheme"
    }
}

extension LauncherModel {
    static var preview: LauncherModel {
        let model = LauncherModel(defaults: UserDefaults(suiteName: "BeaconPreview")!)
        return model
    }
}
