# Algo Widget — mobile SDKs

In-app bug reporting for mobile apps. An end user reports a problem from inside your app — text,
screenshot, voice narration, screen recording, and a recorded **interaction trace** — and when the
app dies of an uncaught exception it files the report itself.

Reports land in [AlgoSoft OS](https://github.com/algosoftbd) as first-class issues and ride the
existing pipeline: transcription → reproduction steps → AI triage → a card on the right Discord
channel → a manager accepts → Algo AI implements → draft PR.

> **Status: usable, not finished.** Both SDKs are complete and tested from the wire protocol up to a
> one-call `AlgoWidget.init(...)` — session, trace, crash capture, framework bindings and the report
> panel's bridge. What still needs device work is the native capture layer (screen, voice,
> screenshot) and the WebView host that presents the panel. See [Status](#status).

| package | language | install |
|---|---|---|
| [`algo_widget`](packages/flutter) | Dart | `flutter pub add algo_widget` |
| [`@algosoft/algo-widget-react-native`](packages/react-native) | TypeScript | `npm i @algosoft/algo-widget-react-native` |
| [`packages/android`](packages/android) | Kotlin | native capture core |
| [`packages/ios`](packages/ios) | Swift | native capture core |

## Why this repository is public

The SDK runs **inside your app and observes your end users**, and on mobile that is a wider surface
than the web equivalent — Android's `MediaProjection` captures the whole device, not one browser tab.

Guarantees like *"the trace records that a field was typed into, never what"* are claims. Open source
is how you check them rather than take them. The privacy rules are in
[PROTOCOL.md §6](docs/PROTOCOL.md#6-privacy--not-negotiable-and-not-improvable), the code that keeps
them is in `recorder.ts` / `recorder.dart`, and CI has a job that fails a pull request which
introduces a value-reading path.

Nothing here is secret. The portal key already ships inside your APK — which is precisely why the
server requires a platform attestation instead of trusting it.

## How a report is authenticated

The web widget's key is safe to publish because the **browser** writes an `Origin` header the page
cannot forge. A native app has no such thing, and its key can be read out of the artifact by anyone.

So the app proves itself to the platform instead — Play Integrity on Android, App Attest on iOS —
against a challenge the server issues:

```
POST /api/widget/session  { key, client: { platform, appId } }
  → 401 { challenge }                    ← not an error; this is step one

POST /api/widget/session  { key, client: { …, challenge, attestation } }
  → 200 { token, portal }
```

The `appId` your app sends is a **lookup key, never an identity**: the server uses whatever the
attestation reports. Full contract in [docs/PROTOCOL.md](docs/PROTOCOL.md).

## The interaction trace

The part that makes a report worth having. ~50 KB against a video's ~50 MB, and it is what the fix is
derived from — every event names the element it touched through an identity **ladder**, so "I tap
*here* and *this* breaks" becomes a string an AI agent can grep for in your repository:

| rung | Flutter | React Native | Android | iOS |
|---|---|---|---|---|
| best | `Key('submit_order')` | `testID="submit_order"` | `Modifier.testTag` | `accessibilityIdentifier` |
| then | `Semantics(label:)` | `accessibilityLabel` | `contentDescription` | `accessibilityLabel` |
| then | widget runtime type | component `displayName` | composable / class | view / class |

**If your app already sets `testID` / keys, you are most of the way there.** That is the single most
valuable thing you can do for the quality of future bug reports.

## Setup

Register your app in AlgoSoft OS first — **Settings → Algo Widget → Mobile apps** — with its package
name / bundle id. On Android, register **both** signing certificate fingerprints: with Play App
Signing (the default for new apps) a Play Store build presents a different certificate than the same
build off your machine, and registering only one locks out half your users.

Then initialise once at app start. Flutter:

```dart
await AlgoWidget.init(portalKey: 'pk_…', host: 'https://os.example.com');
```

React Native:

```tsx
<AlgoWidgetProvider portalKey="pk_…" host="https://os.example.com">
  {/* your app */}
</AlgoWidgetProvider>
```

Then wire navigation, your HTTP client and the crash handler — those three are what turn an installed
SDK into evidence. An SDK that is only initialised still files reports; they just do not say anything.

## Status

| | React Native | Flutter |
|---|---|---|
| wire protocol (session, challenge, staging, report, crash) | **done** | **done** |
| interaction recorder (events, retention, clock, redaction) | **done** | **done** |
| crash reporter (throttles, persistence, signature) | **done** | **done** |
| element ladder | **done** | **done** |
| bindings (network, logs, crashes, navigation, lifecycle) | **done** | **done** |
| report-panel bridge | **done** | **done** |
| `AlgoWidget.init(...)` façade | **done** | **done** |
| native capture (screen, voice, screenshot) | interface + Kotlin/Swift core; needs device work | as RN |
| WebView host presenting the panel | bridge done, widget pending | bridge done, widget pending |
| iOS App Attest | **blocked on server support** — use `attestation: 'off'` for internal builds | |

89 tests across the two (47 TypeScript, 42 Dart), none of which needs a device.

Two SDKs implement one contract, so CI runs a **contract parity** job that fails if a cap or a
version constant disagrees between Dart and TypeScript — the failure mode is otherwise silent.

## Development

```bash
# React Native
cd packages/react-native && npm ci && npm run typecheck && npm test

# Flutter
cd packages/flutter && dart pub get && dart analyze && dart test
```

Both suites run without a device or a simulator, deliberately: the protocol, the recorder and the
crash throttles are where the expensive bugs live, so they are written to be testable on a laptop.

The server contract is verified separately, against a running AlgoSoft OS, by
`scripts/check-widget-mobile.mjs` in that repository. It is what caught the three shape errors this
SDK would otherwise have shipped — a form field named `file` instead of `files`, the staging
response, and the attachment ref.

## Releasing

Tags are per package — `flutter-v0.1.0`, `react-native-v0.1.0`. CI checks the tag against the
manifest before publishing, because neither npm nor pub.dev lets you replace a published version.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
