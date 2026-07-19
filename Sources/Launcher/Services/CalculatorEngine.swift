import Foundation

struct Calculation: Equatable {
    let expression: String
    let result: Double
    let formattedResult: String
    let operationLabel: String
    let resultLabel: String?
}

enum CalculatorEngine {
    static func evaluate(_ input: String) -> Calculation? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let tokens = tokenize(trimmed),
              qualifiesAsCalculation(tokens) else { return nil }

        var parser = Parser(tokens: tokens)
        guard let value = try? parser.parseExpression(),
              parser.isAtEnd,
              value.isFinite,
              let formatted = format(value) else { return nil }

        return Calculation(
            expression: trimmed,
            result: value,
            formattedResult: formatted,
            operationLabel: operationLabel(for: tokens),
            resultLabel: spellOut(value)
        )
    }

    // MARK: - Tokens

    private enum Token: Equatable {
        case number(Double)
        case op(Character)
        case leftParen
        case rightParen
        case identifier(String)

        var startsValue: Bool {
            switch self {
            case .number, .leftParen, .identifier: true
            case .op, .rightParen: false
            }
        }
    }

    private static func tokenize(_ input: String) -> [Token]? {
        var tokens: [Token] = []
        let characters = Array(input)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character.isWhitespace {
                index += 1
            } else if character.isNumber || character == "." {
                var digits = ""
                var sawDot = false
                while index < characters.count {
                    let digit = characters[index]
                    if digit == "." {
                        guard !sawDot else { return nil }
                        sawDot = true
                    } else if !digit.isNumber {
                        break
                    }
                    digits.append(digit)
                    index += 1
                }
                guard let value = Double(digits) else { return nil }
                tokens.append(.number(value))
            } else if character.isLetter {
                var word = ""
                while index < characters.count, characters[index].isLetter {
                    word.append(characters[index])
                    index += 1
                }
                let name = word.lowercased()
                if name == "x" {
                    tokens.append(.op("*"))
                } else {
                    tokens.append(.identifier(name == "π" ? "pi" : name))
                }
            } else {
                switch character {
                case "+": tokens.append(.op("+"))
                case "-", "−", "–": tokens.append(.op("-"))
                case "*":
                    if index + 1 < characters.count, characters[index + 1] == "*" {
                        tokens.append(.op("^"))
                        index += 1
                    } else {
                        tokens.append(.op("*"))
                    }
                case "×", "·", "⋅": tokens.append(.op("*"))
                case "/", "÷": tokens.append(.op("/"))
                case "^": tokens.append(.op("^"))
                case "%": tokens.append(.op("%"))
                case "(": tokens.append(.leftParen)
                case ")": tokens.append(.rightParen)
                case "=": break
                default: return nil
                }
                index += 1
            }
        }

        return tokens.isEmpty ? nil : tokens
    }

    /// Plain numbers and lone words should keep behaving as searches; only show the
    /// calculator when the query contains an operator, or combines a number with a
    /// known constant or function ("2pi").
    private static func qualifiesAsCalculation(_ tokens: [Token]) -> Bool {
        var hasOperator = false
        var hasIdentifier = false
        var hasNumber = false
        for token in tokens {
            switch token {
            case .op, .leftParen, .rightParen: hasOperator = true
            case .identifier: hasIdentifier = true
            case .number: hasNumber = true
            }
        }
        return hasOperator || (hasIdentifier && hasNumber)
    }

    // MARK: - Parser

    private struct ParseError: Error {}

    private static let constants: [String: Double] = [
        "pi": .pi,
        "tau": .pi * 2,
        "e": M_E
    ]

    private static let functions: [String: (Double) -> Double] = [
        "sqrt": sqrt,
        "cbrt": cbrt,
        "abs": abs,
        "ln": log,
        "log": log10,
        "log2": log2,
        "exp": exp,
        "sin": sin,
        "cos": cos,
        "tan": tan,
        "floor": floor,
        "ceil": ceil,
        "round": { $0.rounded() }
    ]

    private struct Parser {
        let tokens: [Token]
        var index = 0

        var isAtEnd: Bool { index >= tokens.count }

        private var current: Token? {
            index < tokens.count ? tokens[index] : nil
        }

        private var next: Token? {
            index + 1 < tokens.count ? tokens[index + 1] : nil
        }

        mutating func parseExpression() throws -> Double {
            var value = try parseTerm()
            while case let .op(symbol) = current, symbol == "+" || symbol == "-" {
                index += 1
                let rhs = try parseTerm()
                value = symbol == "+" ? value + rhs : value - rhs
            }
            return value
        }

        private mutating func parseTerm() throws -> Double {
            var value = try parseFactor()
            loop: while let token = current {
                switch token {
                case .op("*"):
                    index += 1
                    value *= try parseFactor()
                case .op("/"):
                    index += 1
                    value /= try parseFactor()
                case .op("%") where next?.startsValue == true:
                    index += 1
                    value = value.truncatingRemainder(dividingBy: try parseFactor())
                case .number, .leftParen, .identifier:
                    // Implicit multiplication: "2pi", "2(3+4)".
                    value *= try parseFactor()
                default:
                    break loop
                }
            }
            return value
        }

        private mutating func parseFactor() throws -> Double {
            if case .op("-") = current {
                index += 1
                return -(try parseFactor())
            }
            if case .op("+") = current {
                index += 1
                return try parseFactor()
            }
            return try parsePower()
        }

        private mutating func parsePower() throws -> Double {
            let value = try parsePostfix()
            if case .op("^") = current {
                index += 1
                return pow(value, try parseFactor())
            }
            return value
        }

        private mutating func parsePostfix() throws -> Double {
            var value = try parsePrimary()
            // Trailing "%" is a percentage; "%" followed by a value is modulo.
            while case .op("%") = current, next?.startsValue != true {
                index += 1
                value /= 100
            }
            return value
        }

        private mutating func parsePrimary() throws -> Double {
            switch current {
            case let .number(value):
                index += 1
                return value
            case .leftParen:
                index += 1
                let value = try parseExpression()
                guard case .rightParen = current else { throw ParseError() }
                index += 1
                return value
            case let .identifier(name):
                index += 1
                if let constant = CalculatorEngine.constants[name] { return constant }
                guard let function = CalculatorEngine.functions[name],
                      case .leftParen = current else { throw ParseError() }
                index += 1
                let argument = try parseExpression()
                guard case .rightParen = current else { throw ParseError() }
                index += 1
                return function(argument)
            default:
                throw ParseError()
            }
        }
    }

    // MARK: - Labels

    private static let functionLabels: [String: String] = [
        "sqrt": "Square Root",
        "cbrt": "Cube Root",
        "abs": "Absolute Value",
        "ln": "Natural Log",
        "log": "Logarithm",
        "log2": "Log Base 2",
        "exp": "Exponential",
        "sin": "Sine",
        "cos": "Cosine",
        "tan": "Tangent",
        "floor": "Floor",
        "ceil": "Ceiling",
        "round": "Rounded"
    ]

    /// Describes the outermost operation, e.g. "Sum" for "5+5".
    private static func operationLabel(for tokens: [Token]) -> String {
        var depth = 0
        var seen: Set<Character> = []

        for (index, token) in tokens.enumerated() {
            switch token {
            case .leftParen: depth += 1
            case .rightParen: depth -= 1
            case let .op(symbol) where depth == 0:
                let previous = index > 0 ? tokens[index - 1] : nil
                let isBinary: Bool
                switch previous {
                case .number, .rightParen, .identifier: isBinary = true
                default: isBinary = false
                }
                switch symbol {
                case "+", "-":
                    if isBinary { seen.insert(symbol) }
                case "%":
                    seen.insert(tokens.indices.contains(index + 1) && tokens[index + 1].startsValue ? "m" : "p")
                default:
                    seen.insert(symbol)
                }
            default: break
            }
        }

        if seen.contains("+") { return "Sum" }
        if seen.contains("-") { return "Difference" }
        if seen.contains("*") { return "Product" }
        if seen.contains("/") { return "Quotient" }
        if seen.contains("m") { return "Remainder" }
        if seen.contains("^") { return "Power" }
        if seen.contains("p") { return "Percentage" }
        if case let .identifier(name) = tokens.first, let label = functionLabels[name] {
            return label
        }
        if tokens.contains(where: { if case .identifier = $0 { return true } else { return false } }) {
            return "Constant"
        }
        return "Expression"
    }

    // MARK: - Formatting

    private static let resultFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 10
        return formatter
    }()

    private static let scientificFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .scientific
        formatter.maximumSignificantDigits = 8
        formatter.exponentSymbol = "e"
        return formatter
    }()

    private static let spellOutFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .spellOut
        return formatter
    }()

    private static func format(_ value: Double) -> String? {
        guard value.isFinite else { return nil }
        let normalized = value == 0 ? 0 : value
        let magnitude = abs(normalized)
        if magnitude >= 1e15 || (magnitude > 0 && magnitude < 1e-9) {
            return scientificFormatter.string(from: NSNumber(value: normalized))
        }
        return resultFormatter.string(from: NSNumber(value: normalized))
    }

    /// "Ten" for 10; nil when the number is too large or unwieldy to spell out.
    private static func spellOut(_ value: Double) -> String? {
        guard value.isFinite, abs(value) < 1e15 else { return nil }
        let rounded = (value * 1e10).rounded() / 1e10
        guard let spelled = spellOutFormatter.string(from: NSNumber(value: rounded)),
              spelled.count <= 44 else { return nil }
        return spelled.localizedCapitalized
    }
}
