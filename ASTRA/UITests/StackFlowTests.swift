import XCTest

final class StackFlowTests: XCTestCase {
    @MainActor
    func testImportedFramesCreateAStack() {
        let app = launch(with: "good")
        app.buttons["start-stack"].tap()
        let success = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "合成完成")).firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "384 × 256 像素")).firstMatch.exists)
        XCTAssertTrue(app.buttons["导出照片"].isEnabled)
    }

    @MainActor
    func testMixedDimensionsShowPersistentReason() {
        let app = launch(with: "mixed")
        app.buttons["start-stack"].tap()
        let error = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "尺寸不同")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.buttons["start-stack"].isEnabled)
    }

    @MainActor
    private func launch(with fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ASTRA_UI_STACK_FIXTURE"] = fixture
        app.launchArguments = ["-astra.hasSeenOnboarding", "YES"]
        app.launch()
        let button = app.buttons["start-stack"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 25), .completed, app.debugDescription)
        return app
    }
}
