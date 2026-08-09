// A complete report, end to end — the shortest thing that is still true.
//
// Everything here runs without Flutter: the protocol, the recorder and the
// crash reporter are pure Dart on purpose, so they can be exercised in a test
// or a script rather than only on a device.
import 'package:algo_widget/algo_widget.dart';
import 'package:flutter/foundation.dart';

Future<void> main() async {
  // 1. A session. On Android this is a two-call exchange under the hood — the
  //    server issues a challenge and `attest` mints a Play Integrity token
  //    against it. A null ticket means the portal will not have us, and the
  //    correct response is to hide the report button, never to show an error.
  final client = AlgoWidgetClient(
    host: 'https://os.example.com',
    portalKey: 'pk_00000000000000000000000000000000',
    platform: AlgoPlatform.android,
    appId: 'com.acme.orders',
    app: const AppFacts(
      appVersion: '3.2.1',
      buildNumber: '451',
      osVersion: 'Android 14',
      deviceModel: 'Pixel 8',
    ),
    attest: (challenge) async => yourPlayIntegrityToken(challenge),
  );

  final ticket = await client.session();
  if (ticket == null) return;

  // 2. Record what the reporter does. The recorder stops itself at the
  //    portal's cap, so a reporter never discovers the limit by having their
  //    recording refused.
  final recorder = TraceRecorder(
    platform: AlgoPlatform.android,
    framework: AlgoFramework.flutter,
    maxSeconds: ticket.portal.recordingMaxSeconds,
  )..start('/orders/42', title: 'Order detail');

  recorder.tap(
      el: const TraceElement(testid: 'orders_refresh', tag: 'ElevatedButton'));
  recorder.input(
      el: const TraceElement(testid: 'order_note')); // never the value
  recorder.request(
      method: 'POST', path: '/api/orders/42', status: 500, ms: 240);
  recorder.gesture(
      AlgoGesture.back); // the system back Android never reports as a control

  // 3. Stage the trace, then file the report.
  final staged = await client.stageTrace(recorder.stop());
  await client.report(
    description: 'Saving an order shows a spinner forever.',
    route: '/orders/42',
    name: 'Jane Doe',
    attachments: [if (staged != null) staged],
  );
  debugPrint('filed \$issueId');

  client.close();
}

/// Your platform channel to the Play Integrity API. Returning null means "I
/// cannot attest" — the client then reports a refusal rather than retrying.
Future<String?> yourPlayIntegrityToken(String challenge) async => null;
