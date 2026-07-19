import AppKit
import XCTest
@testable import Launcher

final class CalculatorEngineTests: XCTestCase {
    private func result(_ input: String) -> String? {
        CalculatorEngine.evaluate(input)?.formattedResult
    }

    func testBasicArithmetic() {
        XCTAssertEqual(result("5+5"), "10")
        XCTAssertEqual(result("7-10"), "-3")
        XCTAssertEqual(result("6*7"), "42")
        XCTAssertEqual(result("9/2"), "4.5")
    }

    func testOperatorPrecedenceAndParentheses() {
        XCTAssertEqual(result("2+3*4"), "14")
        XCTAssertEqual(result("(2+3)*4"), "20")
        XCTAssertEqual(result("10-4-3"), "3")
        XCTAssertEqual(result("100/10/2"), "5")
    }

    func testPowerIsRightAssociative() {
        XCTAssertEqual(result("2^3^2"), "512")
        XCTAssertEqual(result("2**10"), "1,024")
        XCTAssertEqual(result("-2^2"), "-4")
    }

    func testUnaryMinus() {
        XCTAssertEqual(result("-5+3"), "-2")
        XCTAssertEqual(result("2*-3"), "-6")
    }

    func testPercentAndModulo() {
        XCTAssertEqual(result("50%"), "0.5")
        XCTAssertEqual(result("50% * 300"), "150")
        XCTAssertEqual(result("10 % 3"), "1")
    }

    func testAlternativeOperatorSymbols() {
        XCTAssertEqual(result("6×7"), "42")
        XCTAssertEqual(result("10÷4"), "2.5")
        XCTAssertEqual(result("2x3"), "6")
    }

    func testConstantsAndFunctions() {
        XCTAssertEqual(result("sqrt(9)"), "3")
        XCTAssertEqual(result("abs(-4)"), "4")
        XCTAssertEqual(CalculatorEngine.evaluate("pi*2")?.result ?? 0, .pi * 2, accuracy: 1e-12)
        XCTAssertEqual(CalculatorEngine.evaluate("2pi")?.result ?? 0, .pi * 2, accuracy: 1e-12)
    }

    func testImplicitMultiplication() {
        XCTAssertEqual(result("2(3+4)"), "14")
    }

    func testFloatingPointNoiseIsRoundedAway() {
        XCTAssertEqual(result("0.1+0.2"), "0.3")
    }

    func testGroupingSeparatorsInLargeResults() {
        XCTAssertEqual(result("1000*1000"), "1,000,000")
    }

    func testQueriesThatShouldNotBeCalculations() {
        XCTAssertNil(CalculatorEngine.evaluate("safari"))
        XCTAssertNil(CalculatorEngine.evaluate("42"))
        XCTAssertNil(CalculatorEngine.evaluate("e"))
        XCTAssertNil(CalculatorEngine.evaluate("iphone 15"))
        XCTAssertNil(CalculatorEngine.evaluate(""))
    }

    func testInvalidExpressions() {
        XCTAssertNil(CalculatorEngine.evaluate("5+"))
        XCTAssertNil(CalculatorEngine.evaluate("(2+3"))
        XCTAssertNil(CalculatorEngine.evaluate("2..5+1"))
        XCTAssertNil(CalculatorEngine.evaluate("1/0"))
        XCTAssertNil(CalculatorEngine.evaluate("sqrt 9"))
    }

    func testOperationLabels() {
        XCTAssertEqual(CalculatorEngine.evaluate("5+5")?.operationLabel, "Sum")
        XCTAssertEqual(CalculatorEngine.evaluate("9-4")?.operationLabel, "Difference")
        XCTAssertEqual(CalculatorEngine.evaluate("6*7")?.operationLabel, "Product")
        XCTAssertEqual(CalculatorEngine.evaluate("9/3")?.operationLabel, "Quotient")
        XCTAssertEqual(CalculatorEngine.evaluate("2^8")?.operationLabel, "Power")
        XCTAssertEqual(CalculatorEngine.evaluate("10%3")?.operationLabel, "Remainder")
        XCTAssertEqual(CalculatorEngine.evaluate("50%")?.operationLabel, "Percentage")
        XCTAssertEqual(CalculatorEngine.evaluate("sqrt(16)")?.operationLabel, "Square Root")
        XCTAssertEqual(CalculatorEngine.evaluate("2+3*4")?.operationLabel, "Sum")
        XCTAssertEqual(CalculatorEngine.evaluate("(2+3)*4")?.operationLabel, "Product")
        XCTAssertEqual(CalculatorEngine.evaluate("-5+3")?.operationLabel, "Sum")
    }

    func testSpelledOutResultLabel() {
        XCTAssertEqual(CalculatorEngine.evaluate("5+5")?.resultLabel, "Ten")
        XCTAssertEqual(CalculatorEngine.evaluate("100+23")?.resultLabel, "One Hundred Twenty-Three")
    }
}

final class LauncherModelCalculatorTests: XCTestCase {
    private func makeModel() -> LauncherModel {
        let model = LauncherModel(
            settings: LauncherSettings(defaults: UserDefaults(suiteName: "LauncherModelCalculatorTests")!),
            isUITesting: true,
            loginItems: InMemoryLoginItemService()
        )
        model.loadApplications()
        return model
    }

    func testCalculationAppearsAsFirstResult() {
        let model = makeModel()
        model.query = "5+5"

        XCTAssertEqual(model.calculation?.formattedResult, "10")
        XCTAssertEqual(model.results.first?.kind, .calculator)
        XCTAssertEqual(model.results.first?.destination, .copyText("10"))
        XCTAssertEqual(model.selectedIndex, 0)
    }

    func testEnterOnCalculatorCopiesAnswer() {
        let model = makeModel()
        var closed = false
        model.onRequestClose = { closed = true }
        model.query = "6*7"

        NSPasteboard.general.clearContents()
        model.activateSelected()

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "42")
        XCTAssertTrue(closed)
    }

    func testNonMathQueryHasNoCalculation() {
        let model = makeModel()
        model.query = "calculator"

        XCTAssertNil(model.calculation)
        XCTAssertNotEqual(model.results.first?.kind, .calculator)
    }
}
