import XCTest

@MainActor final class ZORACameraUITests: XCTestCase {
    func testDisconnectedCameraDoesNotPresentFakeLiveView() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["connectCamera"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["�ȴ���� Nikon Z7 II"].exists)
        XCTAssertFalse(app.buttons["�ͷſ���"].isEnabled)
        app.buttons["connectCamera"].tap()
        XCTAssertTrue(app.buttons["���� Nikon ���"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Nikon ������֤���"].exists)
    }
    func testLibraryAndLooksNavigation() {
        let app = XCUIApplication(); app.launch()
        app.tabBars.buttons["��Ƭ"].tap()
        XCTAssertTrue(app.buttons["importPhotos"].waitForExistence(timeout: 5))
        app.tabBars.buttons["���"].tap()
        XCTAssertTrue(app.staticTexts["�����չ�"].waitForExistence(timeout: 5))
    }
    func testUSBSimulatorNeverPretendsACameraIsConnected() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["connectCamera"].waitForExistence(timeout: 10))
        app.buttons["connectCamera"].tap()
        app.segmentedControls["connectionMode"].buttons["USB ����"].tap()
        app.buttons["searchUSBCamera"].tap()
        XCTAssertTrue(app.staticTexts["ģ��������������ʵ USB �������ʹ�� iPhone / iPad"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["�Ͽ� USB �Ự"].exists)
    }
}
