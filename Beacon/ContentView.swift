//
//  ContentView.swift
//  Beacon
//
//  Created by Denys Yazan on 22.08.2026.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(\.openSettings) private var openSettings
    @Bindable var model: LauncherModel
    @FocusState private var searchFocused: Bool
    @State private var lastPointerLocation: NSPoint?

    private var scheme: ColorScheme {
        model.resolvedColorScheme
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.65)
            if model.isShowingExtensions {
                extensionsNotice
                Divider().opacity(0.65)
            }
            results
            Divider().opacity(0.65)
            footer
        }
        .frame(width: 720, height: 500)
        .background(Color.beaconCanvas(scheme))
        .animation(.easeInOut(duration: 0.25), value: scheme)
        .task {
            model.onOpenSettings = {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            await focusSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .beaconDidShow)) { _ in
            Task { await focusSearch() }
        }
        .onExitCommand {
            model.goBack()
        }
        .onKeyPress(.delete, phases: [.down, .repeat]) { keyPress in
            if keyPress.modifiers.contains(.command), model.isShowingExtensions || model.isShowingClipboardHistory {
                if keyPress.phase == .down {
                    if model.isShowingExtensions {
                        model.uninstallSelectedExtension()
                    } else {
                        model.removeSelectedClipboardEntry()
                    }
                }
                return .handled
            }
            guard model.isShowingPage, model.query.isEmpty else { return .ignored }
            model.goBack()
            return .handled
        }
        .onKeyPress(.upArrow, phases: [.down, .repeat]) { keyPress in
            if keyPress.modifiers.contains(.option), model.canReorderFavoriteForSelection {
                model.moveFavoriteForSelection(by: -1)
                return .handled
            }
            model.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow, phases: [.down, .repeat]) { keyPress in
            if keyPress.modifiers.contains(.option), model.canReorderFavoriteForSelection {
                model.moveFavoriteForSelection(by: 1)
                return .handled
            }
            model.moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            guard model.isSettingsButtonSelected || LauncherModel.normalized(model.query).isEmpty else {
                return .ignored
            }
            model.runSelected()
            return .handled
        }
        .onKeyPress("k", phases: .down) { keyPress in
            guard keyPress.modifiers.contains(.command) else { return .ignored }
            return model.toggleFavoriteForSelection() ? .handled : .ignored
        }
        .onChange(of: model.query) { _, _ in
            lastPointerLocation = NSEvent.mouseLocation
        }
    }

    private var searchBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.beaconInk(scheme))

            if let session = model.commandSession {
                pageChip(
                    title: session.title,
                    icon: session.icon,
                    symbolName: session.symbolName,
                    accessibilityLabel: "\(session.title), \(session.extensionName). Back to all results",
                    identifier: "extensionCommandChip"
                )
            } else if model.isShowingExtensions {
                pageChip(
                    title: "Extensions",
                    icon: nil,
                    symbolName: "puzzlepiece.extension.fill",
                    accessibilityLabel: "Extensions. Back to all results",
                    identifier: "extensionsPageChip"
                )
            } else if model.isShowingClipboardHistory {
                pageChip(
                    title: "Clipboard History",
                    icon: nil,
                    symbolName: "doc.on.clipboard.fill",
                    accessibilityLabel: "Clipboard History. Back to all results",
                    identifier: "clipboardHistoryChip"
                )
            }

            TextField(searchPlaceholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundStyle(Color.beaconInk(scheme))
                .focused($searchFocused)
                .onSubmit { runCurrentSelection() }
                .accessibilityIdentifier("launcherSearchField")
        }
        .padding(.horizontal, 22)
        .frame(height: 72)
    }

    private var searchPlaceholder: String {
        if let session = model.commandSession { return session.placeholder }
        if model.isShowingClipboardHistory { return "Search clipboard history" }
        return model.isShowingExtensions ? "Search extensions" : "Search apps and commands"
    }

    private func pageChip(
        title: String,
        icon: NSImage?,
        symbolName: String,
        accessibilityLabel: String,
        identifier: String
    ) -> some View {
        Button {
            model.goBack()
        } label: {
            HStack(spacing: 6) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: symbolName)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.beaconInk(scheme))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color.beaconSelection(scheme))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Back to all results")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(identifier)
    }

    private var extensionsNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Extensions come from")
                Link(
                    ExtensionManager.repositoryName,
                    destination: URL(string: "https://github.com/\(ExtensionManager.repositoryName)")!
                )
                Text("and can read your files. Install only extensions you trust.")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Color.beaconMuted(scheme))

            if let errorMessage = extensionsErrorMessage {
                HStack(spacing: 12) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.beaconErrorText(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if model.extensions.errorMessage == nil {
                        Button("Try Again") {
                            model.refreshExtensionCatalog()
                        }
                        .controlSize(.small)
                    }
                }
                .padding(10)
                .background(Color.beaconErrorBackground(scheme))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("extensionsNotice")
    }

    private var extensionsErrorMessage: String? {
        if let errorMessage = model.extensions.errorMessage { return errorMessage }
        guard case .failed(let message) = model.extensions.catalogState, !model.results.isEmpty else { return nil }
        return "Couldn’t load the extension catalog. \(message)"
    }

    @ViewBuilder
    private var results: some View {
        if model.results.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: emptyStateSymbol)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Color.beaconMuted(scheme))
                    .symbolEffect(.rotate, isActive: isLoadingResults)
                Text(emptyStateTitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.beaconMuted(scheme))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                if model.query.isEmpty && !model.isIndexing && !model.isShowingPage {
                    Text("Search for an app or command, then press ⌘K")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.beaconMuted(scheme))
                }
                if model.isShowingExtensions, model.query.isEmpty, isExtensionCatalogFailed {
                    Button("Try Again") {
                        model.refreshExtensionCatalog()
                    }
                }
                if model.isShowingClipboardHistory, !model.clipboardHistory.isEnabled {
                    Button("Turn On Clipboard History") {
                        model.clipboardHistory.isEnabled = true
                    }
                    .accessibilityIdentifier("turnOnClipboardHistoryButton")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                            resultRow(result, at: index)
                                .id(result.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: model.selectedIndex) { _, index in
                    guard model.results.indices.contains(index) else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(model.results[index].id, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ result: LauncherResult, at index: Int) -> some View {
        let isSelected = !model.isSettingsButtonSelected && index == model.selectedIndex
        if case .extensionListing(let listing) = result.target {
            ExtensionListingRow(
                listing: listing,
                icon: result.icon,
                symbolName: result.symbolName,
                isSelected: isSelected,
                isBusy: model.extensions.busyExtensionIDs.contains(listing.id),
                isUpdateAvailable: model.extensions.isUpdateAvailable(for: listing.id),
                scheme: scheme,
                onPointerMove: { updateSelectionFromPointer(to: index) },
                onSelect: { model.selectResult(at: index) },
                onInstall: { Task { await model.extensions.install(listing.id) } },
                onUninstall: { model.extensions.uninstall(listing.id) }
            )
        } else {
            ResultRow(
                result: result,
                isSelected: isSelected,
                isFavorite: model.isFavorite(result),
                scheme: scheme,
                onPointerMove: { updateSelectionFromPointer(to: index) },
                onRun: {
                    model.selectResult(at: index)
                    model.runSelected()
                }
            )
            .accessibilityIdentifier(resultIdentifier(for: result))
        }
    }

    private var footer: some View {
        HStack(spacing: 18) {
            if model.isShowingExtensions {
                if let listing = model.selectedExtensionListing {
                    if let title = installActionTitle(for: listing) {
                        Label(title, systemImage: "return")
                    }
                    Label("Navigate", systemImage: "arrow.up.arrow.down")
                    if listing.isInstalled {
                        Label("Uninstall ⌘⌫", systemImage: "trash")
                    }
                } else {
                    Label("Navigate", systemImage: "arrow.up.arrow.down")
                }
                Label("Back esc", systemImage: "escape")
            } else if model.isShowingClipboardHistory {
                if !model.results.isEmpty {
                    Label(returnActionTitle, systemImage: "return")
                    Label("Navigate", systemImage: "arrow.up.arrow.down")
                    Label("Delete ⌘⌫", systemImage: "trash")
                }
                Label("Back esc", systemImage: "escape")
            } else {
                Label(returnActionTitle, systemImage: "return")
                Label("Navigate", systemImage: "arrow.up.arrow.down")
                if model.commandSession == nil {
                    Label("Favorite ⌘K", systemImage: "star")
                    Text("Hold ⌥ and press ↑↓ to rearrange")
                } else {
                    Label("Back esc", systemImage: "escape")
                }
            }
            Spacer()
            Button {
                model.openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(model.isSettingsButtonSelected ? Color.beaconSelection(scheme) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("openSettingsButton")
            .accessibilityAddTraits(model.isSettingsButtonSelected ? .isSelected : [])
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Color.beaconMuted(scheme))
        .padding(.horizontal, 18)
        .frame(height: 38)
    }

    private func resultIdentifier(for result: LauncherResult) -> String {
        if case .clipboardEntry = result.target { return "clipboardEntry" }
        switch result.id {
        case LauncherModel.settingsResultID: return "openBeaconSettingsResult"
        case LauncherModel.clipboardHistoryResultID: return "clipboardHistoryResult"
        case LauncherModel.calculationResultID: return "calculationResult"
        case LauncherModel.updateResultID: return "updateResult"
        default: return "launcherResult"
        }
    }

    private var returnActionTitle: String {
        guard !model.isSettingsButtonSelected, model.results.indices.contains(model.selectedIndex) else { return "Open" }
        switch model.results[model.selectedIndex].target {
        case .copy, .clipboardEntry: return "Copy"
        case .reloadExchangeRates: return "Try Again"
        case .checkForUpdates: return "Check"
        case .update: return model.updater.canInstallUpdate ? "Update" : "Download"
        default: return "Open"
        }
    }

    private func focusSearch() async {
        try? await Task.sleep(for: .milliseconds(80))
        searchFocused = true
    }

    private func runCurrentSelection() {
        model.runSelected()
    }

    private func updateSelectionFromPointer(to index: Int) {
        let pointerLocation = NSEvent.mouseLocation
        guard pointerLocation != lastPointerLocation else { return }
        lastPointerLocation = pointerLocation
        model.selectResult(at: index)
    }

    private func installActionTitle(for listing: ExtensionManager.Listing) -> String? {
        if !listing.isInstalled { return "Install" }
        return model.extensions.isUpdateAvailable(for: listing.id) ? "Update" : nil
    }

    private var isExtensionCatalogFailed: Bool {
        if case .failed = model.extensions.catalogState { return true }
        return false
    }

    private var isLoadingResults: Bool {
        if let session = model.commandSession { return session.isLoading }
        if model.isShowingExtensions {
            return [.idle, .loading].contains(model.extensions.catalogState)
        }
        return model.isIndexing
    }

    private var emptyStateSymbol: String {
        if isLoadingResults { return "arrow.trianglehead.2.clockwise.rotate.90" }
        if model.commandSession?.errorMessage != nil { return "exclamationmark.triangle" }
        if !model.query.isEmpty { return "text.magnifyingglass" }
        if model.isShowingExtensions {
            return isExtensionCatalogFailed ? "exclamationmark.triangle" : "puzzlepiece.extension"
        }
        if model.isShowingClipboardHistory { return "doc.on.clipboard" }
        return model.commandSession == nil ? "star" : "tray"
    }

    private var emptyStateTitle: String {
        if model.isShowingExtensions {
            if isLoadingResults { return "Loading extensions" }
            if !model.query.isEmpty { return "No results for “\(model.query)”" }
            if case .failed(let message) = model.extensions.catalogState {
                return "Couldn’t load the extension catalog. \(message)"
            }
            return "No extensions are available yet"
        }
        if model.isShowingClipboardHistory {
            if !model.clipboardHistory.isEnabled { return "Clipboard history is off" }
            return model.query.isEmpty ? "Text you copy appears here" : "No results for “\(model.query)”"
        }
        if let session = model.commandSession {
            if session.isLoading { return "Loading \(session.extensionName)" }
            if let errorMessage = session.errorMessage { return errorMessage }
            return model.query.isEmpty ? "Nothing to show" : "No results for “\(model.query)”"
        }
        if model.isIndexing { return "Indexing applications" }
        return model.query.isEmpty ? "No favorites yet" : "No results for “\(model.query)”"
    }
}

private struct ResultRow: View {
    let result: LauncherResult
    let isSelected: Bool
    let isFavorite: Bool
    let scheme: ColorScheme
    let onPointerMove: () -> Void
    let onRun: () -> Void

    var body: some View {
        Button(action: onRun) {
            HStack(spacing: 13) {
                ResultIcon(icon: result.icon, symbolName: result.symbolName, tint: result.tint, scheme: scheme)

                VStack(alignment: .leading, spacing: 3) {
                    Text(result.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.beaconInk(scheme))
                        .lineLimit(1)
                    Text(result.subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.beaconMuted(scheme))
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                if result.isExtensionCommand {
                    Label("Extension", systemImage: "puzzlepiece.extension")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.beaconMuted(scheme))
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(Color.beaconKeycapBackground(scheme), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.beaconKeycapBorder(scheme)))
                }

                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.beaconMuted(scheme))
                        .accessibilityLabel("Favorite")
                }

                if isSelected {
                    Text("↵")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.beaconMuted(scheme))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Color.beaconKeycapBackground(scheme))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.beaconKeycapBorder(scheme), lineWidth: 1)
                        }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 58)
            .contentShape(Rectangle())
            .background(isSelected ? Color.beaconSelection(scheme) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onContinuousHover { phase in
            if case .active = phase {
                onPointerMove()
            }
        }
    }
}

