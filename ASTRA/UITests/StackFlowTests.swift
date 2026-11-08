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
        let region = app.descendants(matching: .any)["reference-region"].firstMatch
        XCTAssertTrue(region.waitForExistence(timeout: 4))
        XCTAssertGreaterThan(region.frame.width, canvas.frame.width * 0.5, "从空白处拖动应按整个手势框选")
        let portrait = app.buttons["region-aspect-9:16"]
        if !portrait.isHittable { app.scrollViews["region-ratios"].swipeLeft() }
        portrait.tap()
        XCTAssertEqual(region.frame.width / region.frame.height, 9.0 / 16, accuracy: 0.015)
        app.buttons["完成"].tap()
        app.buttons["start-stack"].tap()
        let success = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "合成完成")).firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 35), app.debugDescription)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "135 × 240 像素")).firstMatch.exists)
        app.buttons["导出照片"].tap()
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "PNG 16 位")).firstMatch.tap()
        let share = app.buttons["导出并分享"]
        if !share.isHittable { app.swipeUp() }
        share.tap()
        _ = app.buttons["取消"].waitForExistence(timeout: 6)
    }

    @MainActor
    func testSubjectFrameKeepsAspectWhileMovingAndScaling() {
        let app = launch(with: "good")
        app.buttons["select-reference-region"].tap()
        let canvas = app.descendants(matching: .any)["reference-selector-canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        app.buttons["region-aspect-1:1"].tap()
        let region = app.descendants(matching: .any)["reference-region"].firstMatch
        XCTAssertTrue(region.waitForExistence(timeout: 5))
        XCTAssertEqual(region.frame.width, region.frame.height, accuracy: 2)
        let initialCenter = region.frame.midX
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.08, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.55)))
        XCTAssertGreaterThan(region.frame.midX, initialCenter)
        XCTAssertEqual(region.frame.width, region.frame.height, accuracy: 2)
        let initialWidth = region.frame.width
        app.sliders["region-size-slider"].adjust(toNormalizedSliderPosition: 0.2)
        XCTAssertLessThan(region.frame.width, initialWidth)
        XCTAssertEqual(region.frame.width, region.frame.height, accuracy: 2)
    }

    @MainActor
    func testDifferentExposuresKeepMatching() {
        let app = launch(with: "exposure")
        app.buttons["start-stack"].tap()
        let success = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "合成完成")).firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 35), app.debugDescription)
    }

    @MainActor
    func testHDRAndAstroScreenStretch() {
        let app = launch(with: "exposure")
        let hdr = app.switches["HDR 多曝光融合"]
        XCTAssertTrue(hdr.exists)
        hdr.tap()
        app.buttons["start-stack"].tap()
        let success = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "合成完成")).firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 35), app.debugDescription)
        XCTAssertTrue(app.buttons["导出照片"].waitForExistence(timeout: 5))
        let canvas = app.descendants(matching: .any)["photo-canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let neutralImage = canvas.screenshot().image.pngData()
        app.descendants(matching: .any)["editor-dock"].firstMatch.swipeLeft()
        app.buttons["editor-tool-astro"].tap()
        XCTAssertTrue(app.buttons["auto-develop"].exists)
        app.buttons["auto-develop"].tap()
        var changed = false
        for _ in 0..<24 {
            if canvas.screenshot().image.pngData() != neutralImage { changed = true; break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(changed, "星云参数应改变真实预览像素")
        let decrease = app.buttons["减小去灰强度"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: decrease)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 8), .completed)
        let automatic = canvas.screenshot().image.pngData()
        decrease.tap()
        XCTAssertTrue(previewChanged(canvas, from: automatic), "去灰刻度尺必须改变真实预览像素")
        let noSpikes = canvas.screenshot().image.pngData()
        let four = app.buttons["spike-style-four"]
        let inspector = app.scrollViews["editor-inspector"]
        for _ in 0..<3 where !four.isHittable { inspector.swipeUp(velocity: .slow) }
        four.tap()
        XCTAssertTrue(previewChanged(canvas, from: noSpikes), "星芒必须改变真实预览像素")
        let sparse = canvas.screenshot().image.pngData()
        let dense = app.buttons["spike-density-dense"]
        for _ in 0..<3 where !dense.isHittable {
            inspector.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
                .press(forDuration: 0.05, thenDragTo: inspector.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52)))
        }
        dense.tap()
        XCTAssertTrue(dense.isSelected, "密度卡片应选中较多")
        XCTAssertTrue(previewChanged(canvas, from: sparse), "较多应让更多星点产生星芒")
        let off = app.buttons["spike-style-off"]
        for _ in 0..<3 where !off.isHittable { inspector.swipeDown(velocity: .slow) }
        off.tap()
        var spikesRemoved = false
        for _ in 0..<25 {
            if canvas.screenshot().image.pngData() == noSpikes { spikesRemoved = true; break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(spikesRemoved, "关闭星芒应恢复原先的预览像素")
        let natural = canvas.screenshot().image.pngData()
        app.buttons["editor-tool-detail"].tap()
        app.buttons["editor-tool-astro"].tap()
        let core = app.buttons["develop-method-1"]
        for _ in 0..<5 where !core.isHittable {
            inspector.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.76))
                .press(forDuration: 0.05, thenDragTo: inspector.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.53)))
        }
        XCTAssertTrue(core.isHittable)
        core.tap()
        var coreChanged = false
        for _ in 0..<20 {
            if canvas.screenshot().image.pngData() != natural { coreChanged = true; break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(coreChanged, "亮核算法必须改变真实预览像素")
        let coreImage = canvas.screenshot().image.pngData()
        XCTAssertTrue(app.buttons["develop-method-2"].exists)
        app.buttons["develop-method-2"].tap()
        var gasChanged = false
        for _ in 0..<20 {
            if canvas.screenshot().image.pngData() != coreImage { gasChanged = true; break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(gasChanged, "云气算法必须改变真实预览像素")
        let arc = app.buttons["增大Arcsinh 拉伸"]
        for _ in 0..<4 where !arc.isHittable { inspector.swipeUp(velocity: .slow) }
        XCTAssertTrue(app.staticTexts["Arcsinh 拉伸"].exists)
        app.buttons["增大Arcsinh 拉伸"].tap()
        XCTAssertTrue(app.staticTexts["ruler-value"].exists)
        XCTAssertTrue(app.buttons["reset-adjustments"].exists)
        app.buttons["reset-adjustments"].tap()
        XCTAssertTrue(app.staticTexts.matching(identifier: "ruler-value")
            .matching(NSPredicate(format: "label == %@", "0.0")).firstMatch.exists)
        XCTAssertFalse(app.alerts["ASTRA"].exists, "星云处理内核必须实际运行")
        XCTAssertTrue(app.buttons["导出照片"].isEnabled)
        app.buttons["导出照片"].tap()
        XCTAssertTrue(app.navigationBars["导出成片"].waitForExistence(timeout: 5))
        let match = app.switches["export-match-preview"]
        for _ in 0..<3 where !match.exists { app.swipeUp() }
        XCTAssertTrue(match.waitForExistence(timeout: 5))
        XCTAssertEqual(match.value as? String, "1", "成片默认应与预览一致")
        let album = app.buttons["export-to-photos"]
        for _ in 0..<3 where !album.exists { app.swipeUp() }
        XCTAssertTrue(album.waitForExistence(timeout: 5))
    }

    @MainActor
    func testEditorDockAndPrecisionControls() {
        let app = launch(with: "good")
        let stack = app.buttons["editor-tool-stack"]
        let dock = app.descendants(matching: .any)["editor-dock"].firstMatch
        XCTAssertTrue(stack.exists && dock.exists)
        let trailingEdge = dock.frame.maxX
        app.buttons["editor-tool-light"].tap()
        let exposure = app.staticTexts["ruler-value"]
        XCTAssertTrue(exposure.waitForExistence(timeout: 5))
        XCTAssertEqual(exposure.label, "0.00 EV")
        app.buttons["增大曝光"].tap()
        XCTAssertEqual(exposure.label, "0.05 EV")
        capture("ASTRA-LIGHT", app: app)

        dock.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: dock.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)))
        let curves = app.buttons["editor-tool-curves"]
        XCTAssertTrue(curves.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(dock.frame.maxX, trailingEdge, accuracy: 1)
        curves.tap()
        let graph = app.descendants(matching: .any)["tone-curve-graph"].firstMatch
        XCTAssertTrue(graph.waitForExistence(timeout: 5))
        let midpoint = graph.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        midpoint.press(forDuration: 0.05, thenDragTo: graph.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32)))
        XCTAssertNotEqual(app.staticTexts["ruler-value"].label, "0.50")
        capture("ASTRA-CURVES", app: app)

        dock.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: dock.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)))
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        XCTAssertEqual(dock.frame.maxX, trailingEdge, accuracy: 1)
        app.buttons["editor-tool-wheels"].tap()
        XCTAssertTrue(app.buttons["中间调"].waitForExistence(timeout: 5))
        capture("ASTRA-WHEELS", app: app)
    }

    @MainActor
    private func previewChanged(_ canvas: XCUIElement, from previous: Data?) -> Bool {
        for _ in 0..<25 {
            if canvas.screenshot().image.pngData() != previous { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
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
