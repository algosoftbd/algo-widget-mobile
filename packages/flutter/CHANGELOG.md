# Changelog

## 0.1.0

First release. Everything from the wire protocol up to a one-call
`AlgoWidget.init(...)`, tested without a device.

- **Protocol** — the session exchange that replaces the browser's `Origin`
  header on a native client: name the app, get a challenge, come back with a
  platform attestation minted against it. A `401` carrying a challenge is step
  one, not an error.
- **`TraceRecorder`** — the interaction trace. Head+tail retention (setup *and*
  failure survive; a ring buffer keeps only the failure), a media-time clock
  that does not accumulate a gap across pause, the element identity ladder, and
  the redaction rules: a request path never carries a query string, and there is
  no code path that reads a field's value.
- **`CrashReporter`** — per-launch, per-route and per-signature throttles,
  persistence across the dying process, and a signature that separates the same
  error on two screens while grouping one bug with its own repeats.
- **Bindings** — `FlutterError.onError` (where a widget build failure lands, and
  the only channel that sees it), `PlatformDispatcher.onError`, a
  `NavigatorObserver`, lifecycle, `debugPrint`, and a `recordRequest` hook for
  whatever HTTP client the app already uses. Each chains rather than replaces,
  and restores exactly what it found.
- **Frame bridge** — the report panel is the same page the web widget serves, in
  a WebView. An unrecognised message is ignored rather than fatal, because the
  panel and the SDK version independently.

- **`AlgoWidgetPanel`** — the report panel, presented in a WebView. It loads the
  same page the web widget serves, so the form, the draft store, the annotation
  UI and the countdown are one implementation reaching every client; a small
  shim bridges `window.postMessage` onto the platform channel so the page cannot
  tell which client it is running in.

Not in this release: the native capture layer (screen, voice, screenshot). Its
contract is defined (`NativeCapture`) and the Kotlin and Swift cores exist, but
no module is registered yet — so a panel offers `steps` only until you supply an
implementation. Everything else works today.
