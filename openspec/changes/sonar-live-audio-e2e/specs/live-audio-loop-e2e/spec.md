## ADDED Requirements

### Requirement: Two physical devices demonstrably hear each other live
The system SHALL demonstrate, using two physical iPhones (iPhone 17 Pro and
iPhone15,2) running the Sonar app in dev mode, that speech captured on
device A is audibly played back on device B in near-real-time, and vice
versa, once both devices show a connected peer.

#### Scenario: Peer visibility
- **WHEN** both devices run Sonar and are within pairing range
- **THEN** each device's UI shows the other device as a connected peer
  (MPC path active, not just discovered)

#### Scenario: Live audio loop closes in both directions
- **WHEN** a person speaks into device A's microphone while connected to
  device B
- **THEN** the speech is audibly heard on device B's speaker/output within
  the app's live-audio latency budget, and the same holds in the reverse
  direction (device B → device A)

#### Scenario: Proof is captured as real evidence, not mocked
- **WHEN** the live audio loop test is performed
- **THEN** screen and/or audio recordings from both physical devices are
  saved under `evidence/` in the repo, are reviewed for containing real
  captured audio (not synthetic/mocked data), and are referenced from
  `docs/SONA-E2E-REPORT.md`

### Requirement: Existing unit test suite remains green
The system SHALL keep all pre-existing `sonarTests` unit tests passing after
the loop fixes are applied, in addition to any new tests added by this
change.

#### Scenario: Full test suite run
- **WHEN** the `sonarTests` target is run after implementing the fixes in
  this change
- **THEN** all tests (pre-existing and newly added) pass
