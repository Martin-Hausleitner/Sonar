import AVFoundation
@testable import Sonar
import XCTest

@MainActor
final class ProfileTests: XCTestCase {
    func testFiveBuiltInProfilesExist() {
        let ids = SessionProfile.builtIn.map(\.id)
        XCTAssertEqual(Set(ids), ["zimmer", "roller", "festival", "club", "zen"])
    }

    func testZimmerHasTransparency() throws {
        let zimmer = try XCTUnwrap(SessionProfile.builtIn.first { $0.id == "zimmer" })
        XCTAssertEqual(zimmer.listeningMode, "transparency")
        XCTAssertEqual(zimmer.musicMix, 0)
    }

    func testClubMixesMusic() throws {
        let club = try XCTUnwrap(SessionProfile.builtIn.first { $0.id == "club" })
        XCTAssertGreaterThan(club.musicMix, 0)
        XCTAssertEqual(club.listeningMode, "noiseCancellation")
        XCTAssertEqual(club.aiTrigger, .doubleTap)
    }

    func testThresholdsSane() {
        for p in SessionProfile.builtIn {
            XCTAssertLessThan(
                p.duplicateThreshold,
                p.nearFarThreshold,
                "\(p.id) duplicateThreshold must be < nearFarThreshold"
            )
            XCTAssertGreaterThan(p.gain, 0)
            XCTAssertLessThanOrEqual(p.gain, 1)
            XCTAssertGreaterThanOrEqual(p.musicMix, 0)
            XCTAssertLessThanOrEqual(p.musicMix, 1)
        }
    }

    func testJSONRoundtrip() throws {
        let original = SessionProfile.builtIn[0]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionProfile.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testProfileManagerStartsOnFirstProfile() {
        let mgr = ProfileManager()
        XCTAssertEqual(mgr.selected.id, SessionProfile.builtIn[0].id)
    }

    func testProfileManagerSelectByID() {
        let mgr = ProfileManager()
        mgr.select("club")
        XCTAssertEqual(mgr.selected.id, "club")
    }

    func testProfileManagerIgnoresUnknownID() {
        let mgr = ProfileManager()
        let before = mgr.selected.id
        mgr.select("does-not-exist")
        XCTAssertEqual(mgr.selected.id, before)
    }

    func testSpatialMixerAppliesProfileVoiceGainBeforeGlobalOutputVolume() {
        SpatialMixer.applyOutputVolume(1.0)
        let mixer = SpatialMixer()

        mixer.applyProfileVoiceGain(0.4)

        XCTAssertEqual(mixer.remotePlayerNode.volume, 0.4, accuracy: 0.0001)

        SpatialMixer.applyOutputVolume(0.5)

        let exp = expectation(description: "global output volume propagated")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(mixer.remotePlayerNode.volume, 0.2, accuracy: 0.0001)
    }

    func testAudioSessionPolicyPreservesDuckingWhenRawAudioIsReasserted() {
        var policy = AudioSessionPolicy(rawAudioMode: true)
        policy.musicDuckingEnabled = true

        XCTAssertEqual(policy.sessionMode, .default)
        XCTAssertFalse(policy.voiceProcessingEnabled)
        XCTAssertTrue(policy.categoryOptions.contains(.duckOthers))
        XCTAssertTrue(policy.categoryOptions.contains(.mixWithOthers))
        XCTAssertTrue(policy.categoryOptions.contains(.allowAirPlay))
    }

    func testAudioSessionPolicyPreservesAirPodsVoiceChatNudgeDuringRawAudioMode() {
        var policy = AudioSessionPolicy(rawAudioMode: true)
        policy.listeningModeNudge = .voiceChat
        policy.musicDuckingEnabled = true

        XCTAssertEqual(policy.sessionMode, .voiceChat)
        XCTAssertFalse(policy.voiceProcessingEnabled)
        XCTAssertTrue(policy.categoryOptions.contains(.duckOthers))
        XCTAssertTrue(policy.categoryOptions.contains(.mixWithOthers))
        XCTAssertTrue(policy.categoryOptions.contains(.allowAirPlay))
    }
}