private struct ExtensionListingRow: View {
    let listing: ExtensionManager.Listing
    let icon: NSImage?
    let symbolName: String
    let isSelected: Bool
    let isBusy: Bool
    let isUpdateAvailable: Bool
    let scheme: ColorScheme
    let onPointerMove: () -> Void
    let onSelect: () -> Void
    let onInstall: () -> Void
    let onUninstall: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            ResultIcon(icon: icon, symbolName: symbolName, tint: .blue, scheme: scheme)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(listing.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.beaconInk(scheme))
                        .lineLimit(1)
                    Text(listing.version)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.beaconMuted(scheme))
                }
                Text(listing.description)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.beaconMuted(scheme))
                    .lineLimit(1)
                    .help(listing.description)
            }

            Spacer(minLength: 12)

            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                if listing.isInstalled {
                    Label("Installed", systemImage: "checkmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.beaconMuted(scheme))
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(Color.beaconKeycapBackground(scheme), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.beaconKeycapBorder(scheme)))
                }
                if isUpdateAvailable {
                    Button("Update", action: onInstall)
                        .accessibilityIdentifier("updateExtensionButton")
                }
                if listing.isInstalled {
                    Button("Uninstall", action: onUninstall)
                        .accessibilityIdentifier("uninstallExtensionButton")
                } else {
                    Button("Install", action: onInstall)
                        .accessibilityIdentifier("installExtensionButton")
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 58)
        .contentShape(Rectangle())
        .background(isSelected ? Color.beaconSelection(scheme) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture(perform: onSelect)
        .onContinuousHover { phase in
            if case .active = phase {
                onPointerMove()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("extensionListing")
    }
}

private struct ResultIcon: View {
    let icon: NSImage?
    let symbolName: String
    let tint: BeaconTint
    let scheme: ColorScheme

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.beaconInk(scheme))
            }
        }
        .frame(width: 38, height: 38)
        .background(icon == nil ? Color.beaconTint(tint, scheme) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

extension NSColor {
    static func beaconDynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

extension Color {
    static func beaconCanvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.102, green: 0.102, blue: 0.110)
            : Color(red: 0.973, green: 0.969, blue: 0.953)
    }

    static func beaconInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.93, green: 0.93, blue: 0.95)
            : Color(red: 0.10, green: 0.10, blue: 0.095)
    }

    static func beaconMuted(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.62, green: 0.62, blue: 0.65)
            : Color(red: 0.43, green: 0.42, blue: 0.39)
    }

    static func beaconSelection(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.22, green: 0.22, blue: 0.24)
            : Color(red: 0.91, green: 0.925, blue: 0.90)
    }

    static func beaconKeycapBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.14) : Color.white.opacity(0.78)
    }

    static func beaconKeycapBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.07)
    }

    static func beaconTint(_ token: BeaconTint, _ scheme: ColorScheme) -> Color {
        switch token {
        case .blue:
            return scheme == .dark
                ? Color(red: 0.20, green: 0.24, blue: 0.28)
                : Color(red: 0.90, green: 0.93, blue: 0.96)
        case .green:
            return scheme == .dark
                ? Color(red: 0.18, green: 0.26, blue: 0.23)
                : Color(red: 0.90, green: 0.94, blue: 0.92)
        case .clay:
            return scheme == .dark
                ? Color(red: 0.27, green: 0.24, blue: 0.21)
                : Color(red: 0.94, green: 0.91, blue: 0.88)
        case .sand:
            return scheme == .dark
                ? Color(red: 0.28, green: 0.25, blue: 0.20)
                : Color(red: 0.95, green: 0.92, blue: 0.88)
        }
    }
}

#Preview {
    ContentView(model: LauncherModel.preview)
}
