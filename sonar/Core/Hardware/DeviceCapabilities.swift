import AVFoundation
import Foundation
import NearbyInteraction

/// Detects hardware capabilities once at launch and derives the Sonar tier. §9.2.
struct DeviceCapabilities: Sendable {
    let hasUWB: Bool
    let uwbGen: UWBGen?
    let hasNeuralEngine: Bool   // A12 Bionic and later
    let supportsSpatialAudio: Bool

    enum UWBGen: Sendable { case gen1, gen2 }

    enum SonarTier: Sendable {
        case a  // iPhone 17 Pro (U2) — full experience
        case b  // iPhone 14-16 (U1) — ~80 %
        case c  // No UWB / older — ~60 %
    }

    var sonarTier: SonarTier {
        if uwbGen == .gen2 { return .a }
        if uwbGen == .gen1 { return .b }
        return .c
    }

    /// Detect from the current device.
    static func detect() -> DeviceCapabilities {
        let uwbSupported = NISession.deviceCapabilities.supportsDirectionMeasurement ||
                           NISession.deviceCapabilities.supportsPreciseDistanceMeasurement

        // U2 ships with iPhone 16 Pro and later (we can't distinguish U1/U2 at runtime via public API,
        // so we approximate: check model identifier against known U2 models).
        let modelID = Self.modelIdentifier()
        let isU2Model = modelID.hasPrefix("iPhone17") || modelID.hasPrefix("iPhone18")

        let uwbGen: UWBGen? = uwbSupported ? (isU2Model ? .gen2 : .gen1) : nil

        // Neural Engine: A12 Bionic (iPhone XS) and later. All devices that have UWB have NE.
        let hasNE = uwbSupported || Self.hasNeuralEngineHeuristic()

        // Spatial Audio requires AirPods Pro 2/3 + iPhone 14+; we can't detect AirPods model
        // at capabilities-detection time, so we use device model as a proxy.
        let supportsSpatial = !modelID.hasPrefix("iPhone1") || modelID.hasPrefix("iPhone14") ||
                               modelID.hasPrefix("iPhone15") || modelID.hasPrefix("iPhone16") ||
                               modelID.hasPrefix("iPhone17")

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
        // All iPhones since iPhone XS (2018) have the Neural Engine.
        // If the device supports VoiceProcessing it's at least A-series modern enough.
        return AVAudioSession.sharedInstance().availableInputs?.isEmpty == false
    }
}
