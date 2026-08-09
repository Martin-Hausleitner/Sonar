## ADDED Requirements

### Requirement: Live transcription via reverse-engineered Soniox streaming API
The system SHALL transcribe the active live-audio call in near-real-time
using the reverse-engineered Soniox streaming API (as documented in the
`soniox-route-lab` repo), using the `stt-rt-v5` model with multi-speaker
diarization, and display the resulting live transcript in the app UI while
the call is active.

#### Scenario: Live transcript appears during an active call
- **WHEN** two devices are connected and speech is exchanged over the live
  audio loop
- **THEN** a live transcript of the speech appears in the UI on the device(s)
  running the transcription client, updating as the call progresses

#### Scenario: Multi-speaker diarization is reflected in the transcript
- **WHEN** both participants speak during the same call
- **THEN** the displayed transcript distinguishes between the two speakers
  (diarization), consistent with Soniox `stt-rt-v5` multi-speaker output

#### Scenario: Transcription proof captured as real evidence
- **WHEN** the live transcription feature is demonstrated
- **THEN** a screen recording/screenshot showing the live transcript text
  appearing during a real call (not mocked/sample text) is saved under
  `evidence/` and referenced from `docs/SONA-E2E-REPORT.md`
