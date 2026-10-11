import Foundation
import Testing
@testable import Beacon

struct CalculatorTests {

    private static let names = CurrencyNames(preferredLanguages: ["en"])
    private static let english = Locale(identifier: "en_US")
    private static let rates = """
        { "date": "2026-10-11", "usd": { "usd": 1, "uah": 40, "eur": 0.8, "unpublished": null } }
        """

    @Test func arithmeticFollowsOperatorPrecedence() {
        let cases: [(String, Double)] = [
            ("2+2", 4),
            ("2 + 3 * 4", 14),
            ("(2 + 3) * 4", 20),
            ("10/4", 2.5),
            ("2 × 3 ÷ 4", 1.5),
            ("2x3", 6),
            ("2^3^2", 512),
            ("2**10", 1024),
            ("-2^2", -4),
            ("2 - -3", 5),
            ("5!", 120),
            ("sqrt(16) + 1", 5),
            ("√16", 4),
            ("(1 + 2", 3)
        ]
        for (expression, value) in cases {
            #expect(Calculator.evaluate(expression, locale: Self.english) == value, "\(expression)")
        }
        #expect(abs(Calculator.evaluate("pi * 2", locale: Self.english)! - 2 * .pi) < 1e-12)
    }

    @Test func percentagesAdjustTheLeftOperandLikeAPocketCalculator() {
        #expect(Calculator.evaluate("200 + 15%", locale: Self.english) == 230)
        #expect(Calculator.evaluate("200 - 10%", locale: Self.english) == 180)
        #expect(Calculator.evaluate("200 * 15%", locale: Self.english) == 30)
        #expect(Calculator.evaluate("50%", locale: Self.english) == 0.5)
    }

    @Test func plainNumbersAndTextAreNotCalculations() {
        for query in ["2026", "-5", "e", "1password", "safari", "2 +", "2 2", "1/0", "sqrt(-1)", "2 xbox"] {
            #expect(Calculator.evaluate(query, locale: Self.english) == nil, "\(query)")
        }
        #expect(Calculator.evaluate("2026", locale: Self.english, requiresOperator: false) == 2026)
    }

    @Test func separatorsFollowTheLocale() {
        #expect(Calculator.evaluate("1,000 + 0.5", locale: Self.english) == 1000.5)
        #expect(Calculator.evaluate("2,5 + 1", locale: Self.english) == 3.5)
        #expect(Calculator.evaluate("1 000 + 1", locale: Self.english) == 1001)

        let german = Locale(identifier: "de_DE")
        #expect(Calculator.evaluate("1.000,5 + 1", locale: german) == 1001.5)
        #expect(Calculator.evaluate("1.5 + 1", locale: german) == 2.5)

        let ukrainian = Locale(identifier: "uk_UA")
        #expect(Calculator.evaluate("2,5 + 1,5", locale: ukrainian) == 4)
        #expect(Calculator.evaluate("1,500 + 1", locale: ukrainian) == 2.5)
        #expect(Calculator.evaluate("٣ + ٤", locale: Self.english) == 7)
    }

    @Test func resultsAreFormattedForTheLocale() {
        #expect(Calculator.format(0.1 + 0.2, locale: Self.english) == "0.3")
        #expect(Calculator.format(1_234_567.5, locale: Self.english) == "1,234,567.5")
        #expect(Calculator.format(1_234_567.5, locale: Self.english, usesGrouping: false) == "1234567.5")
        #expect(Calculator.format(2.5, locale: Locale(identifier: "uk_UA")) == "2,5")
        #expect(Calculator.format(1e20, locale: Self.english) == "1E20")

        #expect(CurrencyConversion.format(89.7712, locale: Self.english) == "89.77")
        #expect(CurrencyConversion.format(1234.5, locale: Self.english) == "1,234.50")
        #expect(CurrencyConversion.format(1234.5, locale: Self.english, usesGrouping: false) == "1234.50")
        #expect(CurrencyConversion.format(0.0000241234, locale: Self.english) == "0.00002412")
    }

    @Test func conversionsAreRecognizedInAnyLanguage() {
        let cases: [(String, Double, String, String)] = [
            ("2$ in uah", 2, "USD", "UAH"),
            ("$2 to UAH", 2, "USD", "UAH"),
            ("2 usd uah", 2, "USD", "UAH"),
            ("20 us dollars in canadian dollars", 20, "USD", "CAD"),
            ("2 доллара в гривнах", 2, "USD", "UAH"),
            ("100 евро в рублях", 100, "EUR", "RUB"),
            ("50 гривень у доларах", 50, "UAH", "USD"),
            ("1 000 грн в евро", 1000, "UAH", "EUR"),
            ("100 € en dólares", 100, "EUR", "USD"),
            ("100 zlotych na euro", 100, "PLN", "EUR"),
            ("100美元换人民币", 100, "USD", "CNY"),
            ("100usd→eur", 100, "USD", "EUR"),
            ("(2 + 3) usd in eur", 5, "USD", "EUR"),
            ("3 bucks in yen", 3, "USD", "JPY"),
            ("100 lira in usd", 100, "TRY", "USD")
        ]
        for (query, amount, source, target) in cases {
            let conversion = CurrencyConversion.parse(query, names: Self.names, localCurrency: "CZK", locale: Self.english)
            #expect(conversion == CurrencyConversion(amount: amount, source: source, target: target), "\(query)")
        }
    }

