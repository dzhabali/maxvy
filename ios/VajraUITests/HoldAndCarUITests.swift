import XCTest

/// Живые касания в демо-режиме: удержание главной кнопки и режим «Авто».
/// Счёт дня читается из accessibilityValue («за день N»).
final class HoldAndCarUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demo", "-noOffer", "-noFocus"]
        app.launch()
    }

    private func total(_ e: XCUIElement) -> Int {
        let v = (e.value as? String) ?? ""
        return Int(v.split(separator: " ").last ?? "") ?? -1
    }

    func testHoldThreeSecondsCountsEveryTime() {
        let hold = app.descendants(matching: .any)["hold"]
        XCTAssertTrue(hold.waitForExistence(timeout: 10))
        let start = total(hold)
        XCTAssertGreaterThanOrEqual(start, 0)
        // пять удержаний подряд по 3,2 с — каждое обязано засчитаться
        for k in 1...5 {
            hold.press(forDuration: 3.2)
            sleep(1)
            XCTAssertEqual(total(hold), start + k, "удержание №\(k) не засчиталось")
        }
    }

    func testShortHoldDoesNotCount() {
        let hold = app.descendants(matching: .any)["hold"]
        XCTAssertTrue(hold.waitForExistence(timeout: 10))
        let start = total(hold)
        hold.press(forDuration: 1.5)
        sleep(1)
        XCTAssertEqual(total(hold), start)
    }

    func testCarModeTapCountsAndExit() {
        let enter = app.buttons["carEnter"]
        XCTAssertTrue(enter.waitForExistence(timeout: 10))
        enter.tap()
        let surface = app.descendants(matching: .any)["carSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        let start = total(surface)
        surface.tap()
        sleep(1)                                   // пауза ≥ 1 с между засчётами
        XCTAssertEqual(total(surface), start + 1)
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.9)).tap()
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.2)).tap()   // сразу второй — отсекается
        sleep(1)
        XCTAssertEqual(total(surface), start + 2)
        app.buttons["carExit"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["hold"].waitForExistence(timeout: 5))
        XCTAssertEqual(total(app.descendants(matching: .any)["hold"]), start + 2)
    }
}
