import XCTest
@testable import Sonar

final class DeviceCapabilitiesTests: XCTestCase {

    // MARK: - sonarTier derivation

    func testTierAForGen2UWB() {
        let caps = DeviceCapabilities(hasUWB: true, uwbGen: .gen2,
                                      hasNeuralEngine: true, supportsSpatialAudio: true)
        XCTAssertEqual(caps.sonarTier, .a, "U2 chip (iPhone 17 Pro) must be tier A")
    }

    func testTierBForGen1UWB() {
        let caps = DeviceCapabilities(hasUWB: true, uwbGen: .gen1,
                                      hasNeuralEngine: true, supportsSpatialAudio: true)
        XCTAssertEqual(caps.sonarTier, .b, "U1 chip (iPhone 14-16) must be tier B")
    }

    func testTierCForNoUWB() {
        let caps = DeviceCapabilities(hasUWB: false, uwbGen: nil,
                                      hasNeuralEngine: false, supportsSpatialAudio: false)
        XCTAssertEqual(caps.sonarTier, .c, "No UWB must be tier C")
    }

    func testTierCWhenUWBTrueButGenNil() {
        // hasUWB true but uwbGen nil is inconsistent; sonarTier falls through to .c
        let caps = DeviceCapabilities(hasUWB: true, uwbGen: nil,
                                      hasNeuralEngine: true, supportsSpatialAudio: false)
        XCTAssertEqual(caps.sonarTier, .c)
    }

    // MARK: - Gen2 takes priority over gen1 in switch

    func testGen2AlwaysBeatsGen1InTierLogic() {
        let gen2 = DeviceCapabilities(hasUWB: true, uwbGen: .gen2,
                                      hasNeuralEngine: true, supportsSpatialAudio: true)
        let gen1 = DeviceCapabilities(hasUWB: true, uwbGen: .gen1,
                                      hasNeuralEngine: true, supportsSpatialAudio: true)
        XCTAssertEqual(gen2.sonarTier, .a)
        XCTAssertEqual(gen1.sonarTier, .b)
        XCTAssertNotEqual(gen2.sonarTier, gen1.sonarTier)
    }

    // MARK: - hasUWB matches uwbGen presence

    func testHasUWBAndGenAreConsistent() {
        let caps = DeviceCapabilities.detect()
        if caps.hasUWB {
            XCTAssertNotNil(caps.uwbGen, "hasUWB=true should imply a non-nil uwbGen")
        } else {
            XCTAssertNil(caps.uwbGen, "hasUWB=false should imply nil uwbGen")
        }
    }

    // MARK: - detect() internal consistency (hardware-independent)

    func testDetectDoesNotCrash() {
        // Must not crash. Beyond that, only invariants we can test without
        // knowing the actual hardware:
        let caps = DeviceCapabilities.detect()

        // If there's no UWB, there must be no gen
        if !caps.hasUWB {
            XCTAssertNil(caps.uwbGen)
            XCTAssertEqual(caps.sonarTier, .c)
        } else {
            // UWB present → gen must be set → tier A or B
            XCTAssertNotNil(caps.uwbGen)
            XCTAssertNotEqual(caps.sonarTier, .c)
        }
    }

    func testDetectTierMatchesGenConsistently() {
        let caps = DeviceCapabilities.detect()
        switch caps.uwbGen {
        case .gen2: XCTAssertEqual(caps.sonarTier, .a)
        case .gen1: XCTAssertEqual(caps.sonarTier, .b)
        case nil:   XCTAssertEqual(caps.sonarTier, .c)
        }
    }
}
