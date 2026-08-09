# Changelog

## 0.1.0

First release.

- The wire protocol, including the challenge/attestation exchange that replaces
  the browser's `Origin` header on native clients.
- `TraceRecorder` — the interaction trace: head+tail retention, a media-time
  clock that survives pause, the element identity ladder, and the redaction
  rules (a request path never carries a query string; a field's value is never
  read).
- `CrashReporter` — per-launch, per-route and per-signature throttles,
  persistence across the dying process, and a signature that separates the same
  error on two screens while grouping one bug with its own repeats.
- `AlgoWidgetClient` — session, staging, report and crash.

Native capture (screen, voice, screenshot) is scaffolded in the repository's
Android and iOS cores and is not yet wired into this package.
