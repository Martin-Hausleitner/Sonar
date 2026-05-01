import XCTest

final class SonarUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-sonar.onboarded", "YES",
            "-sonar.seedRecording", "YES"
        ]
    }

    func testPrimarySessionButtonsMuteAndProfilePicker() throws {
        launchApp()

        XCTAssertTrue(app.buttons["Session starten"].waitForExistence(timeout: 6))
        app.buttons["Session starten"].tap()
        acceptSystemPermissionIfNeeded()

        XCTAssertTrue(app.buttons["Session beenden"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Mikrofon stummschalten"].waitForExistence(timeout: 4))
        app.buttons["Mikrofon stummschalten"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Mikrofon einschalten"].waitForExistence(timeout: 4))
        app.buttons["Mikrofon einschalten"].firstMatch.tap()

        XCTAssertTrue(app.buttons["Profil Zimmer (aktiv)"].waitForExistence(timeout: 4))
        app.buttons["Profil Roller"].tap()
        XCTAssertTrue(app.buttons["Profil Roller (aktiv)"].waitForExistence(timeout: 4))

        app.buttons["Session beenden"].tap()
        XCTAssertTrue(app.buttons["Session starten"].waitForExistence(timeout: 4))
    }

    func testTabsSettingsGuideAndPairingButtons() throws {
        launchApp()

        app.tabBars.buttons["Transkript"].tap()
        XCTAssertTrue(app.navigationBars["Transkript"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Noch kein Transkript"].waitForExistence(timeout: 4))

        app.tabBars.buttons["Aufnahmen"].tap()
        XCTAssertTrue(app.navigationBars["Aufnahmen"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 6))
        app.cells.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Wiedergabe"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["Abspielen"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.sliders["Aufnahme-Position"].waitForExistence(timeout: 4))
        attachScreenshot(named: "recording-player")
        app.buttons["Abspielen"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 4))
        app.buttons["Pause"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.tabBars.buttons["Session"].tap()
        XCTAssertTrue(app.buttons["Einstellungen öffnen"].waitForExistence(timeout: 4))
        app.buttons["Einstellungen öffnen"].tap()
        XCTAssertTrue(app.navigationBars["Einstellungen"].waitForExistence(timeout: 4))

        tapHittableButton("QR-Pairing")
        XCTAssertTrue(app.navigationBars["QR-Pairing"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["Code regenerieren"].waitForExistence(timeout: 4))
        app.buttons["Code regenerieren"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        tapHittableButton("Verbindung einrichten")
        XCTAssertTrue(app.navigationBars["Verbindung einrichten"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["QR-Pairing starten"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["AWDL / AirDrop-Kanal"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Bluetooth"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Lokales Netzwerk"].waitForExistence(timeout: 4))
        attachScreenshot(named: "connection-guide")
        app.buttons["QR-Pairing starten"].tap()
        XCTAssertTrue(app.navigationBars["QR-Pairing"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.descendants(matching: .any)["Pairing-QR-Code"].waitForExistence(timeout: 4))
        attachScreenshot(named: "guide-pairing-sheet")
        app.buttons["Fertig"].tap()
        XCTAssertTrue(app.navigationBars["Verbindung einrichten"].waitForExistence(timeout: 4))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        setSwitch("Vorwärtsfehlerkorrektur (FEC)", to: true)
        setSwitch("Privacy Mode", to: true)
        setSwitch("Demo-Modus", to: true)
        XCTAssertTrue(isSwitchOn(app.switches["Demo-Modus"]))
        setSwitch("Demo-Modus", to: false)

        app.buttons["Fertig"].tap()
        XCTAssertTrue(app.buttons["Verbinden — Pairing-Guide öffnen"].waitForExistence(timeout: 4))
        app.buttons["Verbinden — Pairing-Guide öffnen"].tap()
        XCTAssertTrue(app.navigationBars["Verbindung einrichten"].waitForExistence(timeout: 4))
        app.buttons["Fertig"].tap()
    }

    func testProfileDetailsPairingQRCodeAndAudioVolumeControls() throws {
        launchApp()

        XCTAssertTrue(app.buttons["Details zum aktiven Profil"].waitForExistence(timeout: 6))
        app.buttons["Details zum aktiven Profil"].tap()
        XCTAssertTrue(app.navigationBars["Profil-Details"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["AirPods-Modus"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Stimmen-Verstärkung"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["KI-Auslöser"].waitForExistence(timeout: 4))
        attachScreenshot(named: "profile-details")
        app.buttons["Fertig"].tap()

        XCTAssertTrue(app.buttons["Einstellungen öffnen"].waitForExistence(timeout: 4))
        app.buttons["Einstellungen öffnen"].tap()
        XCTAssertTrue(app.navigationBars["Einstellungen"].waitForExistence(timeout: 4))

        let volumeSlider = waitForHittableSlider("Sonar-Lautstärke")
        volumeSlider.adjust(toNormalizedSliderPosition: 0.62)
        attachScreenshot(named: "settings-audio-volume")

        tapHittableButton("QR-Pairing")
        XCTAssertTrue(app.navigationBars["QR-Pairing"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.descendants(matching: .any)["Pairing-QR-Code"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["Code regenerieren"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["Scannen"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["Anzeigen"].waitForExistence(timeout: 4))
        attachScreenshot(named: "pairing-qr-code")
        app.buttons["Scannen"].tap()
        acceptSystemPermissionIfNeeded()
        XCTAssertTrue(
            waitForAnyElement([
                app.descendants(matching: .any)["QR-Code-Scanner"],
                app.staticTexts["Kamerazugriff in Einstellungen erlauben."],
                app.staticTexts["Kameraberechtigung anfordern…"]
            ], timeout: 6),
            "Scanner tab should show either the live scanner, the permission prompt, or the denied camera state"
        )
        attachScreenshot(named: "pairing-scan-mode")
        app.buttons["Anzeigen"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["Pairing-QR-Code"].waitForExistence(timeout: 4))

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Fertig"].tap()
    }

    private func launchApp() {
        app.launch()
    }

    private func tapHittableButton(_ label: String, timeout: TimeInterval = 4, file: StaticString = #filePath, line: UInt = #line) {
        let buttons = app.buttons.matching(NSPredicate(format: "label == %@", label))
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            for index in 0..<buttons.count {
                let button = buttons.element(boundBy: index)
                if button.exists, button.isHittable {
                    button.tap()
                    return
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTFail("No hittable button named \(label)", file: file, line: line)
    }

    private func tapSwitch(_ label: String, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) {
        let toggle = waitForHittableSwitch(label, timeout: timeout, file: file, line: line)
        toggle.tap()
    }

    private func setSwitch(_ label: String, to enabled: Bool, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) {
        let toggle = waitForHittableSwitch(label, timeout: timeout, file: file, line: line)
        if isSwitchOn(toggle) != enabled {
            toggle.tap()
        }
    }

    private func waitForHittableSwitch(_ label: String, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let toggle = app.switches[label]
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if toggle.exists, toggle.isHittable {
                return toggle
            }
            app.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTFail("No hittable switch named \(label)", file: file, line: line)
        return toggle
    }

    private func waitForHittableSlider(_ label: String, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let slider = app.sliders[label]
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if slider.exists, slider.isHittable {
                return slider
            }
            app.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTFail("No hittable slider named \(label)", file: file, line: line)
        return slider
    }

    private func waitForAnyElement(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if elements.contains(where: { $0.exists }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return elements.contains(where: { $0.exists })
    }

    private func isSwitchOn(_ toggle: XCUIElement) -> Bool {
        if let number = toggle.value as? NSNumber {
            return number.boolValue
        }
        let normalized = String(describing: toggle.value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["1", "on", "ein", "true", "yes", "ja"].contains(normalized)
            || normalized.contains("optional(1")
            || normalized.contains("on")
            || normalized.contains("ein")
            || normalized.contains("true")
    }

    private func acceptSystemPermissionIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let candidates = [
            springboard.buttons["Erlauben"],
            springboard.buttons["OK"],
            springboard.buttons["Allow"],
            springboard.buttons["While Using App"]
        ]
        for button in candidates where button.waitForExistence(timeout: 1) {
            button.tap()
            return
        }
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
