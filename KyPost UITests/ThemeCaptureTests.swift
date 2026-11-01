//
//  ThemeCaptureTests.swift
//  KyPost UITests
//
//  A capture run, not a check, like ScreenshotTests: launches the demo build
//  in one theme and writes the inbox and the theme settings screen as PNGs to
//  KYPOST_CAPTURE_DIR (default /tmp/theme-shots) on the host. Skips unless
//  KYPOST_SCREENSHOTS=1. KYPOST_THEME_ARGS holds extra launch arguments,
//  separated by `|` (`-theme.pair|busnes-pair|-theme.mode|dark`): they land
//  in the argument domain, which the demo's isolated defaults read through.
//  KYPOST_CAPTURE_PREFIX names the files.
//

#if os(iOS)
import XCTest

final class ThemeCaptureTests: XCTestCase {
    private var outputDir = URL(fileURLWithPath: "/tmp/theme-shots")
    private var prefix = "shot"
    private var extraArguments: [String] = []

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["KYPOST_SCREENSHOTS"] == "1", "Theme capture only")
        if let dir = env["KYPOST_CAPTURE_DIR"] { outputDir = URL(fileURLWithPath: dir) }
        if let name = env["KYPOST_CAPTURE_PREFIX"] { prefix = name }
        if let args = env["KYPOST_THEME_ARGS"], !args.isEmpty {
            extraArguments = args.components(separatedBy: "|")
        }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        continueAfterFailure = true
    }

    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 1.2)
        // The iPhone Duo's main screen is the outer display, dark while
        // unfolded: take whichever screen is lit.
        let image = XCUIScreen.screens.map { $0.screenshot() }
            .max { $0.pngRepresentation.count < $1.pngRepresentation.count }
            ?? XCUIScreen.main.screenshot()
        try? image.pngRepresentation.write(to: outputDir.appendingPathComponent("\(prefix)-\(name).png"))
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-KyPostDemo"] + extraArguments
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

    @discardableResult
    private func tap(_ element: XCUIElement, timeout: TimeInterval = 4) -> Bool {
        guard element.waitForExistence(timeout: timeout), element.isHittable else { return false }
        element.tap()
        Thread.sleep(forTimeInterval: 0.8)
        return true
    }

    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let bar = app.tabBars.buttons[name]
        return bar.waitForExistence(timeout: 2) ? bar : app.buttons[name].firstMatch
    }

    private func row(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)
        let button = app.buttons.matching(predicate).firstMatch
        return button.waitForExistence(timeout: 3) ? button : app.cells.matching(predicate).firstMatch
    }

    /// Inbox, Settings → Theme, then a message beside or over the list.
    @MainActor
    func testCaptureThemeScreens() {
        let app = launch()
        shot("main")
        if tap(tab(app, "Settings")) {
            var theme = row(app, "Theme")
            if !theme.waitForExistence(timeout: 3) || !theme.isHittable {
                app.swipeUp()
                theme = row(app, "Theme")
            }
            if tap(theme) { shot("theme-settings") }
        }
        if tap(tab(app, "Inbox")), tap(row(app, "Key rotation")) { shot("reader") }
        app.terminate()
    }
}
#endif
