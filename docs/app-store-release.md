# App Store / TestFlight Release

Sonar uses bundle identifier `app.sonar.ios` and team `FH29968UF7`.

## Prerequisites

One of these must be available on the build machine:

- An Apple Developer account added in Xcode Settings -> Accounts, with access to
  team `FH29968UF7`.
- Or an App Store Connect API key, exported as:

```bash
export ASC_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8
export ASC_KEY_ID=XXXXXXXXXX
export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

The Apple Developer portal/App Store Connect also needs an app identifier and
App Store Connect app record for `app.sonar.ios`.

## Export A Local IPA

```bash
scripts/release/build-appstore.sh
```

The script archives the Release build and exports an App Store Connect `.ipa`
under `build/release/AppStore`.

## Upload Directly To App Store Connect

```bash
DESTINATION=upload scripts/release/build-appstore.sh
```

After processing in App Store Connect, the build can be installed through
TestFlight or submitted for App Store review.

## Build An Unsigned IPA Artifact

This creates a `.ipa` wrapper from an unsigned iPhoneOS build. It is useful for
handoff to a signing pipeline, but iOS will not install it and App Store Connect
will not accept it until it is signed with Apple distribution provisioning.

```bash
scripts/release/build-unsigned-ipa.sh
```
