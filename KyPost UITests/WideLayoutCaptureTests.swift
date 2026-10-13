//
//  WideLayoutCaptureTests.swift
//  KyPost UITests
//
//  A capture run, not a check, like ScreenshotTests: drives the demo build
//  through the stack/split switch by rotating the device, and writes a PNG
//  per step to KYPOST_CAPTURE_DIR (default /tmp/wide-shots) on the host as
//  well as attaching it. Skips unless KYPOST_SCREENSHOTS=1; run one test at
//  a time with TEST_RUNNER_KYPOST_SCREENSHOTS=1 and -only-testing.
//  testCaptureCurrentPose is for a pose changed by hand (the iPhone Duo's
//  fold): run it before and after folding.
//

#if os(iOS)
import XCTest

final class WideLayoutCaptureTests: XCTestCase {
    private var outputDir = URL(fileURLWithPath: "/tmp/wide-shots")
    private var step = 0

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["KYPOST_SCREENSHOTS"] == "1", "Layout capture only")
        if let dir = env["KYPOST_CAPTURE_DIR"] { outputDir = URL(fileURLWithPath: dir) }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        continueAfterFailure = true
    }

    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 1.2)
        step += 1
        let image = XCUIScreen.main.screenshot()
        let file = outputDir.appendingPathComponent(String(format: "%02d-%@.png", step, name))
        try? image.pngRepresentation.write(to: file)
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func rotate(_ orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-KyPostDemo"]
        app.launch()
        Thread.sleep(forTimeInterval: 3)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<2 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 2) else { break }
            let allow = alert.buttons["Allow"]
            if allow.exists { allow.tap() } else { alert.buttons.firstMatch.tap() }
        }
        return app
    }

    private func row(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)
        let button = app.buttons.matching(predicate).firstMatch
        return button.waitForExistence(timeout: 3) ? button : app.cells.matching(predicate).firstMatch
    }

    @discardableResult
    private func tap(_ element: XCUIElement, timeout: TimeInterval = 4) -> Bool {
        guard element.waitForExistence(timeout: timeout), element.isHittable else { return false }
        element.tap()
        Thread.sleep(forTimeInterval: 0.8)
        return true
    }

    private func backIfCovered(_ app: XCUIApplication) {
        guard !app.buttons["Compose"].isHittable else { return }
        tap(app.navigationBars.buttons.element(boundBy: 0))
    }

    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let bar = app.tabBars.buttons[name]
        return bar.waitForExistence(timeout: 2) ? bar : app.buttons[name].firstMatch
    }

    /// Rotation, reading, Undo beside the reader, search, select mode,
    /// compose, contacts — each across a portrait/landscape switch.
    @MainActor
    func testCaptureLayouts() {
        let app = launch()
        shot("inbox-portrait")
        rotate(.landscapeLeft)
        shot("inbox-landscape")
        rotate(.portrait)

        tap(row(app, "Your ticket"))
        shot("reader-portrait")
        rotate(.landscapeLeft)
        shot("reader-landscape")
        rotate(.portrait)
        shot("reader-back-to-portrait")
        backIfCovered(app)

        // Undo: archive a row, then open another message. In the split the
        // Undo bar must stay beside the reader; in the stack it commits.
        rotate(.landscapeLeft)
        let victim = row(app, "Q3 rollout")
        if victim.waitForExistence(timeout: 3) {
            victim.swipeLeft()
            Thread.sleep(forTimeInterval: 0.8)
            // The swipe's Archive, not the open reader's (which acts at once).
            app.buttons.matching(identifier: "Archive").allElementsBoundByIndex
                .filter { $0.isHittable }.min { $0.frame.minX < $1.frame.minX }?.tap()
            tap(row(app, "Key rotation"))
            shot("undo-beside-reader-landscape")
            rotate(.portrait)
            shot("undo-after-switch-portrait")
            Thread.sleep(forTimeInterval: 5)
            shot("undo-window-over")
            backIfCovered(app)
        } else {
            rotate(.portrait)
        }

        app.terminate()
    }

    /// Search, select mode, compose and contacts, each across a rotation.
    @MainActor
    func testCaptureLayoutsSecondHalf() {
        let app = launch()
        var search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 2) {
            // Hidden under the navigation bar until the list is pulled down.
            app.cells.firstMatch.swipeDown()
            Thread.sleep(forTimeInterval: 1)
            if !search.exists { tap(app.buttons["Search"].firstMatch, timeout: 2) }
            search = app.searchFields.firstMatch
        }
        if tap(search) {
            search.typeText("ticket\n")
            Thread.sleep(forTimeInterval: 1.5)
            shot("search-portrait")
            rotate(.landscapeLeft)
            shot("search-landscape")
            rotate(.portrait)
            shot("search-back-to-portrait")
            tap(app.buttons["Cancel"].firstMatch, timeout: 2)
        }

        if tap(app.buttons["Select"].firstMatch) {
            let cells = app.cells.allElementsBoundByIndex.filter { $0.isHittable }
            for cell in cells.prefix(2) { cell.tap() }
            shot("select-portrait")
            rotate(.landscapeLeft)
            shot("select-landscape")
            rotate(.portrait)
            tap(app.buttons["Done"].firstMatch)
        }

        if tap(app.buttons["Compose"].firstMatch) {
            let subject = app.textFields.element(boundBy: app.textFields.count > 3 ? 3 : 0)
            if subject.waitForExistence(timeout: 3) {
                subject.tap()
                subject.typeText("Layout check")
            }
            shot("compose-portrait")
            rotate(.landscapeLeft)
            shot("compose-landscape")
            rotate(.portrait)
            shot("compose-back-to-portrait")
            tap(app.buttons["Cancel"].firstMatch)
            tap(app.buttons["Discard"].firstMatch, timeout: 2)
        }

        if tap(tab(app, "Contacts")) {
            shot("contacts-portrait")
            tap(app.cells.firstMatch)
            shot("contact-portrait")
            rotate(.landscapeLeft)
            shot("contact-landscape")
            rotate(.portrait)
        }
        app.terminate()
    }

    @MainActor
    func testReaderAcrossRotation() {
        let app = launch()
        tap(row(app, "Your ticket"))
        shot("rr-portrait")
        rotate(.landscapeLeft)
        shot("rr-landscape")
        rotate(.portrait)
        shot("rr-portrait-again")
        backIfCovered(app)
        if tap(tab(app, "Contacts")) {
            tap(app.cells.firstMatch)
            shot("rc-portrait")
            rotate(.landscapeLeft)
            shot("rc-landscape")
            rotate(.portrait)
            shot("rc-portrait-again")
        }
        app.terminate()
    }

    @MainActor
    func testUndoBesideReader() {
        let app = launch()
        rotate(.landscapeLeft)
        tap(row(app, "Key rotation"))
        let victim = row(app, "Q3 rollout")
        victim.swipeLeft()
        Thread.sleep(forTimeInterval: 0.8)
        let archive = app.buttons.matching(identifier: "Archive").allElementsBoundByIndex
            .filter { $0.isHittable }.min { $0.frame.minX < $1.frame.minX }
        archive?.tap()
        Thread.sleep(forTimeInterval: 0.5)
        shot("ub-reader-undo")
        Thread.sleep(forTimeInterval: 5)
        shot("ub-window-over")
        rotate(.portrait)
        app.terminate()
    }

    @MainActor
    func testSearchAcrossRotation() {
        let app = launch()
        var search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 2) {
            let from = app.cells.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: 70)))
            Thread.sleep(forTimeInterval: 1)
            search = app.searchFields.firstMatch
            shot("sr-pulled")
        }
        if tap(search) {
            search.typeText("ticket\n")
            Thread.sleep(forTimeInterval: 1.5)
            shot("sr-portrait")
            rotate(.landscapeLeft)
            shot("sr-landscape")
            rotate(.portrait)
            shot("sr-portrait-again")
        }
        app.terminate()
    }

    @MainActor
    func testComposeAcrossRotation() {
        let app = launch()
        let compose = app.buttons["Compose"].firstMatch
        // A narrow iPad stack folds Compose into the overflow menu.
        let startsLandscape = !(compose.waitForExistence(timeout: 3) && compose.isHittable)
        if startsLandscape { rotate(.landscapeLeft) }
        guard tap(compose) else { return }
        let fields = app.textFields.allElementsBoundByIndex
        if let subject = fields.last {
            subject.tap()
            subject.typeText("Layout check")
        }
        if app.keyboards.buttons["Hide keyboard"].exists { app.keyboards.buttons["Hide keyboard"].tap() }
        let first: UIDeviceOrientation = startsLandscape ? .landscapeLeft : .portrait
        let second: UIDeviceOrientation = startsLandscape ? .portrait : .landscapeLeft
        shot("cm-\(first.isLandscape ? "landscape" : "portrait")")
        rotate(second)
        shot("cm-\(second.isLandscape ? "landscape" : "portrait")")
        rotate(first)
        shot("cm-\(first.isLandscape ? "landscape" : "portrait")-again")
        tap(app.buttons["Cancel"].firstMatch)
        tap(app.buttons["Discard"].firstMatch, timeout: 2)
        app.terminate()
    }

    /// One pose, no rotation — for a device whose pose is changed by hand
    /// (the iPhone Duo's fold). Leaves a message open and a search typed.
    @MainActor
    func testCaptureCurrentPose() {
        let app = launch()
        shot("pose-inbox")
        tap(row(app, "Your ticket"))
        shot("pose-reader")
        app.terminate()
    }
}
#endif
