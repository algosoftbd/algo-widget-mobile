// Tests for the bindings — the same properties the React Native suite asserts,
// because they are properties of being a guest in someone else's process
// rather than facts about a language.
import 'dart:convert';

import 'package:algo_widget/algo_widget.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

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

TraceRecorder recorder({String route = '/orders'}) => TraceRecorder(
      platform: AlgoPlatform.android,
      framework: AlgoFramework.flutter,
      maxSeconds: 600,
    )..start(route);

List<Map<String, Object?>> eventsOf(TraceRecorder rec, String type) =>
    (rec.build()['events']! as List<Object?>)
        .map((e) => e! as Map<String, Object?>)
        .where((e) => e['type'] == type)
        .toList();

class _StubClient extends http.BaseClient {
  _StubClient(this.handler);
  final http.Response Function(http.BaseRequest, String) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request is http.Request ? request.body : '';
    final res = handler(request, body);
    return http.StreamedResponse(
        Stream.value(utf8.encode(res.body)), res.statusCode);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('debugPrint capture', () {
    test('records the line and still prints it', () {
      final rec = recorder();
      final printed = <String?>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message);

      final unbind = bindDebugPrint(Sinks(recorder: rec));
      debugPrint('save failed');
      unbind();
      debugPrint = original;

      expect(eventsOf(rec, 'console').single['message'], 'save failed');
      expect(printed, ['save failed'],
          reason: "the app's own output still runs");
    });

    test('unbinding restores exactly what it found', () {
      void marker(String? m, {int? wrapWidth}) {}
      final original = debugPrint;
      debugPrint = marker;
      final unbind = bindDebugPrint(const Sinks());
      expect(debugPrint, isNot(marker));
      unbind();
      expect(debugPrint, marker,
          reason: 'not the platform default — what was there');
      debugPrint = original;
    });
  });

  group('crash handlers', () {
    test('FlutterError.onError CHAINS to an existing handler', () async {
      final store = _MemoryStore();
      final crash = CrashReporter(store: store, currentRoute: () => '/orders');
      final seenByHost = <String>[];
      final original = FlutterError.onError;
      FlutterError.onError = (d) => seenByHost.add(d.exceptionAsString());

      final unbind = bindFlutterErrors(crash);
      FlutterError.onError!(FlutterErrorDetails(exception: StateError('boom')));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // An app with Crashlytics already has a handler; replacing it would
      // silently stop their crash reporting the day this SDK is added.
      expect(seenByHost.single, contains('boom'));
      expect(store.items.length, 1, reason: 'and ours captured it too');
      expect(store.items.single['error'], isA<Map<String, Object?>>());
      expect(
        (store.items.single['error']! as Map<String, Object?>)['kind'],
        'boundary',
        reason: 'a framework-caught error is the boundary kind',
      );

      unbind();
      FlutterError
          .onError!(FlutterErrorDetails(exception: StateError('after')));
      expect(seenByHost.length, 2, reason: 'unbinding restores the original');
      FlutterError.onError = original;
    });

    test('PlatformDispatcher.onError preserves the app’s handled answer',
        () async {
      final store = _MemoryStore();
      final crash = CrashReporter(store: store, currentRoute: () => '/a');
      final original = PlatformDispatcher.instance.onError;
      PlatformDispatcher.instance.onError = (e, s) => true;

      final unbind = bindPlatformErrors(crash);
      // Answering on the app's behalf would silently swallow a crash it wanted
      // to see — or resurface one it had already handled.
      final handled = PlatformDispatcher.instance.onError!(
          StateError('x'), StackTrace.empty);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(handled, isTrue);
      expect(store.items.length, 1);
      unbind();
      PlatformDispatcher.instance.onError = original;
    });
  });

  group('navigator observer', () {
    Route<dynamic> route(String? name) => PageRouteBuilder<void>(
          settings: RouteSettings(name: name),
          pageBuilder: (_, __, ___) => const SizedBox(),
        );

    test('a push is the reporter, a replace is the app', () {
      final rec = recorder();
      final obs = AlgoNavigatorObserver(Sinks(recorder: rec));
      obs.didPush(route('/orders/42'), null);
      obs.didReplace(newRoute: route('/login'), oldRoute: route('/orders/42'));

      final navs = eventsOf(rec, 'nav');
      expect(navs[0]['to'], '/orders/42');
      expect(navs[0]['cause'], 'user');
      // A redirect written up as a step sends whoever follows it looking for a
      // control that does not exist.
      expect(navs[1]['cause'], 'app');
      expect(obs.currentRoute, '/login');
    });

    test('an unnamed route is skipped, not labelled', () {
      final rec = recorder();
      final obs = AlgoNavigatorObserver(Sinks(recorder: rec));
      obs.didPush(route(null), null);
      obs.didPush(route(''), null);
      // A step naming a screen that does not exist in the app's source is worse
      // than one that says nothing.
      expect(eventsOf(rec, 'nav'), isEmpty);
      expect(obs.currentRoute, '');
    });

    test('a re-push of the current route is not a navigation', () {
      final rec = recorder();
      final obs = AlgoNavigatorObserver(Sinks(recorder: rec));
      obs.didPush(route('/orders'), null);
      obs.didPush(route('/orders'), null);
      expect(eventsOf(rec, 'nav').length, 1);
    });
  });

  group('network', () {
    test('only failures are recorded, and never a query string', () {
      final rec = recorder();
      final sinks = Sinks(recorder: rec);
      recordRequest(sinks, method: 'GET', path: '/api/ok', status: 200);
      recordRequest(sinks,
          method: 'POST', path: '/api/bad?token=secret', status: 500, ms: 12);

      final reqs = eventsOf(rec, 'request');
      expect(reqs.length, 1, reason: 'a 200 is not evidence');
      expect(reqs.single['path'], '/api/bad');
      expect(reqs.single['status'], 500);
    });
  });

  _frameBridgeTests();
  _facadeTests();
  _panelTests();

  group('bindAll', () {
    test('returns one teardown, and it is idempotent', () {
      final original = debugPrint;
      final unbind = bindAll(sinks: const Sinks(), crashes: false);
      expect(debugPrint, isNot(original));
      unbind();
      expect(debugPrint, original);
      expect(unbind, returnsNormally);
      debugPrint = original;
    });
  });
}

