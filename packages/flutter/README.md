# algo_widget

In-app bug reporting for Flutter apps. A user reports a problem from inside your
app — text, screenshot, voice narration, screen recording, and a recorded
**interaction trace** — and reports land in
[AlgoSoft OS](https://github.com/algosoftbd) as first-class issues.

Part of [algo-widget-mobile](https://github.com/algosoftbd/algo-widget-mobile).
The wire contract is documented in
[PROTOCOL.md](https://github.com/algosoftbd/algo-widget-mobile/blob/main/docs/PROTOCOL.md).

## What makes a report worth having

The **interaction trace** — ~50 KB against a video's ~50 MB, and the part a fix
is actually derived from. Every event names the element it touched through an
identity ladder, so "I tap *here* and *this* breaks" becomes a string an agent
can grep for in your repository:

```dart
Semantics(
  identifier: 'submit_order',   // ← the best rung
  child: ElevatedButton(onPressed: submit, child: const Text('Save')),
)
```

If your widgets already carry `Key`s or `Semantics(identifier:)`, you are most of
the way there.

## Privacy

Not negotiable, and checked in CI rather than promised in prose:

- the trace records **that** a field was typed into, never what — there is no
  code path that reads a value;
- nothing is captured before Record is pressed. No always-on buffer, ever;
- requests carry no headers, no bodies and no query strings;
- `cancel()` discards everything on-device.

## Usage

```dart
final client = AlgoWidgetClient(
  host: 'https://os.example.com',
  portalKey: 'pk_…',
  platform: AlgoPlatform.android,
  appId: 'com.acme.orders',
  app: const AppFacts(appVersion: '3.2.1', buildNumber: '451'),
  attest: (challenge) => PlayIntegrity.token(nonce: challenge),
);

final recorder = TraceRecorder(
  platform: AlgoPlatform.android,
  framework: AlgoFramework.flutter,
  maxSeconds: client.portal?.recordingMaxSeconds ?? 300,
)..start('/orders/42');

recorder.tap(el: const TraceElement(testid: 'orders_refresh'));
recorder.navigate('/orders/42/edit');

final trace = await client.stageTrace(recorder.stop());
await client.report(
  description: 'Saving an order does nothing',
  route: '/orders/42',
  attachments: [if (trace != null) trace],
);
```

Register your app first in AlgoSoft OS — **Settings → Algo Widget → Mobile
apps** — with its package name and, on Android, **both** signing certificate
fingerprints. With Play App Signing a Play Store build presents a different
certificate than the same build off your machine, and registering only one locks
out half your users.

## Attaching files

Works out of the box, and **needs no permission** — no manifest entry, no
runtime prompt. The picker goes through Android's system photo picker (13+) or
the Storage Access Framework below it, both of which grant access to the one
item the reporter chose. Asking for `READ_MEDIA_IMAGES` would request a
customer's users' entire gallery to read a file they had already handed over.

Android needs the wiring because an `<input type="file">` in an Android WebView
opens nothing on its own: the platform asks the embedder through
`onShowFileChooser`, and an unanswered request is dropped silently — no error,
no dialog. `AlgoWidgetPanel` answers it. iOS is deliberately left alone, since
WKWebView presents its own picker.

The default covers images and video. To widen it — documents, or a picker your
app already ships — pass your own:

```dart
AlgoWidgetPanel(
  widget: algo,
  readFile: (path) => File(path).readAsBytes(),
  fileSelector: (params) async => myPicker(params.acceptTypes),
)
```

Return `[]` when the reporter cancels, and never throw: Android expects an
answer either way, and a dropped one wedges the file input for the rest of the
session.

## Licence

Apache-2.0.
