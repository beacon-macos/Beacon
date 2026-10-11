import Foundation

nonisolated enum Calculator {
    /// `requiresOperator` keeps a bare number such as `2026` from showing a calculation while searching for apps.
    static func evaluate(_ expression: String, locale: Locale = .current, requiresOperator: Bool = true) -> Double? {
        var parser = Parser(expression, locale: locale)
        guard let value = parser.parse(), value.isFinite, parser.usesOperator || !requiresOperator else { return nil }
        return value == 0 ? 0 : value
    }

    static func format(_ value: Double, locale: Locale = .current, usesGrouping: Bool = true) -> String {
        let magnitude = abs(value)
        if magnitude >= 1e15 || (magnitude > 0 && magnitude < 1e-10) {
            return value.formatted(.number.notation(.scientific).precision(.significantDigits(1...10)).locale(locale))
        }
        // Rounds away binary noise, such as 0.1 + 0.2 = 0.30000000000000004, before limiting the decimals.
        let rounded = Double(String(format: "%.15g", value)) ?? value
        return rounded.formatted(
            .number
                .precision(.fractionLength(0...10))
                .grouping(usesGrouping ? .automatic : .never)
                .locale(locale)
        )
    }

    static func isDecimalDigit(_ character: Character) -> Bool {
        digit(character) != nil
    }

    /// Unlike `isNumber`, rejects superscripts such as `²`.
    fileprivate static func digit(_ character: Character) -> Character? {
        guard character.unicodeScalars.count == 1,
              character.unicodeScalars.first?.properties.numericType == .decimal,
              let value = character.wholeNumberValue else { return nil }
        return Character(String(value))
    }

    private struct Parser {
        private typealias Operand = (value: Double, isPercentage: Bool)

        private static let functions: [String: @Sendable (Double) -> Double] = [
            "sqrt": { $0.squareRoot() },
            "cbrt": { cbrt($0) },
            "abs": { abs($0) },
            "round": { $0.rounded() },
            "floor": { $0.rounded(.down) },
            "ceil": { $0.rounded(.up) },
            "sin": { sin($0) },
            "cos": { cos($0) },
            "tan": { tan($0) },
            "asin": { asin($0) },
            "acos": { acos($0) },
            "atan": { atan($0) },
            "ln": { log($0) },
            "log": { log10($0) },
            "log10": { log10($0) },
            "log2": { log2($0) },
            "exp": { exp($0) }
        ]
        private static let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E]
        private static let spaceGroupingSeparators: Set<Character> = [" ", "\u{00A0}", "\u{202F}", "'", "’", "_"]

        private let characters: [Character]
        private let groupingSeparator: Character?
        private var position = 0
        private(set) var usesOperator = false

        init(_ text: String, locale: Locale) {
            characters = Array(text)
            groupingSeparator = locale.groupingSeparator?.first
        }

        mutating func parse() -> Double? {
            guard let value = parseSum(), isAtEnd() else { return nil }
            return value
        }

        private mutating func parseSum() -> Double? {
            guard var value = parseProduct()?.value else { return nil }
            while let symbol = consume(anyOf: "+-−") {
                usesOperator = true
                guard let operand = parseProduct() else { return nil }
                // `200 + 15%` adds 15 percent of 200, as on a pocket calculator.
                let change = operand.isPercentage ? value * operand.value : operand.value
                value = symbol == "+" ? value + change : value - change
            }
            return value
        }

        private mutating func parseProduct() -> Operand? {
            guard var operand = parseUnary() else { return nil }
            while let symbol = consume(anyOf: "*×·xX/÷") {
                usesOperator = true
                guard let factor = parseUnary()?.value else { return nil }
                operand = ("/÷".contains(symbol) ? operand.value / factor : operand.value * factor, false)
            }
            return operand
        }

        private mutating func parseUnary() -> Operand? {
            if consume(anyOf: "-−") != nil {
                return parseUnary().map { (-$0.value, $0.isPercentage) }
            }
            if consume(anyOf: "+") != nil {
                return parseUnary()
            }
            return parsePower()
        }

        private mutating func parsePower() -> Operand? {
            guard let base = parsePostfix() else { return nil }
            guard consume("^") || consume("**") else { return base }
            usesOperator = true
            guard let exponent = parseUnary() else { return nil }
            return (pow(base.value, exponent.value), false)
        }

        private mutating func parsePostfix() -> Operand? {
            guard var value = parsePrimary() else { return nil }
            var isPercentage = false
            while let symbol = consume(anyOf: "%!") {
                usesOperator = true
                if symbol == "%" {
                    value /= 100
                    isPercentage = true
                } else {
                    guard value >= 0, value <= 170, value.rounded() == value else { return nil }
                    value = (1...max(1, Int(value))).reduce(1) { $0 * Double($1) }
                    isPercentage = false
                }
            }
            return (value, isPercentage)
        }

        private mutating func parsePrimary() -> Double? {
            if consume("(") {
                guard let value = parseSum() else { return nil }
                // Shows a result while the closing parenthesis is still untyped, as in `(1 + 2`.
                guard consume(")") || isAtEnd() else { return nil }
                return value
            }
            if consume("√") {
                usesOperator = true
                return parsePostfix()?.value.squareRoot()
            }
            skipWhitespace()
            if let number = parseNumber() {
                return number
            }
            let name = parseName()
            if let constant = Self.constants[name] {
                return constant
            }
            guard let function = Self.functions[name], consume("("), let argument = parseSum(),
                  consume(")") || isAtEnd() else { return nil }
            usesOperator = true
            return function(argument)
        }

        private mutating func parseNumber() -> Double? {
            var literal = ""
            var hasDecimalSeparator = false
            while position < characters.count {
                let character = characters[position]
                let isGroupingSeparator = character == groupingSeparator
                    || Self.spaceGroupingSeparators.contains(character)
                if let digit = Calculator.digit(character) {
                    literal.append(digit)
                } else if isGroupingSeparator, !literal.isEmpty, !hasDecimalSeparator,
                          isGroupOfThreeDigits(after: position) {
                    position += 1
                    continue
                } else if character == "." || character == ",",
                          !hasDecimalSeparator,
                          position + 1 < characters.count,
                          Calculator.digit(characters[position + 1]) != nil {
                    literal.append(".")
                    hasDecimalSeparator = true
                } else {
                    break
                }
                position += 1
            }
            return literal.isEmpty ? nil : Double(literal)
        }

        private mutating func parseName() -> String {
            var name = ""
            while position < characters.count, characters[position].isLetter {
                name.append(characters[position])
                position += 1
            }
            while !name.isEmpty, position < characters.count, Calculator.digit(characters[position]) != nil {
                name.append(characters[position])
                position += 1
            }
            return name.lowercased()
        }

        private func isGroupOfThreeDigits(after index: Int) -> Bool {
            let group = (index + 1)...(index + 3)
            guard group.upperBound < characters.count else { return false }
            guard group.allSatisfy({ Calculator.digit(characters[$0]) != nil }) else { return false }
            let next = group.upperBound + 1
            return next == characters.count || Calculator.digit(characters[next]) == nil
        }

        private mutating func consume(_ token: String) -> Bool {
            skipWhitespace()
            let tokenCharacters = Array(token)
            guard characters[position...].starts(with: tokenCharacters) else { return false }
            position += tokenCharacters.count
            return true
        }

        private mutating func consume(anyOf symbols: String) -> Character? {
            skipWhitespace()
            guard position < characters.count, symbols.contains(characters[position]) else { return nil }
            defer { position += 1 }
            return characters[position]
        }

        private mutating func isAtEnd() -> Bool {
            skipWhitespace()
            return position == characters.count
        }

        private mutating func skipWhitespace() {
            while position < characters.count, characters[position].isWhitespace {
                position += 1
            }
        }
    }
}