// ── The frame bridge ───────────────────────────────────────────────────────
// Deliberately the same cases as the React Native suite: one panel, two
// clients, and the failure mode of a divergence is silence.
void _frameBridgeTests() {
  group('frame bridge', () {
    test('an unrecognised message is ignored, not fatal', () {
      // The frame and the SDK version independently: a panel newer than the app
      // WILL send messages this build has never heard of.
      expect(parseFrameMessage({'type': 'algo-widget:teleport'}), isNull);
      expect(parseFrameMessage({'type': 'something-else'}), isNull);
      expect(parseFrameMessage('not json'), isNull);
      expect(parseFrameMessage(null), isNull);
      expect(parseFrameMessage(42), isNull);
    });

    test('messages arrive as strings from a WebView and parse the same', () {
      expect(
          parseFrameMessage('{"type":"algo-widget:ready"}'), isA<FrameReady>());
      final size =
          parseFrameMessage('{"type":"algo-widget:size","height":412.6}');
      expect((size! as FrameSize).height, 413);
    });

    test('a malformed known message is rejected rather than half-read', () {
      expect(parseFrameMessage({'type': 'algo-widget:size'}), isNull);
      expect(
        parseFrameMessage(
            {'type': 'algo-widget:record-start', 'mode': 'video'}),
        isNull,
      );
      final start = parseFrameMessage(
          {'type': 'algo-widget:record-start', 'mode': 'screen'});
      expect((start! as FrameRecordStart).mode, 'screen');
    });

    test('the URL carries the accent so the first paint is the right colour',
        () {
      expect(
        frameUrl('https://os.example.com/', accentColor: '#c62828'),
        'https://os.example.com/widget/frame?accent=%23c62828',
      );
      expect(frameUrl('https://os.example.com'),
          'https://os.example.com/widget/frame');
    });

    test("a reporter's text cannot break out of the injected expression", () {
      final js = postToFrame({'name': "O'Brien\"; alert(1); //"});
      final inner = jsonDecode(
        js.substring(js.indexOf('("') + 1, js.lastIndexOf('")') + 1),
      ) as String;
      expect((jsonDecode(inner) as Map)['name'], "O'Brien\"; alert(1); //");
    });

    test('the frame is posted an OBJECT — a string it cannot read', () {
      // The bug this exists to keep out: the frame reads `event.data.type`,
      // because on the web it is handed a structured clone. Posted as a string,
      // `.type` was undefined and EVERY message this SDK sent was dropped in
      // silence — the panel loaded, waited for an init it had already been
      // given, and hung on "Loading…".
      final js = postToFrame({'type': 'algo-widget:init', 'token': 'tk'});
      expect(js, contains('JSON.parse('));
      expect(js, isNot(contains('postMessage)("')));
    });
  });
}

