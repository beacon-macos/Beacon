//
//  BeaconUITests.swift
//  BeaconUITests
//
//  Created by Denys Yazan on 22.08.2026.
//

import AppKit
import XCTest

final class BeaconUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSettingsCanBeSearchedAndUnfavorited() throws {
        let app = application(favoriteIDs: ["command:settings"])
        app.launch()

        let settingsResult = app.buttons["openBeaconSettingsResult"]
        XCTAssertTrue(settingsResult.waitForExistence(timeout: 2))

        let searchField = app.textFields["launcherSearchField"]
        searchField.click()
        searchField.typeText("settings")
        XCTAssertTrue(settingsResult.waitForExistence(timeout: 2))

        searchField.typeKey("k", modifierFlags: .command)
        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeKey(.delete, modifierFlags: [])

        XCTAssertTrue(app.staticTexts["No favorites yet"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testSearchKeepsFirstResultSelectedUnderStationaryPointer() throws {
        let app = application(favoriteIDs: ["command:settings", "command:applications"])
        app.launch()

        let searchField = app.textFields["launcherSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        searchField.click()

        let applicationsResult = app.buttons.matching(identifier: "launcherResult").firstMatch
        XCTAssertTrue(applicationsResult.waitForExistence(timeout: 2))
        applicationsResult
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .hover()
        XCTAssertTrue(applicationsResult.isSelected)

        searchField.typeText("settings")

        let settingsResult = app.buttons["openBeaconSettingsResult"]
        XCTAssertTrue(settingsResult.waitForExistence(timeout: 2))
        XCTAssertTrue(settingsResult.isSelected)
    }

    @MainActor
    func testDownArrowSelectsAndOpensFooterSettings() throws {
        let app = application(favoriteIDs: ["command:settings"])
        app.launch()

        let searchField = app.textFields["launcherSearchField"]
        let settingsButton = app.buttons["openSettingsButton"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 2))

        searchField.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(settingsButton.isSelected)
        searchField.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(app.otherElements["settingsView"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testReturnOpensSelectedFavorite() throws {
        let app = application(favoriteIDs: ["command:settings"])
        app.launch()

        let searchField = app.textFields["launcherSearchField"]
        let settingsResult = app.buttons["openBeaconSettingsResult"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        XCTAssertTrue(settingsResult.waitForExistence(timeout: 2))
        XCTAssertTrue(settingsResult.isSelected)

        searchField.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(app.otherElements["settingsView"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testOptionDownArrowReordersSelectedFavorite() throws {
        let app = application(favoriteIDs: ["command:settings", "command:applications"])
        app.launch()

        let searchField = app.textFields["launcherSearchField"]
        let settingsResult = app.buttons["openBeaconSettingsResult"]
        let applicationsResult = app.buttons.matching(identifier: "launcherResult").firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        XCTAssertTrue(settingsResult.waitForExistence(timeout: 2))
        XCTAssertTrue(applicationsResult.waitForExistence(timeout: 2))
        XCTAssertTrue(settingsResult.isSelected)

        searchField.typeKey(.downArrow, modifierFlags: .option)

        XCTAssertTrue(settingsResult.isSelected)
        XCTAssertLessThan(applicationsResult.frame.minY, settingsResult.frame.minY)
    }

    @MainActor
    func testReturnRunsTheResultSelectedWithArrowKeys() throws {
        let app = application(favoriteIDs: [], extensionsDirectory: try fixtureExtensionsDirectory())
        app.launch()

        let searchField = app.textFields["launcherSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        searchField.click()
        searchField.typeText("zebra fixture")
        XCTAssertTrue(app.buttons.matching(identifier: "launcherResult").element(boundBy: 1).waitForExistence(timeout: 2))

        searchField.typeKey(.downArrow, modifierFlags: [])
        searchField.typeKey(.return, modifierFlags: [])

        let chip = app.buttons["extensionCommandChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 2))
        XCTAssertTrue(chip.label.hasPrefix("Zebra Fixture Beta"))
        let betaItem = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Beta item"))
            .firstMatch
        XCTAssertTrue(betaItem.waitForExistence(timeout: 2))

        searchField.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(chip.waitForNonExistence(timeout: 2))
        XCTAssertTrue(searchField.exists)
    }

    @MainActor
    func testReturnCopiesTheCalculationResult() throws {
        let app = application(favoriteIDs: [])
        app.launch()

        let searchField = app.textFields["launcherSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        searchField.click()
        searchField.typeText("2+2")

        let calculation = app.buttons["calculationResult"]
        XCTAssertTrue(calculation.waitForExistence(timeout: 2))
        XCTAssertTrue(calculation.label.contains("2+2 = 4"))
        XCTAssertTrue(calculation.isSelected)

        NSPasteboard.general.clearContents()
        searchField.typeKey(.return, modifierFlags: [])

        let copied = expectation(for: NSPredicate { _, _ in
            NSPasteboard.general.string(forType: .string) == "4"
        }, evaluatedWith: nil)
        wait(for: [copied], timeout: 2)
    }

    @MainActor
    func testClipboardHistoryCopiesAnEarlierItem() throws {
        let app = application(favoriteIDs: [])
        app.launch()

        let searchField = app.textFields["launcherSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        searchField.click()
        searchField.typeText("clipboard history")
        let clipboardHistoryResult = app.buttons["clipboardHistoryResult"]
        XCTAssertTrue(clipboardHistoryResult.waitForExistence(timeout: 2))
        searchField.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["clipboardHistoryChip"].waitForExistence(timeout: 2))

        for text in ["Beacon UI test first", "Beacon UI test second"] {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let entry = app.buttons.matching(identifier: "clipboardEntry")
                .matching(NSPredicate(format: "label CONTAINS %@", text))
                .firstMatch
            XCTAssertTrue(entry.waitForExistence(timeout: 3))
        }

        searchField.typeKey(.downArrow, modifierFlags: [])
        searchField.typeKey(.return, modifierFlags: [])

        let copied = expectation(for: NSPredicate { _, _ in
            NSPasteboard.general.string(forType: .string) == "Beacon UI test first"
        }, evaluatedWith: nil)
        wait(for: [copied], timeout: 2)
    }

    @MainActor
    func testSettingsOpensTheExtensionsPage() throws {
        let app = application(favoriteIDs: ["command:settings"], extensionsDirectory: try fixtureExtensionsDirectory())
        app.launch()

        let searchField = app.textFields["launcherSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        searchField.typeKey(.return, modifierFlags: [])

        let manageExtensionsButton = app.buttons["manageExtensionsButton"]
        XCTAssertTrue(manageExtensionsButton.waitForExistence(timeout: 2))
        manageExtensionsButton.click()

        let chip = app.buttons["extensionsPageChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 2))
        let fixtureListing = app.descendants(matching: .any)
            .matching(identifier: "extensionListing")
            .containing(NSPredicate(format: "label == %@", "Fixture"))
            .firstMatch
        XCTAssertTrue(fixtureListing.waitForExistence(timeout: 10))
        XCTAssertTrue(fixtureListing.buttons["uninstallExtensionButton"].exists)

        searchField.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(chip.waitForNonExistence(timeout: 2))
        XCTAssertTrue(searchField.exists)
    }

    private func application(favoriteIDs: [String], extensionsDirectory: URL? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BEACON_UI_TESTING"] = "1"
        app.launchEnvironment["BEACON_UI_TEST_FAVORITE_IDS"] = favoriteIDs.joined(separator: "\n")
        if let extensionsDirectory {
            app.launchEnvironment["BEACON_UI_TEST_EXTENSIONS_DIRECTORY"] = extensionsDirectory.path
        }
        return app
    }

    /// Installs an extension with two commands whose items never open anything.
    private func fixtureExtensionsDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BeaconUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extensionDirectory = directory.appending(path: "fixture", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: extensionDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let manifest = """
            {
              "id": "fixture", "name": "Fixture", "description": "UI test fixture", "version": "1.0.0",
              "main": "main.js",
              "commands": [
                { "id": "alpha", "title": "Zebra Fixture Alpha" },
                { "id": "beta", "title": "Zebra Fixture Beta" }
              ]
            }
            """
        let script = """
            for (const name of ["alpha", "beta"]) {
              const title = name[0].toUpperCase() + name.slice(1) + " item";
              beacon.registerCommand(name, () => [{ title, action: { type: "open", target: "beacon-ui-test://" + name } }]);
            }
            """
        try manifest.write(to: extensionDirectory.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try script.write(to: extensionDirectory.appending(path: "main.js"), atomically: true, encoding: .utf8)
        return directory
    }
}
