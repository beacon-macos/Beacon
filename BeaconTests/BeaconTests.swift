//
//  BeaconTests.swift
//  BeaconTests
//
//  Created by Denys Yazan on 22.08.2026.
//

import Foundation
import Testing
@testable import Beacon

struct BeaconTests {

    private static let favoriteIDsKey = "launcherFavoriteIDs"

    @Test func normalizationIgnoresCaseWhitespaceAndDiacritics() {
        #expect(LauncherModel.normalized("  ČalCulator  ") == "calculator")
    }

    @Test func matchScoreRanksExactAndPrefixMatchesFirst() {
        let exact = LauncherModel.matchScore(query: "notes", candidate: "notes")
        let prefix = LauncherModel.matchScore(query: "notes", candidate: "notes application")
        let contains = LauncherModel.matchScore(query: "notes", candidate: "open notes application")

        #expect(exact != nil)
        #expect(prefix != nil)
        #expect(contains != nil)
        #expect(exact! > prefix!)
        #expect(prefix! > contains!)
    }

    @Test func fuzzyMatchAcceptsOrderedCharactersOnly() {
        #expect(LauncherModel.matchScore(query: "sset", candidate: "system settings") != nil)
        #expect(LauncherModel.matchScore(query: "zzz", candidate: "system settings") == nil)
    }

    @Test func applicationIndexDetectsNewPathsOnly() {
        let calculator = URL(filePath: "/Applications/Calculator.app")
        let notes = URL(filePath: "/Applications/Notes.app")
        let indexedPaths = Set([calculator.standardizedFileURL.path])

        #expect(!LauncherModel.containsNewApplication(in: [calculator], indexedPaths: indexedPaths))
        #expect(LauncherModel.containsNewApplication(in: [calculator, notes], indexedPaths: indexedPaths))
        #expect(!LauncherModel.containsNewApplication(in: [], indexedPaths: indexedPaths))
    }

    @Test @MainActor func doubleModifierRequiresTwoQuickPresses() {
        var detector = DoubleModifierPressDetector()

        let firstPress = detector.flagsChanged(modifierIsPressed: true, hasOtherModifiers: false, timestamp: 1.0)
        let firstRelease = detector.flagsChanged(modifierIsPressed: false, hasOtherModifiers: false, timestamp: 1.1)
        let secondPress = detector.flagsChanged(modifierIsPressed: true, hasOtherModifiers: false, timestamp: 1.3)

        #expect(!firstPress)
        #expect(!firstRelease)
        #expect(secondPress)
    }

    @Test @MainActor func doubleModifierRejectsSlowOrModifiedPresses() {
        var detector = DoubleModifierPressDetector()

        let firstPress = detector.flagsChanged(modifierIsPressed: true, hasOtherModifiers: false, timestamp: 1.0)
        let firstRelease = detector.flagsChanged(modifierIsPressed: false, hasOtherModifiers: false, timestamp: 1.1)
        let slowPress = detector.flagsChanged(modifierIsPressed: true, hasOtherModifiers: false, timestamp: 1.5)
        let slowRelease = detector.flagsChanged(modifierIsPressed: false, hasOtherModifiers: false, timestamp: 1.6)
        let modifiedPress = detector.flagsChanged(modifierIsPressed: true, hasOtherModifiers: true, timestamp: 1.7)

        #expect(!firstPress)
        #expect(!firstRelease)
        #expect(!slowPress)
        #expect(!slowRelease)
        #expect(!modifiedPress)
    }

    @Test @MainActor func doubleModifierShortcutPersists() {
        let suiteName = "BeaconTests.doubleModifierShortcutPersists"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = LauncherModel(defaults: defaults)
        model.updateShortcut(KeyboardShortcut.doubleTap(.command))
        let restoredModel = LauncherModel(defaults: defaults)

        #expect(restoredModel.shortcut == KeyboardShortcut.doubleTap(.command))
        #expect(restoredModel.shortcut.keyCapComponents == ["⌘", "⌘"])
    }

    @Test @MainActor func removingDefaultFavoritePersistsAnEmptySelection() {
        let suiteName = "BeaconTests.removingDefaultFavoritePersistsAnEmptySelection"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = LauncherModel(defaults: defaults)
        #expect(model.toggleFavoriteForSelection())
        #expect(model.results.isEmpty)

        let restoredModel = LauncherModel(defaults: defaults)
        #expect(restoredModel.results.isEmpty)
        #expect(restoredModel.favoriteIDs.isEmpty)
    }

    @Test @MainActor func favoriteOrderAndDeduplicationArePreserved() {
        let suiteName = "BeaconTests.favoriteOrderAndDeduplicationArePreserved"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            ["command:applications", LauncherModel.settingsResultID, "command:applications", "missing"],
            forKey: Self.favoriteIDsKey
        )

        let model = LauncherModel(defaults: defaults)