// ── The façade ─────────────────────────────────────────────────────────────
// The property that matters most: init NEVER throws. An SDK that can break a
// customer's launch path is not one they can ship.
void _facadeTests() {
  group('facade', () {
    http.Client portalStub(Map<String, Object?>? portal) =>
        _StubClient((req, body) {
          if (!req.url.path.endsWith('/session')) {
            return http.Response(jsonEncode({'issueId': 'i1'}), 200);
          }
          if (portal == null) {
            return http.Response(jsonEncode({'error': 'unknown portal'}), 404);
          }
          return http.Response(
            jsonEncode({'token': 'tk', 'exp': 9999999999999, 'portal': portal}),
            200,
          );
        });

    test('survives a portal that refuses us, and says it is unavailable',
        () async {
      final w = await AlgoWidget.init(
        host: 'https://os.example.com',
        portalKey: 'pk_abc',
        platform: AlgoPlatform.android,
        appId: 'com.acme.orders',
        httpClient: portalStub(null),
      );
      expect(w.available, isFalse,
          reason: 'the host should hide its entry point');
      expect(w.offeredModes, isEmpty);
      w.dispose();
    });

    test('the offered tiers are the portal ANDed with the device', () async {
      final w = await AlgoWidget.init(
        host: 'https://os.example.com',
        portalKey: 'pk_abc',
        platform: AlgoPlatform.android,
        appId: 'com.acme.orders',
        // A microphone, but no screen capture on this build.
        capabilities:
            const CaptureInfo(canScreenshot: true, canRecordVoice: true),
        httpClient: portalStub({
          'recordingEnabled': true,
          'recordingModes': ['steps', 'voice', 'screen'],
          'recordingMaxSeconds': 120,
          'crashCapture': true,
        }),
      );
      // Never offer a tier that fails the moment it is pressed.
      expect(w.offeredModes, ['steps', 'voice']);
      expect(w.recorder.remainingMs, 120000);
      w.dispose();
    });

    test(
        'a portal with recording off offers nothing, whatever the device can do',
        () async {
      final w = await AlgoWidget.init(
        host: 'https://os.example.com',
        portalKey: 'pk_abc',
        platform: AlgoPlatform.ios,
        appId: 'com.acme.orders',
        capabilities: const CaptureInfo(
          canScreenshot: true,
          canRecordVoice: true,
          canRecordScreen: true,
        ),
        httpClient: portalStub({
          'recordingEnabled': false,
          'recordingModes': ['steps'],
          'crashCapture': true,
        }),
      );
      expect(w.offeredModes, isEmpty);
      w.dispose();
    });

    test('crash capture is off without a store rather than pretending',
        () async {
      final w = await AlgoWidget.init(
        host: 'https://os.example.com',
        portalKey: 'pk_abc',
        platform: AlgoPlatform.android,
        appId: 'com.acme.orders',
        httpClient: portalStub({'crashCapture': true}),
      );
      // Reports built on a dying process with nowhere to go are lost reports.
      expect(w.crash, isNull);
      w.dispose();
    });

    test('a queued crash from a previous launch is flushed at init', () async {
      final store = _MemoryStore()
        ..items = [
          {
            'at': 1,
            'error': {'kind': 'error', 'name': 'E', 'message': 'x'},
            'page': {'route': '/a'},
          }
        ];
      var crashPosts = 0;
      final w = await AlgoWidget.init(
        host: 'https://os.example.com',
        portalKey: 'pk_abc',
        platform: AlgoPlatform.android,
        appId: 'com.acme.orders',
        crashStore: store,
        httpClient: _StubClient((req, body) {
          if (req.url.path.endsWith('/crash')) crashPosts++;
          if (req.url.path.endsWith('/session')) {
            return http.Response(
              jsonEncode({
                'token': 'tk',
                'exp': 9999999999999,
                'portal': {'crashCapture': true},
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      // A crash report is worth most when it arrives before the user hits the
      // same wall again.
      expect(crashPosts, 1);
      expect(store.items, isEmpty);
      w.dispose();
    });
  });
}

// ── The report panel ───────────────────────────────────────────────────────
class _FakeNative implements NativeCapture {
  final List<String> calls = [];
  String? shot = '/tmp/shot-1.png';

  @override
  Future<String?> screenshot() async {
    calls.add('screenshot');
    return shot;
  }

  @override
  Future<String?> startVoice() async {
    calls.add('startVoice');
    return '/tmp/voice-1.m4a';
  }

  @override
  Future<String?> stopVoice() async {
    calls.add('stopVoice');
    return '/tmp/voice-1.m4a';
  }

  @override
  Future<void> startScreen({required bool withMicrophone}) async =>
      calls.add('startScreen');

  @override
  Future<String?> stopScreen() async {
    calls.add('stopScreen');
    return '/tmp/screen-1.mp4';
  }

  @override
  Future<void> purge() async => calls.add('purge');
}

const _fullPortal = {
  'recordingEnabled': true,
  'recordingModes': ['steps', 'voice', 'screen'],
  'recordingMaxSeconds': 60,
  'crashCapture': true,
};

void _panelTests() {
  group('panel', () {
    /// `portal: null` = the portal refused us, so no ticket is ever minted.
    Future<(AlgoWidget, _FakeNative, PanelSession, List<String>)> fixture({
      Map<String, Object?>? portal = _fullPortal,
      CaptureInfo capabilities = const CaptureInfo(
        canScreenshot: true,
        canRecordVoice: true,
        canRecordScreen: true,
      ),
      Map<String, String>? identity,
    }) async {
      final sent = <String>[];
      final native = _FakeNative();
      final widget = await AlgoWidget.init(
        host: 'https://os.example.com',
        portalKey: 'pk_abc',
        platform: AlgoPlatform.android,
        appId: 'com.acme.orders',
        capabilities: capabilities,
        httpClient: _StubClient((req, body) {
          if (req.url.path.endsWith('/session')) {
            if (portal == null) {
              return http.Response(
                  jsonEncode({'error': 'unknown portal'}), 404);
            }
            return http.Response(
              jsonEncode(
                  {'token': 'tk', 'exp': 9999999999999, 'portal': portal}),
              200,
            );
          }
          if (req.url.path.endsWith('/files')) {
            return http.Response(
              jsonEncode({
                'ok': true,
                'uploaded': [
                  {'fileId': 'f1', 'filename': 'x', 'kind': 'trace'}
                ],
                'rejected': <Object?>[],
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );
      final session = PanelSession(
        widget: widget,
        native: native,
        readFile: (_) async => Uint8List.fromList([1, 2, 3]),
        send: sent.add,
        identity: identity,
      );
      return (widget, native, session, sent);
    }

    // Pull the payload out of an injected `…postMessage(JSON.parse("…"), '*')`
    // expression, without depending on which function the shim left in front
    // of it.
    Map<String, Object?> payload(List<String> sent, int n) {
      final js = sent[n];
      final inner = jsonDecode(
        js.substring(js.indexOf('("') + 1, js.lastIndexOf('")') + 1),
      ) as String;
      return jsonDecode(inner) as Map<String, Object?>;
    }

    List<Object?> types(List<String> sent) =>
        [for (var i = 0; i < sent.length; i++) payload(sent, i)['type']];

    test('is initialised with the ticket, so it can submit', () async {
      final (widget, _, session, sent) = await fixture();
      await session.handle({'type': 'algo-widget:ready'});
      // The ticket crosses to a page on the OS ORIGIN — never into the
      // customer's own code, the same boundary the web widget uses.
      expect(payload(sent, 0)['token'], 'tk');
      widget.dispose();
    });

    test('init is three messages, because that is what the frame hears',
        () async {
      final (widget, _, session, sent) = await fixture(
        identity: const {'name': 'Jane', 'email': 'jane@acme.com'},
      );
      await session.handle({'type': 'algo-widget:ready'});
      // Folded INTO init, identity and capabilities were silently ignored: the
      // frame has a separate handler for each and no reader for either field on
      // init. The symptom was a panel that never prefilled a name the host had
      // already told us, and never offered a recorder a device could do.
      expect(types(sent), [
        'algo-widget:init',
        'algo-widget:identity',
        'algo-widget:record-capabilities',
      ]);
      expect(payload(sent, 1)['name'], 'Jane');
      expect(payload(sent, 2)['voice'], isTrue);
      widget.dispose();
    });

    test('a session that cannot be minted sends nothing it cannot back up',
        () async {
      // The frame requires a token before it renders a form, so an init
      // carrying `portal: null` was a message it dropped anyway. The host is
      // what should not have opened the panel (`AlgoWidget.available`).
      final (widget, _, session, sent) = await fixture(portal: null);
      await session.handle({'type': 'algo-widget:ready'});
      expect(sent, isEmpty);
      widget.dispose();
    });

    test('is offered our tiers, not the portal’s raw list', () async {
      final (widget, _, session, sent) = await fixture(
        capabilities: const CaptureInfo(canScreenshot: true),
      );
      await session.handle({'type': 'algo-widget:ready'});
      final portal = payload(sent, 0)['portal']! as Map<String, Object?>;
      expect(portal['recordingModes'], ['steps']);
      widget.dispose();
    });

    test('cancel stops the capture, discards the trace AND purges', () async {
      final (widget, native, session, sent) = await fixture();
      await session
          .handle({'type': 'algo-widget:record-start', 'mode': 'screen'});
      widget.recorder.tap(el: const TraceElement(testid: 'a'));
      await session.handle({'type': 'algo-widget:record-stop', 'cancel': true});

      // The promise a reporter is entitled to believe: nothing left the phone,
      // and nothing stayed on it.
      expect(native.calls, contains('stopScreen'));
      expect(native.calls, contains('purge'));
      expect((widget.recorder.build()['events']! as List<Object?>), isEmpty);
      expect(payload(sent, sent.length - 1)['type'],
          'algo-widget:record-cancelled');
      widget.dispose();
    });

    test('closing mid-recording is a cancel, not a pause', () async {
      final fx = await fixture();
      final widget = fx.$1;
      final native = fx.$2;
      var closed = false;
      final session = PanelSession(
        widget: widget,
        native: native,
        readFile: (_) async => Uint8List(0),
        send: (_) {},
        onClose: () => closed = true,
      );
      await session
          .handle({'type': 'algo-widget:record-start', 'mode': 'voice'});
      expect(session.recording, isTrue);
      await session.handle({'type': 'algo-widget:close'});
      expect(closed, isTrue);
      expect(session.recording, isFalse);
      expect(native.calls, contains('stopVoice'));
      widget.dispose();
    });

    test('a finished recording stages the trace and the media', () async {
      final (widget, _, session, sent) = await fixture();
      await session
          .handle({'type': 'algo-widget:record-start', 'mode': 'voice'});
      await session
          .handle({'type': 'algo-widget:record-stop', 'cancel': false});
      final sentTypes = types(sent);
      expect(sentTypes, contains('algo-widget:attached'));
      expect(sentTypes.last, 'algo-widget:record-result');
      widget.dispose();
    });

    test('a tier this device cannot do is refused rather than started',
        () async {
      final (widget, _, session, sent) = await fixture(
        capabilities: const CaptureInfo(canScreenshot: true),
      );
      // A stale panel, or a permission revoked since init, is exactly this case.
      await session
          .handle({'type': 'algo-widget:record-start', 'mode': 'screen'});
      expect(payload(sent, 0)['type'], 'algo-widget:record-error');
      expect(session.recording, isFalse);
      widget.dispose();
    });

    test('a screenshot that fails tells the panel rather than hanging it',
        () async {
      final (widget, native, session, sent) = await fixture();
      native.shot = null;
      await session.handle({'type': 'algo-widget:snip-request'});
      expect(payload(sent, 0)['type'], 'algo-widget:snip-error');
      widget.dispose();
    });

    test('the declared content type follows the extension', () {
      expect(contentTypeFor('voice-1.m4a'), 'audio/mp4');
      expect(contentTypeFor('screen.mov'), 'video/quicktime');
      expect(contentTypeFor('shot.png'), 'image/png');
      expect(contentTypeFor('mystery.bin'), 'application/octet-stream');
    });
  });
}
