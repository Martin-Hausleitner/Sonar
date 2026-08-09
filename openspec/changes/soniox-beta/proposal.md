## Why

The Soniox realtime engine landed in `sonar/Core/Transcription/SonioxRealtimeTranscriber.swift`
(commit `fee20f1`) and streams continuously for as long as a session is open.
Two concrete problems block calling it usable ("Beta"):

1. **Continuous streaming burns money and traffic during silence.**
   `SonioxRealtimeTranscriber.append(_:)` forwards *every* captured buffer to
   the WebSocket, 24/7, regardless of whether anyone is speaking. Soniox bills
   by streamed audio duration, and `stt-rt-v5` sessions are capped at
   `max_session_duration_seconds` (18 000 s in the lab's temporary-key
   request, see `soniox-route-lab/src/local-server.mjs`). A Sonar session that
   sits idle in a pocket for 20 minutes pays for 20 minutes of silence and can
   burn through the session cap before the conversation even starts. Neither
   the transcriber nor `LiveTranscriptionEngine` has any notion of "nobody is
   talking".

2. **Quality is asserted, not measured.** Nothing in the current code records
   how well Soniox performs: there is no latency measurement, no reconnect
   count exposed to the app, no record of how many tokens were finalized, and
   no way to answer "is this good enough to ship?" other than by watching the
   UI. `SonioxRealtimeTranscriber` logs errors to `os.Logger` and drops them.

This change closes both gaps and declares the result **Soniox Beta**: the
engine suspends itself during long silence, resumes seamlessly on speech, and
reports a quality/cost metric set that makes the "how good is it" question
answerable with numbers instead of opinions.

## What Changes

- **Add `SonioxSessionGovernor`** (`sonar/Core/Transcription/`): a
  deterministic, clock-injectable state machine
  (`streaming → silentCountdown → suspended → resuming`) driven by voice
  activity on the outgoing PCM frames. After a configurable silence duration
  (default 120 s) it orders a suspend; on the next speech it orders a resume.
- **Add a pre-roll ring buffer** (~1 s of capture audio) inside the governor
  so the resumed session replays the audio immediately preceding the detected
  speech onset — the first word of a returning conversation is not lost.
- **Suspend/resume reuse the existing transport paths** in
  `SonioxRealtimeTranscriber`: suspend goes through the established
  empty-frame terminator (`finish()`), resume through the established
  connect path including the temporary-key broker. The reconnect/backoff
  logic is not duplicated.
- **Add `SonioxQualityMetrics`**: sessions started/ended split by cause
  (silence vs. error vs. user), streamed vs. suppressed audio seconds (the
  concrete saving), first-token latency as an EMA, final-token ratio,
  reconnect count, last redacted error, and observed diarization speaker
  count. Maintained inside the transcriber, published by
  `LiveTranscriptionEngine` for UI/report consumption.
- **Extend `SonioxConfiguration`** with the silence threshold, pre-roll
  duration and VAD thresholds, using the existing ENV → `UserDefaults` →
  default resolution pattern.
- **Add unit tests** for the governor state machine (injected clock), the
  pre-roll buffer, and the metrics arithmetic — all without network.
- **Add `docs/SONIOX-BETA-PLAN.md`**: current state, beta scope, quality
  definition with target values, open risks, milestones.

## Non-goals

- No change to the audio capture chain (`sonar/Core/Audio/**`) or
  `SessionCoordinator` — the governor observes the buffers the transcriber
  already receives.
- No server-side/broker deployment work; the temporary-key broker contract
  stays as implemented.
- No translation channel, no speaker *naming* (only diarization IDs).
- No on-device verification in this change; that is tracked as an open risk.