    @Test func sharedNamesPreferTheLocalCurrency() {
        let swedish = CurrencyConversion.parse("100 kr in usd", names: Self.names, localCurrency: "CZK", locale: Self.english)
        let norwegian = CurrencyConversion.parse("100 kr in usd", names: Self.names, localCurrency: "NOK", locale: Self.english)
        let czech = CurrencyConversion.parse("100 usd в кронах", names: Self.names, localCurrency: "CZK", locale: Self.english)

        #expect(swedish?.source == "SEK")
        #expect(norwegian?.source == "NOK")
        #expect(czech?.target == "CZK")
    }

    @Test func conversionWithoutTargetUsesTheLocalCurrency() {
        let conversion = CurrencyConversion.parse("100 eur", names: Self.names, localCurrency: "CZK", locale: Self.english)

        #expect(conversion == CurrencyConversion(amount: 100, source: "EUR", target: "CZK"))
        #expect(CurrencyConversion.parse("100 czk", names: Self.names, localCurrency: "CZK", locale: Self.english) == nil)
        #expect(CurrencyConversion.parse("100 eur", names: Self.names, localCurrency: nil, locale: Self.english) == nil)
    }

    @Test func searchesThatMentionNumbersAreNotConversions() {
        let searches = [
            "Euro Truck Simulator 2", "1password", "4k", "3d", "2 euro truck", "Windows 11", "top 10", "24 hours"
        ]
        for query in searches {
            #expect(
                CurrencyConversion.parse(query, names: Self.names, localCurrency: "CZK", locale: Self.english) == nil,
                "\(query)"
            )
        }
    }

    @Test @MainActor func calculationIsTheFirstResultAndCopiesItsValue() {
        let model = LauncherModel(defaults: isolatedDefaults(named: #function), locale: Self.english)

        model.query = "2+2"
        #expect(model.results.first?.id == LauncherModel.calculationResultID)
        #expect(model.results.first?.title == "2+2 = 4")
        #expect(model.results.first?.target == .copy("4"))
        #expect(model.selectedIndex == 0)
        #expect(!model.toggleFavoriteForSelection())

        model.query = "1000 * 1.5="
        #expect(model.results.first?.title == "1000 * 1.5 = 1,500")
        #expect(model.results.first?.target == .copy("1500"))

        model.query = "2026"
        #expect(model.results.first?.id != LauncherModel.calculationResultID)
    }

    @Test @MainActor func conversionUsesDownloadedRatesAndSavesThem() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedURL = directory.appending(path: "usd.json")
        let cacheURL = directory.appending(path: "cache/ExchangeRates.json")
        try Self.rates.write(to: feedURL, atomically: true, encoding: .utf8)

        let exchangeRates = ExchangeRates(sourceURLs: [directory.appending(path: "missing.json"), feedURL], cacheURL: cacheURL)
        let model = LauncherModel(
            defaults: isolatedDefaults(named: #function),
            exchangeRates: exchangeRates,
            locale: Self.english
        )

        model.query = "2$ in uah"
        try await waitUntil { model.results.first?.title == "2 USD = 80.00 UAH" }
        #expect(model.results.first?.subtitle == "US Dollar → Ukrainian Hryvnia · Rates from Oct 11, 2026")
        #expect(model.results.first?.target == .copy("80.00"))
        #expect(abs(try #require(exchangeRates.rate(from: "UAH", to: "EUR")) - 0.02) < 1e-12)
        #expect(exchangeRates.snapshot?.rates["UNPUBLISHED"] == nil)

        try await waitUntil { FileManager.default.fileExists(atPath: cacheURL.path) }
        let offlineRates = ExchangeRates(sourceURLs: [directory.appending(path: "missing.json")], cacheURL: cacheURL)
        let offlineModel = LauncherModel(
            defaults: isolatedDefaults(named: #function + ".offline"),
            exchangeRates: offlineRates,
            locale: Self.english
        )
        offlineModel.query = "10 eur to usd"
        try await waitUntil { offlineModel.results.first?.title == "10 EUR = 12.50 USD" }
    }

    @Test @MainActor func failedRatesDownloadCanBeRetried() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedURL = directory.appending(path: "usd.json")
        let exchangeRates = ExchangeRates(sourceURLs: [feedURL], cacheURL: directory.appending(path: "cache.json"))
        let model = LauncherModel(
            defaults: isolatedDefaults(named: #function),
            exchangeRates: exchangeRates,
            locale: Self.english
        )

        model.query = "2 usd in uah"
        try await waitUntil { model.results.first?.subtitle.hasPrefix("Couldn’t load exchange rates") == true }
        #expect(model.results.first?.title == "2 USD → UAH")
        #expect(model.results.first?.target == .reloadExchangeRates)

        try Self.rates.write(to: feedURL, atomically: true, encoding: .utf8)
        model.runSelected()
        try await waitUntil { model.results.first?.title == "2 USD = 80.00 UAH" }
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
            .appending(path: "BeaconCalculatorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private func isolatedDefaults(named name: String) -> UserDefaults {
        let suiteName = "CalculatorTests.\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
