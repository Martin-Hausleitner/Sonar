# Dev Setup

## Anforderungen

| Tool | Version (mind.) | Empfohlen |
|------|-----------------|-----------|
| macOS | 15 (Sequoia) | 26 (Tahoe) |
| Xcode | 16.4 (iOS 18.1 SDK) | 17 (iOS 26 SDK) |
| Swift Toolchain | 6.0 | 6.2 |
| XcodeGen | 2.42 | latest |
| Python (für `sonar-agent/`) | 3.11 | 3.12 |
| LiveKit CLI (optional) | 2.x | latest |

```bash
brew install xcodegen swiftlint
gem install xcodeproj  # nicht zwingend, aber nützlich
```

## Test-Hardware

**Pflicht. Simulator reicht NICHT.**

- 2× iPhone (mind. iPhone 14 Pro, ideal iPhone 17 Pro) für
  - UWB-Ranging
  - Multipeer Connectivity
  - Audio-Routing
- 2× AirPods Pro 3 (ideal — Pro 2 funktioniert mit reduzierten Features)
- 1× lauter Bluetooth-Speaker für Club-Bubble-Field-Test
- 1× Apple Watch (optional, für §12.7 Notfall-Button)

Was du auf dem Simulator testen kannst, siehe Plan §15.

## First-Run-Checkliste

```bash
git clone <repo>
cd sonar
xcodegen generate
open Sonar.xcodeproj
```

In Xcode:

1. Signing-Team auf dein eigenes umstellen
2. Bundle-ID anpassen, falls `app.sonar.ios` schon vergeben ist
3. Push-To-Talk-Entitlement deaktivieren, bis Apple dir das freigibt
   (Schritt 14 ist v1.1)
4. Auf echtem Device deployen (Simulator hat KEIN UWB)

## Verifikation der Apple-Annahmen

Lege beim ersten Build-And-Run die Werte aus diesem Snippet im
Console-Log ab und übertrage sie hierhin:

```swift
// in SonarApp.swift, init()
import NearbyInteraction
let session = NISession()
print("UWB caps:", session.deviceCapabilities)
```

| Property | Erwartet (17 Pro) | Tatsächlich |
|----------|-------------------|-------------|
| `supportsPreciseDistanceMeasurement` | `true` | TBD |
| `supportsDirectionMeasurement` | `true` | TBD |
| `supportsCameraAssistance` | `true` | TBD |
| `supportsExtendedDistanceMeasurement` | `true` | TBD |

## Bekannte Stolperfallen

- **„App crashes on first mic access"** — fehlender
  `NSMicrophoneUsageDescription`. Siehe Plan §4.
- **„Peers finden sich nicht"** — Local-Network-Permission verweigert,
  oder `NSBonjourServices` fehlt in Info.plist.
- **„UWB liefert immer 0 m"** — beide Devices müssen die gleiche
  `NIDiscoveryToken` ausgetauscht haben, sonst Timeout-Loop.
- **„Audio echo bei Stille"** — `AVAudioEngine.inputNode
  .isVoiceProcessingEnabled` muss VOR dem `prepare()` gesetzt sein.

## Debug-Build-Flags

In `project.yml`:

```yaml
configs:
  Debug:
    SWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG SONAR_VERBOSE_LOGGING
```

`SONAR_VERBOSE_LOGGING` aktiviert os-log-Tracing in `Logger.swift`.
