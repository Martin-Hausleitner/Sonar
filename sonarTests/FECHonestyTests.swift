@testable import Sonar
import XCTest

final class FECHonestyTests: XCTestCase {
    func testStartSessionIntentQueuesUntilOnboardingIsComplete() {
        let decision = StartSessionIntentRouter.decision(
            onboarded: false,
            profileID: "festival"
        )

        XCTAssertEqual(decision.action, .queueUntilOnboarded)
        XCTAssertEqual(decision.profileID, "festival")
    }

    func testStartSessionIntentDispatchesOnlyAfterOnboarding() {
        let decision = StartSessionIntentRouter.decision(
            onboarded: true,
            profileID: "zimmer"
        )

        XCTAssertEqual(decision.action, .dispatchToMountedSession)
        XCTAssertEqual(decision.profileID, "zimmer")
    }

    func testSettingsViewDoesNotExposeUnsupportedFECToggle() throws {
        let source = try readSourceFile("sonar/UI/SettingsView.swift")

        XCTAssertFalse(source.contains("sonar.settings.fecEnabled"))
        XCTAssertFalse(source.contains("Vorwärtsfehlerkorrektur"))
    }

    func testSessionCoordinatorDoesNotWriteUnsupportedEncoderFECFlag() throws {
        let source = try readSourceFile("sonar/Core/Coordinator/SessionCoordinator.swift")

        XCTAssertFalse(source.contains("encoder.fecEnabled"))
    }

    func testReadmeDoesNotAdvertiseUnsupportedFEC() throws {
        let source = try readSourceFile("README.md")

        XCTAssertFalse(source.contains("FEC optional"))
        XCTAssertFalse(source.contains("Fehlerkorr."))
        XCTAssertFalse(source.contains("Forward Error Correction):** Sendet redundante Pakete"))
        XCTAssertFalse(source.contains("Sprach-Codec, FEC"))
        XCTAssertFalse(source.contains("Encode / Decode / FEC"))
        XCTAssertTrue(source.contains("Apples Opus-Encoder stellt keine steuerbare Fehlerkorrektur bereit."))
    }

    func testLatencyBudgetDoesNotExposeUnsupportedFECConstants() throws {
        let source = try readSourceFile("sonar/Core/Utilities/LatencyBudget.swift")

        XCTAssertFalse(source.contains("opusFECEnabledNear"))
        XCTAssertFalse(source.contains("opusFECEnabledFar"))
        XCTAssertTrue(source.contains("opusForwardErrorCorrectionSupported: Bool = false"))
    }

    func testLatencyDocumentDoesNotClaimFarModeEnablesOpusFEC() throws {
        let source = try readSourceFile("LATENCY.md")

        XCTAssertFalse(source.contains("Aktivieren wir nur im Far-Mode, nicht Near."))
        XCTAssertFalse(source.contains("kostet 2–4 ms encode-Latency\n  zugunsten Loss-Resilience"))
        XCTAssertFalse(source.contains("kostet 2-4 ms encode-Latency\n  zugunsten Loss-Resilience"))
        XCTAssertTrue(source.contains("keine kontrollierbare FEC"))
        XCTAssertTrue(source.contains("Far mode"))
        XCTAssertTrue(source.contains("Jitter/Transport/Packet-Loss-Handling"))
    }

    func testSessionViewCommentsDoNotClaimProfilesReapplyUnsupportedFEC() throws {
        let source = try readSourceFile("sonar/UI/SessionView.swift")

        XCTAssertFalse(source.contains("ANC / music / FEC"))
        XCTAssertFalse(source.contains("FEC settings live"))
        XCTAssertFalse(source.contains("re-applies ANC"))
        XCTAssertFalse(source.contains("re-applies FEC"))
    }

    func testAirPodsCopyDoesNotClaimDirectNoiseControl() throws {
        let controller = try readSourceFile("sonar/Core/AirPods/AirPodsController.swift")
        let coordinator = try readSourceFile("sonar/Core/Coordinator/SessionCoordinator.swift")
        let settings = try readSourceFile("sonar/UI/SettingsView.swift")

        XCTAssertFalse(controller.contains("Set Noise Control Mode"))
        XCTAssertFalse(controller.contains("SetListeningModeIntent"))
        XCTAssertFalse(controller.contains(".sonarSetListeningMode"))
        XCTAssertFalse(coordinator.contains("ANC / transparency mode for AirPods."))
        XCTAssertFalse(settings.contains("passt Rauschunterdrückung"))
        XCTAssertTrue(controller.contains("best-effort"))
        XCTAssertTrue(settings.contains("fragt AirPods-Hörpräferenzen best-effort an"))
    }

