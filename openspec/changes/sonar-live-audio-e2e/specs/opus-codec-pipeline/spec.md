## ADDED Requirements

### Requirement: Opus encode failures are observable, not silently dropped
The system SHALL NOT silently discard captured microphone frames on Opus
encode failure. The capture chain in `SessionCoordinator` SHALL replace the
error-swallowing `try? encoder.encode(buffer)` pattern with explicit error
handling that logs the failure (e.g. via `os.Logger`) and increments a
metrics counter, so encode failures are diagnosable instead of invisible.

#### Scenario: Encode fails due to format mismatch
- **WHEN** `OpusCoder.encode(_:)` throws because the input buffer's format
  does not match the encoder's expected PCM format
- **THEN** the failure is logged with enough detail to diagnose it (e.g.
  expected vs. actual format/sample rate) and a metrics counter is
  incremented, instead of the frame being silently dropped with no trace

### Requirement: Mic-tap buffer format matches the Opus encoder's expected format
The system SHALL ensure the `AVAudioPCMBuffer` format installed on the input
node tap in `AudioEngine.prepare()` is reconciled with the format
`OpusCoder` is constructed to encode (sample rate, channel count, frame
size), either by converting the tap's native hardware format to the
encoder's expected format before encoding, or by constructing the encoder to
match the tap's actual negotiated format.

#### Scenario: Hardware input format differs from encoder's configured format
- **WHEN** `engine.inputNode.inputFormat(forBus: 0)` differs from the
  `OpusCoder`'s configured `pcmFormat` (e.g. different sample rate or
  channel count)
- **THEN** captured audio is still successfully encoded (via conversion or
  matched configuration) rather than failing every encode call

#### Scenario: Unit test covers real mic-tap format round-trip
- **WHEN** `OpusCoderTests` (or equivalent) encodes a buffer created with the
  same format `AudioEngine.prepare()` installs on the input tap
- **THEN** `encode(_:)` succeeds and the resulting data can be decoded back
  via `decode(_:into:)` without error
