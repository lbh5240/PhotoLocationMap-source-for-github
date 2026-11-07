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
    func testMixedDimensionsCanRegisterWithSelectedSubject() {
        let app = launch(with: "mixed")
        app.buttons["select-reference-region"].tap()
        let canvas = app.descendants(matching: .any)["reference-selector-canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10), app.debugDescription)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.08))
            .press(forDuration: 0.08, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.93)))
        XCTAssertTrue(app.descendants(matching: .any)["reference-region"].firstMatch.waitForExistence(timeout: 4))
        app.buttons["完成"].tap()
        app.buttons["start-stack"].tap()
        let success = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "合成完成")).firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 35), app.debugDescription)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "384 × 256 像素")).firstMatch.exists)
    }

    @MainActor
    func testDifferentExposuresKeepMatching() {
        let app = launch(with: "exposure")
        app.buttons["start-stack"].tap()
        let success = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "合成完成")).firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 35), app.debugDescription)
    }

    @MainActor
    func testEditorDockAndPrecisionControls() {
        let app = launch(with: "good")
        let stack = app.buttons["editor-tool-stack"]
        let pager = app.buttons["editor-dock-page"]
        XCTAssertTrue(stack.exists && pager.exists)
        let trailingEdge = pager.frame.maxX
        app.buttons["editor-tool-light"].tap()
        let exposure = app.staticTexts["ruler-value"]
        XCTAssertTrue(exposure.waitForExistence(timeout: 5))
        XCTAssertEqual(exposure.label, "0.00 EV")
        app.buttons["增大曝光"].tap()
        XCTAssertEqual(exposure.label, "0.05 EV")
        capture("ASTRA-LIGHT", app: app)

        pager.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: stack.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        let curves = app.buttons["editor-tool-curves"]
        XCTAssertTrue(curves.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(pager.frame.maxX, trailingEdge, accuracy: 1)
        curves.tap()
        let graph = app.descendants(matching: .any)["tone-curve-graph"].firstMatch
        XCTAssertTrue(graph.waitForExistence(timeout: 5))
        let midpoint = graph.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        midpoint.press(forDuration: 0.05, thenDragTo: graph.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32)))
        XCTAssertNotEqual(app.staticTexts["ruler-value"].label, "0.50")
        capture("ASTRA-CURVES", app: app)

        pager.tap()
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        XCTAssertEqual(pager.frame.maxX, trailingEdge, accuracy: 1)
        app.buttons["editor-tool-wheels"].tap()
        XCTAssertTrue(app.buttons["中间调"].waitForExistence(timeout: 5))
        capture("ASTRA-WHEELS", app: app)
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
