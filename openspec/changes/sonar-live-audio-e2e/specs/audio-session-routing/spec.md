## ADDED Requirements

### Requirement: Decoded remote audio routes to an audible output by default
The system SHALL configure `AVAudioSession` category options (via
`AudioSessionPolicy.categoryOptions` in `AudioEngine`) so that, absent an
explicit external route (AirPods/Bluetooth), decoded remote audio is routed
to the device speaker rather than the earpiece, using
`.defaultToSpeaker` (or an equivalent documented mechanism) alongside the
existing `.allowAirPlay`, `.allowBluetooth`, and `.mixWithOthers` options.

#### Scenario: No headphones/AirPods connected
- **WHEN** a call is active and no Bluetooth/AirPlay output is connected
- **THEN** decoded remote audio is audible from the device's speaker, not
  routed to the earpiece

#### Scenario: AirPods connected
- **WHEN** a call is active and AirPods are connected
- **THEN** decoded remote audio is routed to the AirPods (existing
  `.allowBluetooth`/AirPods behavior is preserved)

#### Scenario: Unit test asserts routing option
- **WHEN** `AudioSessionPolicyTests` (or equivalent) constructs the default
  `AudioSessionPolicy`
- **THEN** `categoryOptions` includes `.defaultToSpeaker`
