import XCTest
import UIKit
import LocalAuthentication

final class WalletFlowUITests: XCTestCase {
    private let qaWallet = "UI flow wallet"

    @MainActor private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-wallet.interface.language", "en"]
        app.launch()
        return app
    }

    @MainActor func testOnboardingShowsRecoveryChoices() throws {
        let app = launch()
        let restore = app.buttons["vault.restore"]
        if !restore.waitForExistence(timeout: 2),
           ProcessInfo.processInfo.environment["XMR_UI_TEST_DISPOSABLE"] == "1",
           app.staticTexts[qaWallet].exists {
            app.buttons["Create or restore another wallet"].tap()
        }
        guard restore.waitForExistence(timeout: 5) else { throw XCTSkip("Use a disposable wallet or an empty test installation.") }
        capturePublicScreen("welcome", app: app)
        restore.tap()
        XCTAssertTrue(app.secureTextFields["Enter the words in order"].waitForExistence(timeout: 5))
        app.buttons["View-only"].tap()
        XCTAssertTrue(app.textFields["Monero address"].exists)
        XCTAssertTrue(app.secureTextFields["64 hexadecimal characters"].exists)
        app.buttons["Private keys"].tap()
        XCTAssertEqual(app.secureTextFields.matching(identifier: "64 hexadecimal characters").count, 2)
    }

    @MainActor func testRestoreLockAndWalletNavigation() throws {
        guard ProcessInfo.processInfo.environment["XMR_UI_TEST_DISPOSABLE"] == "1" else {
            throw XCTSkip("Opt in on a disposable simulator or isolated test installation with XMR_UI_TEST_DISPOSABLE=1.")
        }
        let app = launch()
        if app.buttons["Unlock wallet"].waitForExistence(timeout: 2), app.staticTexts[qaWallet].exists {
            try unlock(app)
        } else {
            guard app.buttons["vault.restore"].exists else { throw XCTSkip("Use a clean installation reserved for UI tests.") }
            var availabilityError: NSError?
            guard LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &availabilityError) else {
                throw XCTSkip("The simulator cannot authenticate a device owner.")
            }
            app.buttons["vault.restore"].tap()
            let name = app.textFields["Personal wallet"]
            name.tap()
            if let initial = name.value as? String, initial == "Restored wallet" {
                name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: initial.count))
            }
            name.typeText(qaWallet)
            app.buttons["View-only"].tap()
            let address = app.textFields["Monero address"]
            address.tap()
            // Both public keys are the standard Edwards base point. The test
            // imports the public scalar-one view fixture and has no spend key.
            address.typeText("44yQXfkWZNmJ8QgRfFWTzmJ8QgRfFWTzmJ8QgRfFWTzmJ7suhUXwdrDJ8QgRfFWTzmJ8QgRfFWTzmJ8QgRfFWTzmCYrSgjJ")
            let key = app.secureTextFields["64 hexadecimal characters"].firstMatch
            key.tap()
            UIPasteboard.general.setItems([["public.utf8-plain-text": "01" + String(repeating: "00", count: 31)]],
                                          options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(45)])
            key.press(forDuration: 1)
            let paste = app.descendants(matching: .any).matching(identifier: "Paste").firstMatch
            XCTAssertTrue(paste.waitForExistence(timeout: 5))
            paste.tap()
            let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
            if allow.waitForExistence(timeout: 2) { allow.tap() }
            let submit = app.buttons["Restore wallet"]
            scrollTo(submit, in: app)
            submit.tap()
            if app.secureTextFields["New app PIN"].waitForExistence(timeout: 10) {
                let pin = "615284"
                app.secureTextFields["New app PIN"].tap()
                app.secureTextFields["New app PIN"].typeText(pin)
                app.secureTextFields["Confirm new PIN"].tap()
                app.secureTextFields["Confirm new PIN"].typeText(pin)
                let save = app.buttons["Save app PIN"]
                scrollTo(save, in: app)
                save.tap()
            } else if app.secureTextFields["App PIN"].exists {
                try enterTestPIN(app)
            }
            let verify = app.buttons["I recognize this address"]
            try waitForAuthentication(then: verify, in: app)
            verify.tap()
        }

        // The first unlock offers a network choice. Closing it keeps the test offline.
        let done = app.buttons["Done"]
        if app.navigationBars["Node and sync settings"].waitForExistence(timeout: 3), done.exists { done.tap() }
        let node = app.buttons["Node and sync settings"].firstMatch
        XCTAssertTrue(node.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Overview"].waitForExistence(timeout: 5))
        if app.staticTexts["No transactions yet"].exists { capturePublicScreen("dashboard", app: app) }
        app.buttons["Receive"].tap()
        let amount = app.textFields["0.00"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        capturePublicScreen("receive", app: app)
        amount.tap()
        amount.typeText("1.25")
        XCTAssertTrue(app.buttons["Share"].exists)
        XCTAssertTrue(app.buttons["Copy"].exists)
        app.buttons["Close"].tap()
        app.buttons["Activity"].tap()
        XCTAssertTrue(app.textFields["Search hash, note or recipient"].waitForExistence(timeout: 5))
        let direction = app.segmentedControls.firstMatch
        XCTAssertTrue(direction.exists)
        direction.buttons["Received"].tap()
        direction.buttons["Sent"].tap()
        app.buttons["Wallet"].tap()
        app.buttons["Send"].tap()
        XCTAssertTrue(app.buttons["Scan from photo"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        node.tap()
        XCTAssertTrue(app.navigationBars["Node and sync settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["Tools"].tap()
        let pulse = app.buttons.containing(.staticText, identifier: "Privacy Pulse").firstMatch
        if pulse.exists { pulse.tap() } else { app.buttons["Privacy Pulse"].tap() }
        XCTAssertTrue(app.navigationBars["Privacy Pulse"].waitForExistence(timeout: 5))
        capturePublicScreen("privacy-pulse", app: app)
        let settingsBack = app.navigationBars["Privacy Pulse"].buttons.firstMatch
        XCTAssertTrue(settingsBack.isHittable)
        settingsBack.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let appearance = app.buttons["settings.appearance"]
        scrollTo(appearance, in: app)
        appearance.tap()
        app.buttons["Light"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "settings.appearance").matching(NSPredicate(format: "value == %@", "Light")).firstMatch.waitForExistence(timeout: 3))
        capturePublicScreen("settings-light", app: app)
        appearance.tap()
        app.buttons["Dark"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "settings.appearance").matching(NSPredicate(format: "value == %@", "Dark")).firstMatch.waitForExistence(timeout: 3))
        let lock = app.buttons["Lock wallet"]
        scrollTo(lock, in: app)
        lock.tap()
        XCTAssertTrue(app.buttons["Unlock wallet"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Send"].exists)
        try unlock(app)
        XCTAssertTrue(node.waitForExistence(timeout: 15))
    }

    @MainActor private func capturePublicScreen(_ name: String, app: XCUIApplication) {
        guard ProcessInfo.processInfo.environment["XMR_UI_SCREENSHOTS"] == "1",
              app.secureTextFields.count == 0 else { return }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 where !element.isHittable { app.swipeUp() }
    }

    @MainActor private func unlock(_ app: XCUIApplication) throws {
        app.buttons["Unlock wallet"].tap()
        try enterTestPIN(app)
    }

    @MainActor private func enterTestPIN(_ app: XCUIApplication) throws {
        let pin = app.secureTextFields["App PIN"]
        XCTAssertTrue(pin.waitForExistence(timeout: 10))
        pin.tap()
        pin.typeText("615284")
        let unlock = app.buttons["Unlock"].firstMatch
        scrollTo(unlock, in: app)
        unlock.tap()
    }

    @MainActor private func waitForAuthentication(then element: XCUIElement, in app: XCUIApplication) throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<20 {
            if element.exists && element.isHittable { return }
            let faceUsage = springboard.alerts.containing(NSPredicate(format: "label CONTAINS[c] 'Face ID'")).firstMatch
            if faceUsage.exists && faceUsage.buttons["Allow"].exists { faceUsage.buttons["Allow"].tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            #if targetEnvironment(simulator)
            // Simulator-only equivalent of Features > Face ID > Matching Face.
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName("com.apple.BiometricKit_Sim.fingerTouch.match" as CFString), nil, nil, true)
            #endif
        }
        let denied = app.staticTexts.containing(NSPredicate(format:
            "label CONTAINS[c] 'passcode is required' OR label CONTAINS[c] 'Set a device passcode'")).firstMatch
        if denied.exists { throw XCTSkip("The simulator requires a device passcode to enroll its protected Keychain item.") }
        let indicators = ["passcode", "Keychain", "PIN entries", "incorrect PIN", "authentication", "PIN format", "recover", "app PIN"]
        // Only emit predefined diagnostic categories. Never log the element tree,
        // editable values, addresses, or authentication data.
        var categories: [String] = []
        for category in indicators {
            let predicate = NSPredicate(format: "label CONTAINS[c] %@", category)
            if app.staticTexts.matching(predicate).firstMatch.exists { categories.append("app " + category) }
            if springboard.staticTexts.matching(predicate).firstMatch.exists { categories.append("system " + category) }
        }
        if categories.contains("system passcode") {
            throw XCTSkip("The system requires the simulator owner's device passcode to enroll the protected wallet.")
        }
        XCTFail("Address review did not appear. Visible authentication categories: " + categories.joined(separator: ", "))
    }
}