        #expect(model.favoriteIDs == ["command:applications", LauncherModel.settingsResultID, "missing"])
        #expect(model.results.map(\.id) == ["command:applications", LauncherModel.settingsResultID])
    }

    @Test @MainActor func selectedFavoriteCanBeReorderedAndRestored() {
        let suiteName = "BeaconTests.selectedFavoriteCanBeReorderedAndRestored"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            [LauncherModel.settingsResultID, "missing", "command:applications"],
            forKey: Self.favoriteIDsKey
        )

        let model = LauncherModel(defaults: defaults)
        model.moveFavoriteForSelection(by: 1)

        #expect(model.favoriteIDs == ["command:applications", "missing", LauncherModel.settingsResultID])
        #expect(model.results.map(\.id) == ["command:applications", LauncherModel.settingsResultID])
        #expect(model.selectedIndex == 1)
        #expect(model.results[model.selectedIndex].id == LauncherModel.settingsResultID)

        let restoredModel = LauncherModel(defaults: defaults)
        #expect(restoredModel.favoriteIDs == model.favoriteIDs)
        #expect(restoredModel.results.map(\.id) == model.results.map(\.id))
    }

    @Test @MainActor func favoriteReorderingOnlyAppliesToTheDefaultFavoritesList() {
        let suiteName = "BeaconTests.favoriteReorderingOnlyAppliesToTheDefaultFavoritesList"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            [LauncherModel.settingsResultID, "command:applications"],
            forKey: Self.favoriteIDsKey
        )

        let model = LauncherModel(defaults: defaults)
        model.moveFavoriteForSelection(by: -1)
        #expect(model.favoriteIDs == [LauncherModel.settingsResultID, "command:applications"])

        model.query = "settings"
        #expect(!model.canReorderFavoriteForSelection)
        model.moveFavoriteForSelection(by: 1)
        #expect(model.favoriteIDs == [LauncherModel.settingsResultID, "command:applications"])
    }

    @Test @MainActor func searchedResultCanBeFavoritedAndRestored() {
        let suiteName = "BeaconTests.searchedResultCanBeFavoritedAndRestored"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = LauncherModel(defaults: defaults)
        model.query = "applications"
        #expect(model.results.first?.id == "command:applications")
        #expect(model.toggleFavoriteForSelection())
        model.query = ""

        #expect(model.results.map(\.id) == [LauncherModel.settingsResultID, "command:applications"])

        let restoredModel = LauncherModel(defaults: defaults)
        #expect(restoredModel.results.map(\.id) == [LauncherModel.settingsResultID, "command:applications"])
    }

    @Test @MainActor func webSearchCannotBeFavorited() {
        let suiteName = "BeaconTests.webSearchCannotBeFavorited"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set([], forKey: Self.favoriteIDsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = LauncherModel(defaults: defaults)
        model.query = "a query with no matching command"

        #expect(model.results.map(\.id) == ["command:web-search"])
        #expect(!model.toggleFavoriteForSelection())
        #expect(model.favoriteIDs.isEmpty)
    }

    @Test @MainActor func selectionIncludesSettingsButtonAndResetsForNewQueries() {
        let model = LauncherModel(defaults: isolatedDefaults(named: #function))
        model.query = "applications"

        model.moveSelection(by: 100)
        #expect(model.isSettingsButtonSelected)
        #expect(model.selectedIndex == model.results.count - 1)

        model.moveSelection(by: -1)
        #expect(!model.isSettingsButtonSelected)
        #expect(model.selectedIndex == model.results.count - 1)

        model.moveSelection(by: -100)
        #expect(model.selectedIndex == 0)

        model.moveSelection(by: 1)
        #expect(model.selectedIndex == 1)

        model.query = "settings"
        #expect(!model.isSettingsButtonSelected)
        #expect(model.selectedIndex == 0)
        #expect(model.results.first?.id == LauncherModel.settingsResultID)
    }

    @Test @MainActor func rewritingTheSameQueryKeepsTheSelection() {
        let model = LauncherModel(defaults: isolatedDefaults(named: #function))
        model.query = "a"
        #expect(model.results.count > 1)

        model.moveSelection(by: 1)
        model.query = "a"
        #expect(model.selectedIndex == 1)

        model.query = "ap"
        #expect(model.selectedIndex == 0)
    }

    @Test @MainActor func runningSelectedSettingsButtonDismissesLauncherAndOpensSettings() {
        let model = LauncherModel(defaults: isolatedDefaults(named: #function))
        var dismissalCount = 0
        var settingsOpenCount = 0
        model.onDismiss = { dismissalCount += 1 }
        model.onOpenSettings = { settingsOpenCount += 1 }

        model.moveSelection(by: 1)
        #expect(model.isSettingsButtonSelected)
        #expect(!model.toggleFavoriteForSelection())

        model.runSelected()

        #expect(dismissalCount == 1)
        #expect(settingsOpenCount == 1)
    }

    @Test @MainActor func runningSettingsDismissesLauncherAndOpensSettings() {
        let model = LauncherModel(defaults: isolatedDefaults(named: #function))
        var dismissalCount = 0
        var settingsOpenCount = 0
        model.onDismiss = { dismissalCount += 1 }
        model.onOpenSettings = { settingsOpenCount += 1 }

        model.runSelected()

        #expect(dismissalCount == 1)
        #expect(settingsOpenCount == 1)
    }

    @MainActor
    private func isolatedDefaults(named name: String) -> UserDefaults {
        let suiteName = "BeaconTests.\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
