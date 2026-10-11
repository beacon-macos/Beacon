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
    case clipboardHistory
    case clipboardEntry(ClipboardHistory.Entry)
    case copy(String)
    case reloadExchangeRates
    case checkForUpdates
    case update
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
    static let clipboardHistoryResultID = "command:clipboard-history"
    static let calculationResultID = "command:calculation"
    static let updateResultID = "command:update"

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
    private(set) var isShowingClipboardHistory = false
    let extensions: ExtensionManager
    let clipboardHistory: ClipboardHistory
    let exchangeRates: ExchangeRates
    let updater: Updater

    var isShowingPage: Bool {
        commandSession != nil || isShowingExtensions || isShowingClipboardHistory
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
    private var currencyNames: CurrencyNames?
    private var isLoadingCurrencyNames = false
    private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored private var applicationIcons: [String: NSImage] = [:]
    private let defaults: UserDefaults
    private let locale: Locale

    init(
        defaults: UserDefaults = .standard,
        extensions: ExtensionManager? = nil,
        clipboardHistory: ClipboardHistory? = nil,
        exchangeRates: ExchangeRates? = nil,
        updater: Updater? = nil,
        locale: Locale = .autoupdatingCurrent
    ) {
        self.defaults = defaults
        self.extensions = extensions ?? ExtensionManager()
        self.clipboardHistory = clipboardHistory ?? ClipboardHistory(defaults: defaults)
        self.exchangeRates = exchangeRates ?? ExchangeRates()
        self.updater = updater ?? Updater(defaults: defaults)
        self.locale = locale
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
        self.clipboardHistory.onChange = { [weak self] in
            guard self?.isShowingClipboardHistory == true else { return }
            self?.rebuildResults()
        }
        self.exchangeRates.onChange = { [weak self] in
            self?.rebuildResults()
        }
        self.updater.onChange = { [weak self] in
            self?.rebuildResults()
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
        case .clipboardHistory:
            openClipboardHistory()
            return
        case .clipboardEntry(let entry):
            clipboardHistory.copy(entry.text, source: entry.source)
        case .copy(let text):
            clipboardHistory.copy(text)
        case .reloadExchangeRates:
            exchangeRates.refresh()
            rebuildResults()
            return
        case .checkForUpdates:
            Task { await updater.checkForUpdates() }
            return
        case .update:
            installUpdate()
            return
        }
        dismiss()
    }

    /// Installs the update and relaunches Beacon, or opens the release page when Beacon cannot replace itself.
    func installUpdate() {
        if updater.canInstallUpdate {
            Task { await updater.installUpdate() }
        } else if let pageURL = updater.release?.pageURL {
            NSWorkspace.shared.open(pageURL)
            dismiss()
        }
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

    func openClipboardHistory() {
        closePage()
        isShowingClipboardHistory = true
        resetQuery()
    }

    @discardableResult
    func removeSelectedClipboardEntry() -> Bool {
        guard isShowingClipboardHistory, !isSettingsButtonSelected, results.indices.contains(selectedIndex),
              case .clipboardEntry(let entry) = results[selectedIndex].target else { return false }
        clipboardHistory.remove(entry)
        return true
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

    /// Leaves the open extension command or launcher page, or dismisses the launcher when none is open.
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
        isShowingClipboardHistory = false
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
        guard result.id != "command:web-search",
              result.id != Self.calculationResultID,
              result.id != Self.updateResultID else { return false }

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
        if isShowingClipboardHistory {
            results = clipboardHistory.entries(matching: query).map(clipboardResult(for:))
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
            if updater.release != nil {
                results.append(updateResult())
            }
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

            if let calculation = calculationResult() {
                results.insert(calculation, at: 0)
            }
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

    private func calculationResult() -> LauncherResult? {
        let expression = query.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "=")))
        if let value = Calculator.evaluate(expression, locale: locale) {
            return LauncherResult(
                id: Self.calculationResultID,
                title: "\(expression) = \(Calculator.format(value, locale: locale))",
                subtitle: "Calculator",
                symbolName: "plus.forwardslash.minus",
                tint: .sand,
                icon: nil,
                target: .copy(Calculator.format(value, locale: locale, usesGrouping: false))
            )
        }

        guard CurrencyNames.mightContainConversion(expression) else { return nil }
        guard let currencyNames else {
            loadCurrencyNames()
            return nil
        }
        guard let conversion = CurrencyConversion.parse(
            expression,
            names: currencyNames,
            localCurrency: locale.currency?.identifier,
            locale: locale
        ) else { return nil }
        exchangeRates.refreshIfNeeded()

        let amount = "\(Calculator.format(conversion.amount, locale: locale)) \(conversion.source)"
        let currencies = "\(currencyName(conversion.source)) → \(currencyName(conversion.target))"
        guard let snapshot = exchangeRates.snapshot else {
            return LauncherResult(
                id: Self.calculationResultID,
                title: "\(amount) → \(conversion.target)",
                subtitle: exchangeRates.isLoading
                    ? "Loading exchange rates…"
                    : "Couldn’t load exchange rates. Press Return to try again.",
                symbolName: "dollarsign.arrow.circlepath",
                tint: .green,
                icon: nil,
                target: .reloadExchangeRates
            )
        }
        guard let rate = exchangeRates.rate(from: conversion.source, to: conversion.target) else { return nil }

        let convertedAmount = conversion.amount * rate
        return LauncherResult(
            id: Self.calculationResultID,
            title: "\(amount) = \(CurrencyConversion.format(convertedAmount, locale: locale)) \(conversion.target)",
            subtitle: "\(currencies) · Rates from \(ratesDate(snapshot))",
            symbolName: "dollarsign.arrow.circlepath",
            tint: .green,
            icon: nil,
            target: .copy(CurrencyConversion.format(convertedAmount, locale: locale, usesGrouping: false))
        )
    }

    private func loadCurrencyNames() {
        guard !isLoadingCurrencyNames else { return }
        isLoadingCurrencyNames = true
        Task {
            currencyNames = await Task.detached(priority: .userInitiated) { CurrencyNames.shared }.value
            rebuildResults()
        }
    }

    private func currencyName(_ code: String) -> String {
        locale.localizedString(forCurrencyCode: code) ?? code
    }

    private func ratesDate(_ snapshot: ExchangeRates.Snapshot) -> String {
        guard let date = try? Date(snapshot.date, strategy: .iso8601.year().month().day()) else { return snapshot.date }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: .gmt))
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
                id: Self.clipboardHistoryResultID,
                title: "Clipboard History",
                subtitle: "Find and copy text you copied before",
                symbolName: "doc.on.clipboard.fill",
                tint: .sand,
                icon: nil,
                target: .clipboardHistory
            ),
            LauncherResult(
                id: "command:applications",
                title: "Applications",
                subtitle: "Open folder in Finder",
                symbolName: "square.grid.2x2.fill",
                tint: .sand,
                icon: nil,
                target: .url(URL(filePath: "/Applications"))
            ),
            updateResult()
        ]
    }

    /// Offers the available update, or a command that checks for one.
    private func updateResult() -> LauncherResult {
        guard let release = updater.release else {
            let subtitle = if updater.isChecking {
                "Checking for a newer version…"
            } else if updater.checkErrorMessage != nil {
                "Couldn’t check for updates. Press Return to try again."
            } else if updater.lastCheckDate != nil {
                "Beacon \(updater.currentVersion) is the latest version"
            } else {
                "Look for a newer version of Beacon"
            }
            return LauncherResult(
                id: Self.updateResultID,
                title: "Check for Updates",
                subtitle: subtitle,
                symbolName: "arrow.trianglehead.2.clockwise",
                tint: .green,
                icon: nil,
                target: .checkForUpdates
            )
        }

        let subtitle = switch updater.phase {
        case .idle where updater.canInstallUpdate: "Press Return to update and relaunch Beacon"
        case .idle: "Press Return to download it from GitHub"
        case .downloading: "Downloading the update…"
        case .ready: "Press Return to relaunch Beacon and finish the update"
        case .installed: "Relaunching Beacon…"
        case .failed: "Couldn’t install the update. Press Return to download it from GitHub."
        }
        return LauncherResult(
            id: Self.updateResultID,
            title: "Beacon \(release.version) is available",
            subtitle: subtitle,
            symbolName: "arrow.down.circle.fill",
            tint: .green,
            icon: nil,
            target: .update
        )
    }

    private func clipboardResult(for entry: ClipboardHistory.Entry) -> LauncherResult {
        let date = entry.date.formatted(.relative(presentation: .named))
        return LauncherResult(
            id: "clipboard:\(entry.id.uuidString)",
            title: ClipboardHistory.preview(of: entry.text),
            subtitle: entry.source.map { "\($0.name) · \(date)" } ?? date,
            symbolName: "doc.plaintext",
            tint: .sand,
            icon: applicationIcon(bundleIdentifier: entry.source?.bundleIdentifier),
            target: .clipboardEntry(entry)
        )
    }

    private func applicationIcon(bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier else { return nil }
        if let icon = applicationIcons[bundleIdentifier] { return icon }
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        applicationIcons[bundleIdentifier] = icon
        return icon
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
