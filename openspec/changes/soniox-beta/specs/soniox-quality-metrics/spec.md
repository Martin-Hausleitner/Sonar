## ADDED Requirements

### Requirement: The Soniox engine records quality and cost metrics
The Soniox realtime engine SHALL maintain a metrics record covering at least:
sessions started, sessions ended split by cause (silence, error, user stop),
streamed audio seconds, suppressed silence seconds, first-token latency as an
exponential moving average, the ratio of final to total tokens, reconnect
count, the last error message in redacted form, and the number of distinct
diarization speakers observed.

#### Scenario: Streamed and suppressed audio are accounted separately
- **WHEN** audio is forwarded to Soniox and later suppressed during a
  suspended period
- **THEN** the forwarded duration increases `streamedAudioSeconds`, the
  suppressed duration increases `suppressedSilenceSeconds`, and the two are
  never counted in the same bucket

#### Scenario: Saving is derivable from the metrics
- **WHEN** the metrics are read after at least one suspend/resume cycle
- **THEN** the fraction of audio that was not billed is derivable as
  `suppressedSilenceSeconds / (streamedAudioSeconds + suppressedSilenceSeconds)`

#### Scenario: First-token latency is tracked as an EMA
- **WHEN** the first token of a session arrives after audio was sent
- **THEN** the elapsed time between the audio send and that token updates the
  first-token latency EMA, and a session with no tokens does not corrupt it

#### Scenario: Session ends are attributed to a cause
- **WHEN** a session ends because of silence, because of a transport/server
  error, or because the user stopped the session
- **THEN** the corresponding counter (`sessionsEndedBySilence`,
  `sessionsEndedByError`, `sessionsEndedByUser`) is incremented, and the
  counters sum to the number of ended sessions

#### Scenario: Errors are recorded without leaking credentials
- **WHEN** a server or transport error is recorded in the metrics
- **THEN** the stored message contains no key-shaped substring, using the same
  redaction as the existing error logging path

### Requirement: Metrics are observable by the app
The metrics SHALL be readable at runtime by the app layer so a UI or report
can display them, exposed through `LiveTranscriptionEngine` in the same
observable style as the existing published transcript.

#### Scenario: The engine publishes metric updates
- **WHEN** the Soniox engine updates its metrics
- **THEN** the updated metrics become readable through
  `LiveTranscriptionEngine` without the caller reaching into the transcriber

#### Scenario: Metrics reset with the session
- **WHEN** transcription is stopped and started again
- **THEN** the metrics of the new session start from zero and do not carry the
  previous session's counters

### Requirement: Existing transcription behaviour stays green
This change SHALL NOT regress the already-implemented Soniox behaviour:
engine selection, diarization mapping into transcript segments, PCM
downsampling, the Privacy Mode kill switch, and clean stop.

#### Scenario: The existing test suite still passes
- **WHEN** the unit test suite is run after this change
- **THEN** the pre-existing Soniox and `LiveTranscriptionEngine` tests pass
  unchanged alongside the new governor and metrics tests
