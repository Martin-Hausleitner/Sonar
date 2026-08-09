## ADDED Requirements

### Requirement: MPC service advertises and resolves over both TCP and UDP
The system SHALL declare Bonjour service records for both the TCP and UDP
variants of the MultipeerConnectivity (MPC) service type used by
`NearTransport` (`_sonar-mpc._tcp` and `_sonar-mpc._udp`) in
`NSBonjourServices`, so `MCNearbyServiceAdvertiser`/`MCNearbyServiceBrowser`
can fully resolve peers regardless of which underlying transport MPC selects.

#### Scenario: Info.plist declares both Bonjour service variants
- **WHEN** `sonar/Resources/Info.plist` is inspected for `NSBonjourServices`
- **THEN** the array contains both `_sonar-mpc._tcp` and `_sonar-mpc._udp`

### Requirement: Peers reach a connected MPC session state
The system SHALL transition both the advertising and browsing peer to
`MCSessionState.connected` (not merely `foundPeer`/discovery) before the app
reports the peer as usable for live audio.

#### Scenario: Two physical devices pair and connect
- **WHEN** device A advertises via `NearTransport` and device B browses and
  invites device A within Bluetooth/Wi-Fi range
- **THEN** both devices observe `MCSessionState.connected` for the peer, and
  the app's UI reflects a connected peer on both devices

#### Scenario: Connection state regression is caught by tests
- **WHEN** the `NearTransport` unit tests run
- **THEN** they assert the configured `serviceType` matches an
  `NSBonjourServices` entry pair (`_tcp` and `_udp`) so a future edit to one
  without the other fails the test suite
