## 1. Loop fixes

- [ ] 1.1 Add `_sonar-mpc._udp` to `NSBonjourServices` in
      `sonar/Resources/Info.plist` alongside the existing
      `_sonar-mpc._tcp` entry.
- [ ] 1.2 Verify `NearTransport`'s `serviceType` / advertiser / browser setup
      reaches `MCSessionState.connected` on both peers (add logging if
      needed to confirm during manual testing).
- [ ] 1.3 Add `.defaultToSpeaker` (or documented equivalent) to
      `AudioSessionPolicy.categoryOptions` in
      `sonar/Core/Audio/AudioEngine.swift` so remote audio is audible by
      default without headphones/AirPods.
- [ ] 1.4 Replace the silent `try? encoder.encode(buffer)` in
      `sonar/Core/Coordinator/SessionCoordinator.swift:387` with explicit
      error handling (log via `os.Logger` + metrics counter on failure).
- [ ] 1.5 Reconcile the mic tap's input buffer format
      (`AudioEngine.prepare()`, `engine.inputNode.inputFormat(forBus: 0)`)
      with `OpusCoder`'s expected PCM format/frame size, either via format
      conversion before encode or by constructing the encoder to match the
      tap's actual negotiated hardware format.

## 2. Unit tests

- [ ] 2.1 Add/extend a test asserting `Info.plist` `NSBonjourServices`
      contains both `_sonar-mpc._tcp` and `_sonar-mpc._udp` and matches
      `NearTransport`'s configured service type.
- [ ] 2.2 Add/extend `AudioSessionPolicy` tests asserting
      `categoryOptions` includes `.defaultToSpeaker`.
- [ ] 2.3 Add/extend `OpusCoder` tests covering encode/decode round-trip
      using a buffer built with the same format the mic tap installs
      (`AudioEngine.prepare()`), not just the coder's idealized format.
- [ ] 2.4 Run the full `sonarTests` suite and confirm all tests (existing +
      new) pass.

## 3. Build + install on both devices

- [ ] 3.1 Build Sonar (dev/debug configuration) for the two target
      devices via `xcodebuild`/`devicectl`.
- [ ] 3.2 Install the build on iPhone 17 Pro via `devicectl device install
      app`.
- [ ] 3.3 Install the build on iPhone15,2 via `devicectl device install
      app`. If the device is unavailable/locked, record this explicitly as
      a blocker (do not fake the result) and escalate to the operator.
- [ ] 3.4 Confirm both installs launch successfully and reach the pairing
      screen.

## 4. E2E audio loop test with proof

- [ ] 4.1 Pair the two devices and confirm both UIs show a connected peer
      (MPC path active).
- [ ] 4.2 Speak into device A's microphone; confirm and record (screen +
      audio) that device B audibly plays back the speech.
- [ ] 4.3 Speak into device B's microphone; confirm and record that device A
      audibly plays back the speech.
- [ ] 4.4 Save all recordings/screenshots under `evidence/` in the repo,
      named with date + description, and personally review them (no error
      screens, no mock/synthetic audio, real captured speech only).

## 5. Soniox live transcription

- [ ] 5.1 Extract the reverse-engineered Soniox streaming API contract
      (endpoint, auth, framing, model `stt-rt-v5`, diarization output
      format) from the `soniox-route-lab` repo.
- [ ] 5.2 Implement a Soniox streaming client in Sonar (e.g. under
      `sonar/Core/Transcription/`) that streams live audio to Soniox and
      receives incremental transcript + speaker-diarization results.
- [ ] 5.3 Wire the live transcript into the call UI so it updates in
      near-real-time while a call is active.
- [ ] 5.4 During the E2E test (section 4), capture proof (screen recording/
      screenshot) that the live transcript appears with correct
      multi-speaker diarization, save under `evidence/`.

## 6. Report

- [ ] 6.1 Write `docs/SONA-E2E-REPORT.md` (Variant-A style: per-step ✅/🔴
      status) covering loop fixes, unit test results, device installs, the
      E2E audio proof, and the Soniox transcription proof, with
      inline-embedded evidence.
- [ ] 6.2 Confirm all four acceptance criteria from `proposal.md` /
      `specs/` are explicitly addressed and evidenced in the report:
      (a) both devices show a connected peer, (b) real audible bidirectional
      audio proven with real recordings, (c) live Soniox transcript proven,
      (d) full `sonarTests` suite green.
