import Foundation

nonisolated struct CurrencyConversion: Equatable, Sendable {
    let amount: Double
    let source: String
    let target: String

    /// Reads `[currency] amount [currency] [word] [currency] [word]`. The words around the target can be
    /// anything, such as `in`, `в`, or `en`, which is what makes any language work.
    static func parse(
        _ query: String,
        names: CurrencyNames,
        localCurrency: String?,
        locale: Locale = .current
    ) -> CurrencyConversion? {
        let text = CurrencyNames.normalized(query)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "=?")))
        guard let amountStart = text.firstIndex(where: { Calculator.isDecimalDigit($0) || $0 == "(" }) else {
            return nil
        }
        let amountEnd = text[amountStart...].firstIndex { !isAmountCharacter($0) } ?? text.endIndex
        guard let amount = Calculator.evaluate(
            String(text[amountStart..<amountEnd]),
            locale: locale,
            requiresOperator: false
        ) else { return nil }

        let prefix = text[..<amountStart].trimmingCharacters(in: .whitespaces)
        let words = text[amountEnd...].split(whereSeparator: \.isWhitespace).map(String.init)
        let parser = Parser(names: names, localCurrency: localCurrency)

        if !prefix.isEmpty {
            // Only symbols lead the amount, so searches such as `top 10` don't read the code TOP.
            guard prefix.contains(where: { !$0.isLetter }),
                  let source = names.currency(named: prefix, preferring: localCurrency),
                  let target = parser.target(in: words[...], source: source) else { return nil }
            return CurrencyConversion(amount: amount, source: source, target: target)
        }
        guard !words.isEmpty else { return nil }
        for sourceLength in 1...min(3, words.count) {
            guard let source = names.currency(named: words[..<sourceLength].joined(separator: " "), preferring: localCurrency),
                  let target = parser.target(in: words[sourceLength...], source: source) else { continue }
            return CurrencyConversion(amount: amount, source: source, target: target)
        }
        if words.count == 1, let (source, target) = parser.unsegmentedCurrencies(in: Array(words[0])) {
            return CurrencyConversion(amount: amount, source: source, target: target)
        }
        return nil
    }

    static func format(_ amount: Double, locale: Locale = .current, usesGrouping: Bool = true) -> String {
        let grouping: NumberFormatStyleConfiguration.Grouping = usesGrouping ? .automatic : .never
        if amount != 0, abs(amount) < 1 {
            return amount.formatted(.number.precision(.significantDigits(1...4)).grouping(grouping).locale(locale))
        }
        return amount.formatted(.number.precision(.fractionLength(2)).grouping(grouping).locale(locale))
    }

    private static func isAmountCharacter(_ character: Character) -> Bool {
        Calculator.isDecimalDigit(character) || character.isWhitespace || ".,+-−*×·/÷^%()'’_".contains(character)
    }

    private struct Parser {
        let names: CurrencyNames
        let localCurrency: String?

        func target(in words: ArraySlice<String>, source: String) -> String? {
            guard !words.isEmpty else {
                return localCurrency == source ? nil : localCurrency
            }
            var candidates = [words]
            if words.count >= 2 {
                candidates.append(words.dropFirst())
                candidates.append(words.dropLast())
            }
            if words.count >= 3 {
                candidates.append(words.dropFirst().dropLast())
            }
            let phrases = candidates.filter { $0.count <= 3 }.map { $0.joined(separator: " ") }
            return phrases.lazy.compactMap { names.currency(exactlyNamed: $0, preferring: localCurrency) }.first
                ?? phrases.lazy.compactMap { names.currency(named: $0, preferring: localCurrency) }.first
        }

        /// Handles languages written without spaces, such as `美元换人民币`.
        func unsegmentedCurrencies(in characters: [Character]) -> (source: String, target: String)? {
            for sourceEnd in stride(from: characters.count, through: 1, by: -1) {
                guard let source = names.currency(exactlyNamed: String(characters[..<sourceEnd]), preferring: localCurrency) else {
                    continue
                }
                let rest = characters[sourceEnd...]
                if rest.isEmpty {
                    guard let localCurrency, localCurrency != source else { return nil }
                    return (source, localCurrency)
                }
                for targetStart in rest.indices.prefix(3) {
                    if let target = names.currency(exactlyNamed: String(rest[targetStart...]), preferring: localCurrency) {
                        return (source, target)
                    }
                }
            }
            return nil
        }
    }
}

