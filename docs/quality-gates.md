# Quality Gates

This document is the repo-local checklist for Sonar code-quality and release
confidence. It records what must be green before a release and what the current
local machine could not prove.

## Gate Matrix

| Gate | Command or workflow | Coverage |
| --- | --- | --- |
| Swift formatting | `swiftformat sonar sonarTests sonarUITests --lint` | App, unit tests, UI tests |
| Swift lint | `swiftlint lint --strict` | Swift source and tests |
| Python formatting | `ruff format --check scripts/e2e sonar-server` | E2E relay/assert tooling and server |
| Python lint | `ruff check scripts/e2e sonar-server` | E2E relay/assert tooling and server |
| Shell lint | `shellcheck scripts/coverage/*.sh scripts/e2e/*.sh scripts/release/*.sh` | Coverage, E2E, release scripts |
| YAML lint | `yamllint project.yml .github/workflows` | XcodeGen and GitHub Actions config |
| GitHub Actions lint | `actionlint .github/workflows/*.yml` | CI and release workflows |
| Manifest lint | `plutil -lint sonar/Resources/Info.plist sonar/Resources/Sonar.entitlements sonar/Resources/PrivacyInfo.xcprivacy` | iOS metadata, entitlements, privacy manifest |
| XcodeGen reproducibility | `xcodegen generate` plus committed-project diff | `project.yml`, `Sonar.xcodeproj`, pinned Swift packages |
| Simulator relay smoke | `scripts/e2e/simulator_relay.py --self-test` | Relay register, poll, valid frame routing, bad JSON rejection |
| Two-simulator E2E | `scripts/e2e/run-simulator-e2e.sh` | Fresh install, launch, peer visibility, relay frames, screenshots |
| Full app tests | `make test` | Xcode test suite on a dynamically selected iPhone simulator |

`make lint` runs the Swift, Python, shell, YAML, and GitHub Actions lint gates.
The CI and release workflows run `make lint`, regenerate the project, verify the
generated project is committed, resolve Swift packages, then build and test.

## Current Local Verification

Verified locally on 2026-06-03:

- `make lint`
- `bash -n` for release, E2E, and coverage scripts
- `plutil -lint` for app plist, entitlements, and privacy manifest
- YAML/JSON parsing for `apps.json`, `project.yml`, CI, and release workflows
- `python3 -m py_compile scripts/e2e/assert_relay_state.py scripts/e2e/simulator_relay.py sonar-server/main.py`
- `scripts/e2e/simulator_relay.py --self-test`
- synthetic relay-state regression with 120 frames and only the latest 50 recent
  frames retained
- `xcrun xcodebuild -resolvePackageDependencies` with deterministic package
  flags and `-packageAuthorizationProvider netrc`
- `make test`: 416 unit tests and 3 UI tests, all passing
- `scripts/e2e/run-simulator-e2e.sh`: fresh install on two simulators, both
  devices registered, 23 relayed frames, both frame sources seen, screenshots
  captured and visually checked
- `git diff --check`
- `xcodegen generate`

Former local blocker on 2026-06-03:

```bash
xcrun xcodebuild -resolvePackageDependencies \
  -project Sonar.xcodeproj \
  -scheme Sonar \
  -destination generic/platform=iOS \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  -scmProvider system \
  -packageAuthorizationProvider netrc \
  -disableAutomaticPackageResolution \
  -clonedSourcePackagesDirPath /tmp/SonarResolveGate
```

Without `-packageAuthorizationProvider netrc`, this command was terminated after
420 seconds while the log was still at:

```text
Resolve Package Graph
```

With `-packageAuthorizationProvider netrc`, Swift package resolution completes
locally. CI keeps package resolution as an explicit gate with diagnostic log
upload so regressions are visible instead of being masked by a later build/test
step.

The fixed narrower project-load diagnostic is:

```bash
xcrun xcodebuild -list \
  -project Sonar.xcodeproj \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  -packageAuthorizationProvider netrc \
  -scmProvider system
```

Without `-packageAuthorizationProvider netrc`, the same diagnostic was terminated
after 90 seconds at the `Resolve Package Graph` line, which pointed to local
Xcode/SPM project loading rather than a later compile or test failure.

`xcodebuild -checkFirstLaunchStatus` exits successfully on this machine, and a
second `xcodebuild -list` attempt with `-disablePackageRepositoryCache` also
stalled at `Resolve Package Graph`, so the observed blocker is not Xcode
first-launch setup or the local package repository cache alone.

Sampling the stalled process showed SwiftPM waiting in
`KeychainAuthorizationProvider` while fetching binary artifacts. Passing
`-packageAuthorizationProvider netrc` avoids that Keychain path; with this flag,
`xcodebuild -list -project Sonar.xcodeproj` resolves the package graph and lists
the project successfully. CI, release, coverage, simulator E2E, and local
`make test` Xcodebuild invocations pass the deterministic package flags:

```text
-onlyUsePackageVersionsFromResolvedFile
-skipPackageUpdates
-scmProvider system
-packageAuthorizationProvider netrc
```

Top-level XcodeGen package requirements also use exact versions matching
`Package.resolved`.

## External Practices Applied

- Apple requires a privacy manifest entry for accessed required-reason APIs, so
  `sonar/Resources/PrivacyInfo.xcprivacy` is committed and included in app
  resources:
  <https://developer.apple.com/documentation/BundleResources/describing-use-of-required-reason-api>
- Apple documents `UIBackgroundModes` as an explicit capability declaration, so
  the app declares only the supported `audio` background mode:
  <https://developer.apple.com/documentation/bundleresources/information-property-list/uibackgroundmodes>
- GitHub recommends choosing runner labels deliberately because `*-latest`
  labels move over time; workflows now use `macos-26` rather than
  `macos-latest`:
  <https://docs.github.com/en/actions/reference/runners/github-hosted-runners>
- SwiftFormat and SwiftLint are official upstream tools in this repo's lint
  gate:
  <https://github.com/nicklockwood/SwiftFormat>
  <https://github.com/realm/SwiftLint>

## Audit Slices

The stabilization audit covered these independent slices:

- CI runner/toolchain and failure diagnostics
- XcodeGen project generation and committed resource graph
- Swift audio/session compile compatibility
- Swift concurrency and actor isolation risks
- SwiftUI environment-object injection and previews
- Release script idempotency, branch/tag hygiene, and IPA freshness
- GitHub Release workflow safety
- Python relay/assert/server tooling
- Simulator E2E device selection and state assertions
- Coverage script simulator selection
- Privacy manifest, background modes, and plist hygiene
- Security/privacy risk review for transports and credentials
