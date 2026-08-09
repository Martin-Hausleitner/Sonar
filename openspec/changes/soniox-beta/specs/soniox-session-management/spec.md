## ADDED Requirements

### Requirement: Soniox streaming suspends after sustained silence
The Soniox realtime engine SHALL stop streaming audio and close its WebSocket
session after a configurable period during which no voice activity is
detected. The threshold SHALL default to 120 seconds and SHALL be
configurable via the `SONAR_SONIOX_SILENCE_STOP_SEC` environment variable or
the `sonar.soniox.silenceStopSec` `UserDefaults` key, following the existing
`SonioxConfiguration` resolution order (environment first, then
`UserDefaults`, then default).

#### Scenario: Silence beyond the threshold suspends the session
- **WHEN** the transcriber is streaming and no voice activity is detected for
  longer than the configured silence threshold
- **THEN** the session is closed using the existing empty-frame terminator
  path, no further audio frames are sent, and the engine enters the
  `suspended` state

#### Scenario: The terminator is sent exactly once per suspend
- **WHEN** a suspend is triggered and further silent audio keeps arriving
- **THEN** the empty-frame terminator is sent exactly once for that suspend,
  and no additional terminator or audio frame is sent while suspended

#### Scenario: Speech within the countdown cancels the suspend
- **WHEN** voice activity is detected after the silence countdown has started
  but before the threshold elapses
- **THEN** the countdown is cancelled, the engine stays in `streaming`, and no
  session is closed

#### Scenario: Silence threshold is configurable
- **WHEN** `SONAR_SONIOX_SILENCE_STOP_SEC` is set to a positive number of
  seconds
- **THEN** that value is used as the silence threshold instead of the 120 s
  default, and an unset/invalid value falls back to the default

### Requirement: Soniox streaming resumes seamlessly on renewed speech
The Soniox realtime engine SHALL start a new streaming session when voice
activity is detected while suspended. The resume SHALL be initiated within
one second of the detected speech onset and SHALL reuse the existing connect
path, including the temporary-key broker and the existing reconnect/backoff
logic, without duplicating that logic.

#### Scenario: Speech while suspended starts a new session
- **WHEN** the engine is `suspended` and voice activity is detected
- **THEN** the engine leaves `suspended`, requests a fresh credential through
  the existing key-resolution path, and opens a new WebSocket session

#### Scenario: Pre-roll audio is sent first after a resume
- **WHEN** a resume is triggered by speech onset
- **THEN** the audio buffered in the pre-roll ring buffer (approximately the
  last second before onset, configurable) is sent as the first audio of the
  new session, ahead of any newly captured audio, so the leading word is not
  lost

#### Scenario: No audio is sent while suspended
- **WHEN** the engine is `suspended` and silent audio buffers keep arriving
- **THEN** those buffers are retained only in the bounded pre-roll ring buffer
  and no bytes are sent over the network

#### Scenario: The transcript survives a suspend/resume cycle
- **WHEN** a suspend/resume cycle completes
- **THEN** transcript segments committed before the suspend remain in the
  transcript and are not duplicated by the resumed session

### Requirement: Privacy Mode still overrides session management
Suspend/resume behaviour SHALL NOT weaken the Privacy Mode kill switch. A
Privacy Mode activation SHALL terminate the Soniox engine in every governor
state, including `suspended` and `resuming`.

#### Scenario: Privacy Mode aborts a suspended engine
- **WHEN** Privacy Mode is activated while the engine is `suspended`
- **THEN** the engine is aborted, buffered pre-roll audio is discarded, no
  resume happens afterwards, and `LiveTranscriptionEngine` falls back to a
  non-cloud engine
