import XCTest

@MainActor final class ZORACameraUITests: XCTestCase {
    func testDisconnectedCameraDoesNotPresentFakeLiveView() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["connectCamera"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["等待你的 Nikon Z7 II"].exists)
        XCTAssertFalse(app.buttons["释放快门"].isEnabled)
        app.buttons["connectCamera"].tap()
        XCTAssertTrue(app.buttons["搜索 Nikon 相机"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Nikon 蓝牙认证完成"].exists)
    }
    func testLibraryAndLooksNavigation() {
        let app = XCUIApplication(); app.launch()
        app.tabBars.buttons["照片"].tap()
        XCTAssertTrue(app.buttons["importPhotos"].waitForExistence(timeout: 5))
        app.tabBars.buttons["风格"].tap()
        XCTAssertTrue(app.staticTexts["琥珀日光"].waitForExistence(timeout: 5))
    }
}
