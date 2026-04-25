import Darwin
import Foundation

/// High-resolution per-stage timing. Plan §11 + LATENCY.md.
///
/// Uses `mach_absolute_time()` which has nanosecond resolution on Apple
/// silicon. Deliberately *not* `Date()` (millisecond res) nor
/// `CFAbsoluteTimeGetCurrent()` (sub-ms but with NTP slew).
///
/// Mutation is serialised through an `NSLock` — we're a logging sink, not on
/// the audio render thread, so the extra ~50 ns vs `os_unfair_lock` doesn't
/// matter and the API is much safer to hold across class properties.
final class Metrics: @unchecked Sendable {
    static let shared = Metrics()

    /// Stages in the audio pipeline. Each Frame gets a Trace with timestamps
    /// per stage, then the trace is closed and the durations are recorded.
    enum Stage: String, Sendable, CaseIterable {
        case captured        // mic -> AVAudioEngine tap
        case encoded         // PCM -> Opus bytes
        case sentOnWire      // bytes handed to MPC stream / LiveKit
        case receivedOnWire  // bytes pulled out of MPC / LiveKit
        case decoded         // Opus -> PCM
        case rendered        // PCM -> AVAudio output
    }

    struct Trace: Sendable {
        let frameID: UInt64
        var stamps: [Stage: UInt64] = [:]   // mach_absolute_time ticks

        mutating func mark(_ stage: Stage) {
            stamps[stage] = mach_absolute_time()
        }

        /// Elapsed milliseconds from one stage to another.
        func elapsedMs(_ from: Stage, _ to: Stage) -> Double? {
            guard let a = stamps[from], let b = stamps[to], b >= a else { return nil }
            return Self.ticksToMs(b - a)
        }

        /// Total glass-to-glass: capture → render. Returns nil if either
        /// missing (e.g. local-only echo of own voice).
        var glassToGlassMs: Double? { elapsedMs(.captured, .rendered) }

        /// `mach_timebase_info` cached once.
        private static let timebase: mach_timebase_info_data_t = {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            return info
        }()

        static func ticksToMs(_ ticks: UInt64) -> Double {
            let nanos = ticks &* UInt64(timebase.numer) / UInt64(timebase.denom)
            return Double(nanos) / 1_000_000.0
        }
    }

    private let lock = NSLock()
    private var traces: [Trace] = []
    private var nextID: UInt64 = 0
    private let capacity = 500

    func openTrace() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        nextID &+= 1
        return nextID
    }

    func mark(_ frameID: UInt64, _ stage: Stage) {
        lock.lock(); defer { lock.unlock() }
        if let i = traces.firstIndex(where: { $0.frameID == frameID }) {
            traces[i].mark(stage)
        } else {
            var t = Trace(frameID: frameID)
            t.mark(stage)
            traces.append(t)
            if traces.count > capacity {
                traces.removeFirst(traces.count - capacity)
            }
        }
    }

    func snapshot() -> [Trace] {
        lock.lock(); defer { lock.unlock() }
        return traces
    }

    /// P50, P95, P99 over recent traces for a given stage-pair.
    func percentiles(_ from: Stage, _ to: Stage) -> (p50: Double, p95: Double, p99: Double)? {
        let elapsed = snapshot().compactMap { $0.elapsedMs(from, to) }.sorted()
        guard !elapsed.isEmpty else { return nil }
        func pct(_ p: Double) -> Double {
            let i = max(0, min(elapsed.count - 1, Int(Double(elapsed.count - 1) * p)))
            return elapsed[i]
        }
        return (pct(0.50), pct(0.95), pct(0.99))
    }
}