    func testSetListeningModeIntentCopyDescribesBestEffortRequest() throws {
        let source = try readSourceFile("sonar/App/AppIntents/SetListeningModeIntent.swift")

        XCTAssertFalse(source.contains("\"AirPods Listening Mode setzen\""))
        XCTAssertFalse(source.contains("@Parameter(title: \"Mode\")"))
        XCTAssertFalse(source.contains("return .result()"))
        XCTAssertTrue(source.contains("AirPods Hörpräferenz anfragen"))
        XCTAssertTrue(source.contains("best-effort"))
        XCTAssertTrue(source.contains("iOS und AirPods entscheiden"))
        XCTAssertTrue(source.contains("@Parameter(title: \"Gewünschte Hörpräferenz\")"))
        XCTAssertTrue(source.contains("return .result("))
        XCTAssertTrue(source.contains("dialog:"))
    }

    func testMusicCopyDescribesSystemDuckingRequestNotPreciseAppleMusicMixing() throws {
        let picker = try readSourceFile("sonar/UI/ProfilePickerView.swift")
        let infoPlist = try readSourceFile("sonar/Resources/Info.plist")
        let sideStore = try readSourceFile("apps.json")

        XCTAssertFalse(picker.contains("% beibehalten"))
        XCTAssertFalse(picker.contains("Apple Music läuft im Hintergrund weiter, gedimmt auf diesen Pegel"))
        XCTAssertFalse(infoPlist.contains("mischt Musik aus deiner Apple-Music-Bibliothek"))
        XCTAssertFalse(sideStore.contains("mischt Musik aus deiner Apple-Music-Bibliothek"))
        XCTAssertTrue(picker.contains("System-Ducking angefragt"))
        XCTAssertTrue(infoPlist.contains("bittet iOS"))
        XCTAssertTrue(sideStore.contains("bittet iOS"))
    }

    func testProfileNearFarCopyDescribesBestAvailableFallbackPath() throws {
        let picker = try readSourceFile("sonar/UI/ProfilePickerView.swift")

        XCTAssertFalse(picker.contains("auf das Internet-Relay"))
        XCTAssertTrue(picker.contains("besten aktuell verfügbaren Verbindungspfad"))
        XCTAssertTrue(picker.contains("Fallback"))
    }

    func testE2EPlanKeepsAirPodsAndDuckingClaimsObservableBestEffort() throws {
        let source = try readSourceFile("E2E_TESTPLAN.md")

        XCTAssertFalse(source.contains("AirPods schalten von ANC auf Transparency"))
        XCTAssertFalse(source.contains("ANC stark gedämpft"))
        XCTAssertFalse(source.contains("Apple-Music-Track läuft im Hintergrund auf -18 dB"))
        XCTAssertFalse(source.contains("dipt Musik kurz auf -24 dB"))
        XCTAssertTrue(source.contains("best-effort"))
        XCTAssertTrue(source.contains("hardware-observable"))
        XCTAssertTrue(source.contains("report-only"))
    }

    func testLatencyDocsMatchTenMillisecondFramesAndThirtyTwoKbpsOpus() throws {
        let latency = try readSourceFile("LATENCY.md")
        let readme = try readSourceFile("README.md")

        XCTAssertTrue(latency.contains("| `opusBitrate` | 32_000 | OpusCoder |"))
        XCTAssertFalse(latency.contains("| `opusBitrate` | 24_000 | OpusCoder |"))
        XCTAssertFalse(latency.contains("fix 24 kbps"))

        XCTAssertTrue(readme.contains("Audio-Codec (32 kBit/s, 10-ms Frames)"))
        XCTAssertTrue(readme.contains("OpusCoder.encode<br/>10 ms · ~32 kBit/s"))
        XCTAssertTrue(readme.contains("⑤ Audio-Pfad — alle 10 ms, alle aktiven Pfade"))
        XCTAssertTrue(readme.contains("Opus-Encode (10 ms Frame)"))
        XCTAssertFalse(readme.contains("±20 ms Frames"))
        XCTAssertFalse(readme.contains("20 ms · ~32 kBit/s"))
        XCTAssertFalse(readme.contains("alle 20 ms, alle aktiven Pfade"))
        XCTAssertFalse(readme.contains("Opus-Encode (20 ms Frame)"))
    }

    func testAppTargetDoesNotClaimUnwiredLiveActivityPresentation() throws {
        let source = try readSourceFile("sonar/UI/Components/SonarLiveActivity.swift")
        let infoPlist = try readSourceFile("sonar/Resources/Info.plist")

        XCTAssertFalse(source.contains("struct SonarLiveActivityView: Widget"))
        XCTAssertFalse(source.contains("DynamicIsland"))
        XCTAssertFalse(infoPlist.contains("NSSupportsLiveActivities"))
    }

    func testSideStoreDescriptionDoesNotOverpromiseAutomaticConnection() throws {
        let source = try readSourceFile("apps.json")

        XCTAssertFalse(source.contains("die Verbindung baut sich automatisch auf"))
        XCTAssertFalse(source.contains("LiveKit WebRTC — Cloud Audio Relay, global"))
    }

    private func readSourceFile(_ relativePath: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            let candidate = url.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw NSError(
            domain: "FECHonestyTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate \(relativePath) from \(#filePath)"]
        )
    }
}
