// Tests for the parts that can be wrong without a device — which, measured
// against the web widget's own history, is where the expensive bugs lived.
//
// Deliberately the SAME cases as packages/react-native/test/protocol.test.ts.
// Two SDKs implementing one contract drift silently; two test files asserting
// the same behaviours are how that stops being silent.
import 'dart:convert';

import 'package:algo_widget/algo_widget.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';

http.Client stubClient(
  http.Response Function(http.BaseRequest request, String body) handler,
) {
  return _StubClient(handler);
}

class _StubClient extends http.BaseClient {
  _StubClient(this.handler);
  final http.Response Function(http.BaseRequest, String) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request is http.Request ? request.body : '';
    final res = handler(request, body);
    return http.StreamedResponse(
      Stream.value(utf8.encode(res.body)),
      res.statusCode,
      headers: res.headers,
    );
  }
}

void main() {
  group('retention', () {
    test('keeps the head AND the tail, and says what it dropped', () {
      final events = List.generate(700, (i) => TraceEvent.tap()..t = i);
      final result = applyRetention(events);
      expect(result.dropped, 700 - kTraceHeadEvents - kTraceTailEvents);
      expect(result.events.length, kTraceHeadEvents + kTraceTailEvents + 1);
      // The setup a reproduction needs survives...
      expect(result.events.first.t, 0);
      // ...and so does the failure at the end, which a ring buffer would have
      // kept while throwing the setup away.
      expect(result.events.last.t, 699);
      expect(result.events[kTraceHeadEvents].type, 'mark');
    });

    test('leaves an under-cap trace alone', () {
      final events =
          List.generate(kTraceMaxEvents, (i) => TraceEvent.tap()..t = i);
      final result = applyRetention(events);
      expect(result.dropped, 0);
      expect(result.events.length, kTraceMaxEvents);
    });
  });

  group('redaction', () {
    test('a request path never carries a query string', () {
      expect(stripQuery('/orders?token=secret&id=4'), '/orders');
      expect(stripQuery('/orders#frag'), '/orders');
      // Cross-origin contributes its HOST only — another service's URL
      // structure is not this app's business.
      expect(stripQuery('https://pay.example.com/charge?cvv=123'),
          'pay.example.com');
    });

    test('a stack loses its query strings and its tail', () {
      final stack = List.generate(
          50, (i) => '#$i  Foo.bar (package:acme/a.dart?tok=x:1:2)').join('\n');
      final out = clampStack(stack)!;
      expect(out.split('\n').length, kCrashMaxStackFrames);
      expect(out.contains('tok=x'), isFalse);
    });
  });

  group('recorder', () {
    test('never exposes a way to record a value', () {
      final rec = TraceRecorder(
        platform: AlgoPlatform.android,
        framework: AlgoFramework.flutter,
        maxSeconds: 60,
      )..start('/orders');
      rec.input(el: const TraceElement(testid: 'order_note'));
      final doc = rec.build();
      final events = doc['events']! as List<Object?>;
      final input = events.firstWhere(
        (e) => (e! as Map<String, Object?>)['type'] == 'input',
      )! as Map<String, Object?>;
      // The whole privacy posture in one assertion: the event names the field
      // and carries nothing else.
      expect(input.keys.toSet(), {'type', 't', 'el'});
      expect(jsonEncode(doc).contains('value'), isFalse);
    });

    test('stops itself at the cap rather than letting a trace be refused', () {
      var now = DateTime.fromMillisecondsSinceEpoch(1000);
      var autoStopped = false;
      final rec = TraceRecorder(
        platform: AlgoPlatform.android,
        framework: AlgoFramework.flutter,
        maxSeconds: 10,
        clock: () => now,
        onAutoStop: () => autoStopped = true,
      )..start('/orders');
      rec.tap(el: const TraceElement(testid: 'a'));
      now = now.add(const Duration(seconds: 11));
      rec.tap(el: const TraceElement(testid: 'b'));
      expect(autoStopped, isTrue);
      expect(rec.isRecording, isFalse);
      final clicks = (rec.build()['events']! as List<Object?>)
          .where((e) => (e! as Map<String, Object?>)['type'] == 'click');
      expect(clicks.length, 1);
    });

    test('a paused recording does not accumulate a gap the video does not have',
        () {
      var now = DateTime.fromMillisecondsSinceEpoch(0);
      final rec = TraceRecorder(
        platform: AlgoPlatform.ios,
        framework: AlgoFramework.flutter,
        maxSeconds: 600,
        clock: () => now,
      )..start('/a');
      now = now.add(const Duration(seconds: 1));
      rec.tap(el: const TraceElement(testid: 'before'));
      rec.pause();
      now = now.add(const Duration(seconds: 59));
      rec.resume();
      rec.tap(el: const TraceElement(testid: 'after'));
      final clicks = (rec.build()['events']! as List<Object?>)
          .map((e) => e! as Map<String, Object?>)
          .where((e) => e['type'] == 'click')
          .toList();
      // Media time, not wall clock: the second tap sits ~1s after the first,
      // which is where it is on the recording the narration shares.
      expect(clicks[1]['t'], 1000);
    });

    test('nav records where it came from, and who caused it', () {
      final rec = TraceRecorder(
        platform: AlgoPlatform.android,
        framework: AlgoFramework.flutter,
        maxSeconds: 60,
      )..start('/orders');
      rec.navigate('/orders/42');
      rec.navigate('/login', cause: 'app');
      final navs = (rec.build()['events']! as List<Object?>)
          .map((e) => e! as Map<String, Object?>)
          .where((e) => e['type'] == 'nav')
          .toList();
      expect(navs[0]['from'], '/orders');
      expect(navs[0]['to'], '/orders/42');
      expect(navs[0]['cause'], 'user');
      expect(navs[1]['cause'], 'app');
    });

    test('only FAILED requests are recorded', () {
      final rec = TraceRecorder(
        platform: AlgoPlatform.android,
        framework: AlgoFramework.flutter,
        maxSeconds: 60,
      )..start('/a');
      rec.request(method: 'GET', path: '/api/ok', status: 200);
      rec.request(
          method: 'POST', path: '/api/bad?secret=1', status: 500, ms: 12);
      final reqs = (rec.build()['events']! as List<Object?>)
          .map((e) => e! as Map<String, Object?>)
          .where((e) => e['type'] == 'request')
          .toList();
      expect(reqs.length, 1);
      expect(reqs.single['path'], '/api/bad');
    });

    test('cancel guarantees nothing recorded survives', () {
      final rec = TraceRecorder(
        platform: AlgoPlatform.android,
        framework: AlgoFramework.flutter,
        maxSeconds: 60,
      )..start('/a');
      rec.tap(el: const TraceElement(testid: 'x'));
      rec.cancel();
      expect((rec.build()['events']! as List<Object?>).isEmpty, isTrue);
    });

    test('the gesture vocabulary matches the wire format', () {
      expect(AlgoGesture.longPress.wire, 'long_press');
      expect(AlgoGesture.back.wire, 'back');
    });
  });

  group('crash', () {
    test('signature separates the same error on two screens', () {
      final a = crashSignature(
        kind: 'error',
        name: 'StateError',
        message: 'x is null',
        route: '/orders',
      );
      final b = crashSignature(
        kind: 'error',
        name: 'StateError',
        message: 'x is null',
        route: '/devices',
      );
      expect(a, isNot(b));
    });

    test('signature groups one bug with its own repeats', () {
      final a = crashSignature(
        kind: 'error',
        name: 'StateError',
        message: 'order 4821 not found',
        route: '/orders',
      );
      final b = crashSignature(
        kind: 'error',
        name: 'StateError',
        message: 'order 9137 not found',
        route: '/orders',
      );
      expect(a, b);
    });

    test('one burst per launch — forty throws in a second are one crash',
        () async {
      final store = _MemoryStore();
      final rep = CrashReporter(store: store, currentRoute: () => '/orders');
      var accepted = 0;
      for (var i = 0; i < 40; i++) {
        if (await rep.capture(kind: 'error', name: 'E', message: 'boom')) {
          accepted++;
        }
      }
      expect(accepted, 1);
      expect(store.items.length, 1);
    });

    test('the route is read AT CRASH TIME, not at launch', () async {
      final store = _MemoryStore();
      var route = '/orders';
      final rep = CrashReporter(store: store, currentRoute: () => route);
      await rep.capture(kind: 'error', name: 'E', message: 'one');
      route = '/devices';
      final page = store.items.single['page']! as Map<String, Object?>;
      expect(page['route'], '/orders');
    });

    test('flush clears on success and retains on failure', () async {
      final store = _MemoryStore();
      final rep = CrashReporter(store: store, currentRoute: () => '/a');
      await rep.capture(kind: 'error', name: 'E', message: 'x');

      expect(await rep.flush((_) async => false), 0);
      expect(store.items.length, 1,
          reason: 'a failed send is retried next launch');

      expect(await rep.flush((_) async => true), 1);
      expect(store.items, isEmpty);
    });
  });

  group('session', () {
    test('treats 401+challenge as step one, not an error', () async {
      final bodies = <Map<String, Object?>>[];
      final client = AlgoWidgetClient(
        host: 'https://os.example.com',
        portalKey: 'pk_abc',
        platform: AlgoPlatform.android,
        appId: 'com.acme.orders',
        attest: (challenge) async => 'token-for-$challenge',
        httpClient: stubClient((request, body) {
          final json = jsonDecode(body) as Map<String, Object?>;
          bodies.add(json);
          final clientJson = json['client']! as Map<String, Object?>;
          if (clientJson['attestation'] == null) {
            return http.Response(
                jsonEncode({'challenge': 'nonce-1', 'exp': 1}), 401);
          }
          return http.Response(
            jsonEncode({
              'token': 'tk',
              'exp': 9999999999999,
              'portal': <String, Object?>{}
            }),
            200,
          );
        }),
      );

      final ticket = await client.session();
      expect(ticket, isNotNull,
          reason: 'a challenge must not be surfaced as a failure');
      expect(ticket!.token, 'tk');
      expect(bodies.length, 2);
      // The attestation was minted against the challenge the server issued —
      // the binding that stops a captured token being replayed forever.
      final second = bodies[1]['client']! as Map<String, Object?>;
      expect(second['attestation'], 'token-for-nonce-1');
    });

    test('a refusal is not retried, and never becomes a ticket', () async {
      var hits = 0;
      final client = AlgoWidgetClient(
        host: 'https://os.example.com',
        portalKey: 'pk_abc',
        platform: AlgoPlatform.ios,
        appId: 'com.acme.orders',
        attest: (_) async => 'irrelevant',
        httpClient: stubClient((_, __) {
          hits++;
          return http.Response(jsonEncode({'error': 'unknown portal'}), 404);
        }),
      );
      expect(await client.session(), isNull);
      expect(hits, 1, reason: 'a 404 is configuration; retrying it is noise');
    });

    test('a session with no attestation provider cannot invent one', () async {
      final client = AlgoWidgetClient(
        host: 'https://os.example.com',
        portalKey: 'pk_abc',
        platform: AlgoPlatform.android,
        appId: 'com.acme.orders',
        httpClient: stubClient(
          (_, __) =>
              http.Response(jsonEncode({'challenge': 'n', 'exp': 1}), 401),
        ),
      );
      expect(await client.session(), isNull);
    });

    test('concurrent callers share one session exchange', () async {
      var mints = 0;
      final client = AlgoWidgetClient(
        host: 'https://os.example.com',
        portalKey: 'pk_abc',
        platform: AlgoPlatform.android,
        appId: 'com.acme.orders',
        httpClient: stubClient((_, __) {
          mints++;
          return http.Response(
            jsonEncode({
              'token': 'tk',
              'exp': 9999999999999,
              'portal': <String, Object?>{}
            }),
            200,
          );
        }),
      );
      await Future.wait([client.session(), client.session(), client.session()]);
      expect(mints, 1,
          reason: 'a crash flush and a reporter must not race two exchanges');
    });

    test('attribution is SHOWN unless the portal explicitly says otherwise',
        () {
      // The inverse of crashCapture's default, deliberately: a field the server
      // has not sent yet must not silently strip a customer's attribution.
      expect(PortalConfig.fromJson(const {}).showPoweredBy, isTrue);
      expect(
        PortalConfig.fromJson(const {'showPoweredBy': false}).showPoweredBy,
        isFalse,
      );
    });

    test('crash capture is OFF unless the portal explicitly says otherwise',
        () {
      final absent = PortalConfig.fromJson(const {});
      expect(absent.crashCapture, isFalse);
      final on = PortalConfig.fromJson(const {'crashCapture': true});
      expect(on.crashCapture, isTrue);
    });
  });

  group('staging', () {
    test('kindForFilename knows the mobile containers', () {
      expect(kindForFilename('voice.m4a'), 'audio');
      expect(kindForFilename('voice.aac'), 'audio');
      expect(kindForFilename('screen.3gp'), 'video');
      expect(kindForFilename('screen.mov'), 'video');
      expect(kindForFilename('trace.json'), 'trace');
      expect(kindForFilename('thing.exe'), isNull);
      expect(kindForFilename('noextension'), isNull);
    });
  });

  group('element ladder', () {
    test('drops an all-empty descriptor and clamps the rest', () {
      expect(const TraceElement().toJson(), isNull);
      expect(const TraceElement(testid: '   ').toJson(), isNull);
      final el =
          const TraceElement(testid: 'submit_order', label: 'Save').toJson()!;
      expect(el['testid'], 'submit_order');
      expect(el['label'], 'Save');
    });
  });
}

class _MemoryStore extends CrashStore {
  List<Map<String, Object?>> items = [];

  @override
  Future<void> clear() async => items = [];

  @override
  Future<List<Map<String, Object?>>> load() async => items;

  @override
  Future<void> save(List<Map<String, Object?>> reports) async =>
      items = reports;
}
