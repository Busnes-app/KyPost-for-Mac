//
//  ScreenshotTests.swift
//  KyPost UITests
//
//  Drives the DEBUG demo build (`-KyPostDemo`, see KyPost/App/DemoContent.swift)
//  through the screens the App Store listing needs and attaches a PNG of each
//  one. Not a correctness test: every step is best-effort, because a missing
//  control should cost one screenshot, not the whole run.
//
//  Pull the images out with:
//    xcrun xcresulttool export attachments --path <result>.xcresult \
//      --output-path <dir>
//
//  Skipped unless KYPOST_SCREENSHOTS=1 is in the environment, so an ordinary
//  `xcodebuild test` never runs it. `scripts/capture-screenshots.sh` sets it.
//

import XCTest

final class ScreenshotTests: XCTestCase {

    override func setUpWithError() throws {
        // Opt-in: this is a capture run, not a check, and on macOS it needs
        // UI automation enabled. `xcodebuild test` must not start failing
        // for a machine that never asked for screenshots.
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KYPOST_SCREENSHOTS"] == "1",
            "Set KYPOST_SCREENSHOTS=1 (scripts/capture-screenshots.sh) to capture."
        )
        continueAfterFailure = true
    }

    // MARK: - Capture

    /// Attaches the app's own window and nothing else. There is deliberately
    /// no whole-display fallback: on macOS the display carries whatever else
    /// is open, and those images are exported with the listing. No window
    /// (or an app that is not in the foreground) costs that one screenshot.
    /// Returns whether an attachment was added.
    @discardableResult
    private func capture(_ app: XCUIApplication, _ name: String) -> Bool {
        guard app.state == .runningForeground else {
            XCTContext.runActivity(named: "\(name): app not in the foreground, not captured") { _ in }
            return false
        }
        let screenshot: XCUIScreenshot
#if os(macOS)
        let window = app.windows.firstMatch
        guard window.exists else {
            XCTContext.runActivity(named: "\(name): no app window, not captured") { _ in }
            return false
        }
        screenshot = window.screenshot()
#else
        // The Simulator's screen holds only the app under test, and the
        // listing wants the status bar the window excludes.
        screenshot = XCUIScreen.main.screenshot()
#endif
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return true
    }

    /// Regression: a capture without an app window must attach nothing,
    /// rather than falling back to the whole display.
    @MainActor
    func testCaptureWithoutAnAppWindowAttachesNothing() {
        let absent = XCUIApplication(bundleIdentifier: "org.kysecurity.mail.screenshot-tests.absent")
        XCTAssertFalse(capture(absent, "absent"))
    }

    private func launchDemo(screen: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-KyPostDemo"]
        if let screen {
            app.launchArguments += ["-KyPostDemoScreen", screen]
        }
        app.launch()
        // The inbox arrives through a refresh; the demo source answers
        // immediately but SwiftUI still needs a frame or two to settle.
        // A launch that never reached the foreground has nothing to capture.
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 10),
            "The demo build did not reach the foreground"
        )
        settle(2)
        dismissSystemAlerts()
        return app
    }

    /// The notification-permission alert belongs to Springboard, not the app,
    /// so it does not appear in `app.alerts` — and it sits over the first
    /// screenshot and swallows the first tap.
    private func dismissSystemAlerts() {
#if os(iOS)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 3) else { return }
            let allow = alert.buttons["Allow"]
            let deny = alert.buttons["Don't Allow"]
            if allow.exists { allow.tap() } else if deny.exists { deny.tap() } else { return }
            settle()
        }
#endif
    }

    /// First button or cell whose label contains `text` — List rows read as
    /// "Theme, Busnes Light", so an exact-match query never finds them.
    private func row(in app: XCUIApplication, containing text: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)
        let button = app.buttons.matching(predicate).firstMatch
        return button.exists ? button : app.cells.matching(predicate).firstMatch
    }

    /// Plain sleep on purpose: there is no state to wait on, only SwiftUI
    /// animation, and an unfulfilled XCTestExpectation would fail the run.
    private func settle(_ seconds: TimeInterval = 1) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Taps `element` if it showed up in time. Returns whether it did, so a
    /// caller can skip the screenshot that depended on it.
    @discardableResult
    private func tapIfPresent(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        guard element.waitForExistence(timeout: timeout), element.isHittable else { return false }
        element.tap()
        settle()
        return true
    }

    // MARK: - iOS

