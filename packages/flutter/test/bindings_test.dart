// Tests for the bindings — the same properties the React Native suite asserts,
// because they are properties of being a guest in someone else's process
// rather than facts about a language.
import 'dart:convert';

import 'package:algo_widget/algo_widget.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

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
      expect(js.startsWith('window.postMessage("'), isTrue);
      final inner = jsonDecode(
        js.substring('window.postMessage('.length, js.lastIndexOf(", '*')")),
      ) as String;
      expect((jsonDecode(inner) as Map)['name'], "O'Brien\"; alert(1); //");
    });
  });
}
