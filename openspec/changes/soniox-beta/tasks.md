## 1. Session governor

- [ ] 1.1 Add `sonar/Core/Transcription/SonioxSessionGovernor.swift` with a
      `streaming → silentCountdown → suspended → resuming` state machine and
      an injected clock (`() -> TimeInterval`) so tests are deterministic.
- [ ] 1.2 Detect voice activity on the 16 kHz PCM frames the transcriber
      already produces, using RMS with hysteresis and the same thresholds as
      `sonar/Core/AI/VAD.swift` (on 0.018 / off 0.010).
- [ ] 1.3 Add a bounded pre-roll ring buffer (default 1.0 s of capture audio)
      that is drained into the first send of a resumed session.
- [ ] 1.4 Emit explicit `SonioxSessionGovernor.Decision` values
      (`send`, `hold`, `suspend`, `resume`) so the transcriber contains no
      duplicated policy logic.

## 2. Transcriber integration

- [ ] 2.1 Route every appended buffer through the governor in
      `SonioxRealtimeTranscriber` and only send when the decision allows it.
- [ ] 2.2 Implement suspend through the existing empty-frame terminator path
      (`finish()`'s terminator + close), sent exactly once per suspend.
- [ ] 2.3 Implement resume through the existing connect path (temporary-key
      broker + `startSocket`), reusing — not duplicating — the existing
      reconnect/backoff logic.
- [ ] 2.4 Ensure `abort()` (Privacy Mode) wins in every governor state and
      discards the pre-roll buffer.

## 3. Quality metrics

- [ ] 3.1 Add `SonioxQualityMetrics` with sessions started/ended-by-cause,
      streamed vs. suppressed seconds, first-token latency EMA, final-token
      ratio, reconnects, last redacted error, and speaker count.
- [ ] 3.2 Maintain the metrics inside `SonioxRealtimeTranscriber` under its
      existing lock and expose them via a getter plus an update callback.
- [ ] 3.3 Publish the metrics from `LiveTranscriptionEngine`
      (`@Published private(set) var sonioxMetrics`) and reset them on
      `start()`/`stop()`.

## 4. Configuration

- [ ] 4.1 Extend `SonioxConfiguration` with `silenceStopSeconds`
      (`SONAR_SONIOX_SILENCE_STOP_SEC` / `sonar.soniox.silenceStopSec`,
      default 120), `preRollSeconds` (default 1.0) and the VAD thresholds,
      using the existing resolution order.
- [ ] 4.2 A non-positive silence threshold disables suspension (always-on
      streaming) so the feature can be switched off without a code change.

## 5. Tests

- [ ] 5.1 Governor: silence past the threshold yields `suspend`; speech
      before the threshold cancels the countdown.
- [ ] 5.2 Governor: speech while suspended yields `resume` and the pre-roll
      buffer is returned first, oldest sample first.
- [ ] 5.3 Governor: no `suspend` while speech is ongoing, and the pre-roll
      buffer stays bounded.
- [ ] 5.4 Transcriber/metrics: streamed vs. suppressed seconds, saving
      fraction, latency EMA, final-token ratio, end-cause attribution,
      redacted error, speaker count.
- [ ] 5.5 Suspend sends the terminator exactly once.
- [ ] 5.6 `swiftc -typecheck` against the real sources is clean, and
      SwiftLint/SwiftFormat pass.

## 6. Documentation

- [ ] 6.1 Write `docs/SONIOX-BETA-PLAN.md`: current state with file
      references, beta scope, quality definition with target values, open
      risks, milestones with progress bars.