#if os(iOS)

    @MainActor
    func testCaptureScreenshots() throws {
        let app = launchDemo()

        // 1. Your inbox, at a glance
        capture(app, "01-inbox")

        // 2. Organize mail with custom tabs — the keyword chips above the list.
        // Chips are alphabetical, so Finance is on screen without scrolling.
        // The chip's label carries its count ("Finance, 2"), so match loosely.
        if tapIfPresent(row(in: app, containing: "Finance")) {
            capture(app, "02-keyword-tabs")
            tapIfPresent(row(in: app, containing: "All"))
        }

        // 3. Read messages in a focused view — the rail ticket, which carries
        // no OpenPGP chrome, so the reading layout is what shows. Pick rows by
        // subject, not by index: adding a demo message renumbers the list and
        // the shot silently becomes a different screen.
        if tapIfPresent(row(in: app, containing: "Your ticket")) {
            capture(app, "03-read-message")
            tapIfPresent(app.navigationBars.buttons.element(boundBy: 0))
        }

        // 5. Know how every message was protected — the encrypted, signed and
        // verified message at the top of the list.
        if tapIfPresent(row(in: app, containing: "Q3 rollout")) {
            capture(app, "05-message-protection")
            tapIfPresent(app.navigationBars.buttons.element(boundBy: 0))
        }

        // 4. Compose with encryption and signing
        if tapIfPresent(app.buttons["Compose"]) {
            fillCompose(app)
            capture(app, "04-compose")
            tapIfPresent(app.buttons["Cancel"])
            tapIfPresent(app.buttons["Discard"], timeout: 2)
        }

        // 6. Keep contacts synchronized
        if tapIfPresent(app.tabBars.buttons["Contacts"]) {
            capture(app, "06-contacts")
        }

        // 8. Make KyPost yours with 17 themes
        if tapIfPresent(app.tabBars.buttons["Settings"]) {
            capture(app, "07-settings")
            if tapIfPresent(row(in: app, containing: "Theme")) {
                capture(app, "08-themes")
            }
        }

        app.terminate()

        // 7. Approve MFA requests securely — no route reaches this without a
        // server, so the demo build presents it on launch instead.
        let mfa = launchDemo(screen: "mfa")
        capture(mfa, "09-mfa-approval")
        mfa.terminate()
    }

#endif

    // MARK: - macOS

#if os(macOS)

    @MainActor
    func testCaptureScreenshots() throws {
        let app = launchDemo()
        let window = app.windows.firstMatch

        // 1. Your inbox, at a glance — sidebar, list and preview together
        capture(app, "01-inbox")

        // 2. Organize mail with custom tabs — sidebar keyword filters
        if tapIfPresent(window.outlines.staticTexts["Work"])
            || tapIfPresent(window.staticTexts["Work"]) {
            capture(app, "02-keyword-tabs")
            tapIfPresent(window.staticTexts["Inbox"])
        }

        // 3/5. Reading, and the protection chrome above the body.
        let firstRow = window.tables.cells.element(boundBy: 0)
        let firstOutlineRow = window.outlineRows.element(boundBy: 0)
        if tapIfPresent(firstRow, timeout: 3) || tapIfPresent(firstOutlineRow, timeout: 3) {
            capture(app, "03-read-message")
            capture(app, "05-message-protection")
        }

        // 4. Compose with encryption and signing (⌘N opens its own window)
        app.typeKey("n", modifierFlags: .command)
        settle(2)
        let compose = app.windows["New Email"]
        if compose.waitForExistence(timeout: 5) {
            fillCompose(app)
            let attachment = XCTAttachment(screenshot: compose.screenshot())
            attachment.name = "04-compose"
            attachment.lifetime = .keepAlways
            add(attachment)
            compose.typeKey("w", modifierFlags: .command)
            settle()
        }

        // 6. Keep contacts synchronized
        if tapIfPresent(window.staticTexts["Contacts"]) {
            capture(app, "06-contacts")
        }

        // 8. Make KyPost yours with 17 themes — Preferences ⌘, → Appearance
        app.typeKey(",", modifierFlags: .command)
        settle(2)
        let preferences = app.windows.element(boundBy: 1)
        if preferences.waitForExistence(timeout: 5) {
            tapIfPresent(preferences.buttons["Appearance"])
            let attachment = XCTAttachment(screenshot: preferences.screenshot())
            attachment.name = "08-themes"
            attachment.lifetime = .keepAlways
            add(attachment)
            preferences.typeKey("w", modifierFlags: .command)
            settle()
        }

        app.terminate()

        // 7. Approve MFA requests securely
        let mfa = launchDemo(screen: "mfa")
        capture(mfa, "09-mfa-approval")
        mfa.terminate()
    }

#endif

    // MARK: - Compose

    /// An empty compose window says nothing about composing. Fills enough that
    /// the Encrypt/Sign controls sit above real content.
    private func fillCompose(_ app: XCUIApplication) {
        let fields = app.textFields
        if fields.count > 0 {
            let to = fields.element(boundBy: 0)
            if to.exists {
                to.tap()
                to.typeText("devon@northgatelabs.example")
                settle()
            }
        }
        // Subject is the fourth field (To, Cc, Bcc, Subject) and tapping it
        // also dismisses the recipient autocomplete.
        if fields.count > 3 {
            let subject = fields.element(boundBy: 3)
            if subject.exists {
                subject.tap()
                subject.typeText("Re: key rotation — confirmed")
                settle()
            }
        }
        let editor = app.textViews.firstMatch
        if editor.exists {
            editor.tap()
            editor.typeText(
                "Read your new fingerprint back to me on the call and I'll pin it. "
                + "Sending this one encrypted and signed."
            )
            settle()
        }
        // The caption is about encrypting and signing, so show them on.
        //
        // Tap the *inner* switch, not the labelled container. SwiftUI exposes
        // `Toggle("Encrypt", …)` as a Switch spanning the label and the
        // control with a gap between them, and the container's centre — where
        // XCUITest taps — lands in that gap and toggles nothing.
        for name in ["Encrypt", "Sign"] {
            let container = app.switches[name]
            guard container.waitForExistence(timeout: 3) else { continue }
            guard (container.value as? String) != "1" else { continue }
            let control = container.switches.firstMatch
            let target = control.exists ? control : container
            guard target.isHittable else { continue }
            target.tap()
            settle()
        }
    }
}
