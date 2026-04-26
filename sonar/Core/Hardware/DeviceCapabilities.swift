import AVFoundation
import Foundation
import NearbyInteraction

/// Detects hardware capabilities once at launch and derives the Sonar tier. §9.2.
struct DeviceCapabilities: Sendable {
    let hasUWB: Bool
    let uwbGen: UWBGen?
    let hasNeuralEngine: Bool
    let supportsSpatialAudio: Bool

    enum UWBGen: Sendable { case gen1, gen2 }

    enum SonarTier: Sendable {
        case a  // iPhone 17 Pro (U2) — full experience
        case b  // iPhone 14–16 (U1) — ~80%
        case c  // No UWB / older  — ~60%
    }

    var sonarTier: SonarTier {
        if uwbGen == .gen2 { return .a }
        if uwbGen == .gen1 { return .b }
        return .c
    }

    static func detect() -> DeviceCapabilities {
        let uwbSupported = NISession.deviceCapabilities.supportsDirectionMeasurement ||
                           NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
        let modelID = Self.modelIdentifier()
        let isU2Model = modelID.hasPrefix("iPhone17") || modelID.hasPrefix("iPhone18")
        let uwbGen: UWBGen? = uwbSupported ? (isU2Model ? .gen2 : .gen1) : nil
        let hasNE = uwbSupported || Self.hasNeuralEngineHeuristic()

        // Spatial Audio requires iPhone 14+ hardware. Parse the model number
        // so new generations (iPhone18, 19, ...) are automatically included.
        let spatialMinGeneration = 14
        let supportsSpatial: Bool = {
            guard let numStr = modelID
                .components(separatedBy: "iPhone").last?
                .components(separatedBy: ",").first,
                  let gen = Int(numStr) else { return false }
            return gen >= spatialMinGeneration
        }()

        return DeviceCapabilities(
            hasUWB: uwbSupported,
            uwbGen: uwbGen,
            hasNeuralEngine: hasNE,
            supportsSpatialAudio: supportsSpatial
        )
    }

    private static func modelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }

    private static func hasNeuralEngineHeuristic() -> Bool {
        return AVAudioSession.sharedInstance().availableInputs?.isEmpty == false
    }
}