nonisolated struct CurrencyNames: Sendable {
    static let shared = CurrencyNames(preferredLanguages: Locale.preferredLanguages)

    private static let additionalCodes = ["BTC", "ETH"]

    private static let colloquialNames = [
        "buck": "USD", "bucks": "USD", "бакс": "USD", "ドル": "USD", "달러": "USD",
        "quid": "GBP", "грн": "UAH", "lei": "RON", "reais": "BRL", "円": "JPY", "元": "CNY", "块": "CNY", "원": "KRW",
        "bitcoin": "BTC", "₿": "BTC", "ethereum": "ETH", "ether": "ETH"
    ]

    private static let mostTradedCurrencies = [
        "USD", "EUR", "GBP", "JPY", "CNY", "CHF", "CAD", "AUD", "NZD", "HKD", "SGD", "SEK", "NOK", "DKK",
        "KRW", "INR", "RUB", "UAH", "PLN", "CZK", "HUF", "RON", "BGN", "ISK", "TRY", "ILS", "AED", "SAR",
        "BRL", "MXN", "ARS", "CLP", "COP", "PEN", "ZAR", "EGP", "NGN", "KZT", "BYN", "TWD", "THB", "IDR",
        "MYR", "PHP", "VND", "PKR", "KWD", "BHD", "JOD", "QAR", "BTC", "ETH"
    ]

    private static let foldedLetters: [Character: String] = [
        "ł": "l", "ø": "o", "đ": "d", "ß": "ss", "æ": "ae", "œ": "oe", "ı": "i"
    ]

    private typealias Weights = [String: Int]

    /// Counts how many languages use a name for each currency.
    private var phrases: [String: Weights] = [:]
    private var words: [String: Weights] = [:]
    private var wordsByStem: [String: [String]] = [:]

    /// Loads plural forms only for the preferred languages, because loading them for every language takes seconds.
    init(preferredLanguages: [String]) {
        let codes = Locale.commonISOCurrencyCodes
        let languages = Set(Locale.availableIdentifiers.compactMap {
            Locale(identifier: $0).language.languageCode?.identifier
        })
        for language in languages {
            let locale = Locale(identifier: language)
            for code in codes {
                if let name = locale.localizedString(forCurrencyCode: code) {
                    add(name: name, for: code)
                }
            }
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        for language in Set(preferredLanguages + ["en"]) {
            let locale = Locale(identifier: language)
            formatter.locale = locale
            for code in codes {
                for count in [1, 2, 5] {
                    let name = Decimal(count).formatted(
                        .currency(code: code).presentation(.fullName).precision(.fractionLength(0)).locale(locale)
                    )
                    add(name: name.filter { !$0.isNumber }, for: code)
                }
                formatter.currencyCode = code
                add(symbol: formatter.currencySymbol, for: code)
            }
        }
        for identifier in Locale.availableIdentifiers {
            let locale = Locale(identifier: identifier)
            if let code = locale.currency?.identifier, let symbol = locale.currencySymbol {
                add(symbol: symbol, for: code)
            }
        }

        for code in codes + Self.additionalCodes {
            phrases[Self.normalized(code), default: [:]][code] = 1
        }
        for (name, code) in Self.colloquialNames {
            add(name: name, for: code)
        }
        wordsByStem = Dictionary(grouping: words.keys.filter { $0.unicodeScalars.count >= 4 }, by: Self.stem)
    }

    func currency(named name: String, preferring preferredCurrency: String?) -> String? {
        let phrase = Self.normalized(name).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let weights = phrases[phrase] {
            return Self.resolve(weights, preferring: preferredCurrency)
        }
        let queryWords = Self.words(in: phrase)
        guard let firstWord = queryWords.first,
              queryWords.allSatisfy({ $0.unicodeScalars.count >= 3 }) else { return nil }

        var candidates = weights(matching: firstWord)
        for word in queryWords.dropFirst() where !candidates.isEmpty {
            let wordWeights = weights(matching: word)
            candidates = candidates.reduce(into: [:]) { result, candidate in
                if let weight = wordWeights[candidate.key] {
                    result[candidate.key] = candidate.value + weight
                }
            }
        }
        return Self.resolve(candidates, preferring: preferredCurrency)
    }

    func currency(exactlyNamed name: String, preferring preferredCurrency: String?) -> String? {
        phrases[Self.normalized(name)].flatMap { Self.resolve($0, preferring: preferredCurrency) }
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .reduce(into: "") { result, character in
                if let replacement = foldedLetters[character] {
                    result += replacement
                } else {
                    result.append(character)
                }
            }
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func mightContainConversion(_ query: String) -> Bool {
        query.contains(where: Calculator.isDecimalDigit)
            && query.contains { $0.isLetter || $0.isCurrencySymbol }
    }

    private mutating func add(name: String, for code: String) {
        let phrase = Self.normalized(name)
        guard !phrase.isEmpty else { return }
        phrases[phrase, default: [:]][code, default: 0] += 1
        for word in Set(Self.words(in: phrase)) {
            words[word, default: [:]][code, default: 0] += 1
        }
    }

    /// Skips single letters, such as `K` or `R`, which would turn searches like `4k` into conversions.
    private mutating func add(symbol: String, for code: String) {
        let symbol = Self.normalized(symbol).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !symbol.isEmpty, symbol.count > 1 || !symbol.contains(where: \.isLetter) else { return }
        if phrases[symbol]?[code] == nil {
            phrases[symbol, default: [:]][code] = 1
        }
    }

    /// Matches inflected forms, such as `долларах` or `złotych`, by a shared prefix of at least four letters;
    /// three letters already match `hours` to the Māori `hou` in the name of the shekel.
    private func weights(matching word: String) -> Weights {
        if let weights = words[word] {
            return weights
        }
        let scalars = Array(word.unicodeScalars)
        guard scalars.count >= 4 else { return [:] }

        var longestSharedPrefix = 0
        var weights: Weights = [:]
        for candidate in wordsByStem[Self.stem(word)] ?? [] {
            let candidateScalars = Array(candidate.unicodeScalars)
            let sharedPrefix = zip(scalars, candidateScalars).prefix { $0 == $1 }.count
            guard sharedPrefix >= 4,
                  scalars.count - sharedPrefix <= 3,
                  candidateScalars.count - sharedPrefix <= 2,
                  sharedPrefix >= longestSharedPrefix else { continue }
            if sharedPrefix > longestSharedPrefix {
                longestSharedPrefix = sharedPrefix
                weights = [:]
            }
            weights.merge(words[candidate] ?? [:], uniquingKeysWith: +)
        }
        return weights
    }

    /// Drops currencies that few languages call by the name, such as the pound, which Romanian calls `liră`,
    /// before preferring the local and then the most traded currency.
    private static func resolve(_ weights: Weights, preferring preferredCurrency: String?) -> String? {
        guard let maximumWeight = weights.values.max() else { return nil }
        let codes = Set(weights.filter { $0.value * 2 >= maximumWeight }.keys)
        if codes.count == 1 {
            return codes.first
        }
        if let preferredCurrency, codes.contains(preferredCurrency) {
            return preferredCurrency
        }
        return mostTradedCurrencies.first(where: codes.contains)
    }

    private static func words(in phrase: String) -> [String] {
        phrase.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func stem(_ word: String) -> String {
        String(String.UnicodeScalarView(word.unicodeScalars.prefix(4)))
    }
}
