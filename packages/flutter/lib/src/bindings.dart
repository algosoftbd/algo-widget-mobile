// Wiring the SDK into a Flutter app's own machinery (docs/PROTOCOL.md §3, §5).
//
// The Dart half of packages/react-native/src/bindings.ts, and deliberately the
// same three rules, because they are properties of being a guest in someone
// else's process rather than facts about a language:
//
//  1. IT CHAINS, NEVER REPLACES. An app already has a crash reporter and an
//     error handler; taking one over is a regression the app author did not ask
//     for, and it is silent.
//  2. IT UNINSTALLS. Each binding returns a teardown that restores exactly what
//     it found.
//  3. IT NEVER THROWS INTO THE HOST. A bug in observation must not become a bug
//     in the app being observed.
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'crash.dart';
import 'protocol.dart';
import 'recorder.dart';

/// Undo a binding. Idempotent — calling it twice is not an error.
typedef Unbind = void Function();

/// What the collectors write to. Both optional, so an app can wire crash
/// capture without the recorder or the other way round.
class Sinks {
  const Sinks({this.recorder, this.crash});
  final TraceRecorder? recorder;
  final CrashReporter? crash;
}

// ── Logged errors ──────────────────────────────────────────────────────────

/// Capture what the app logs through `debugPrint`.
///
/// Flutter has no `console.error`, and the closest thing every app shares is
/// `debugPrint`. Only the SHAPE of a line survives the caps — a message is
/// evidence, and an object an app printed while it was failing is where a
/// user's record ends up.
Unbind bindDebugPrint(Sinks sinks) {
  final original = debugPrint;
  void patched(String? message, {int? wrapWidth}) {
    try {
      if (message != null && message.isNotEmpty) {
        sinks.recorder?.console('warn', message);
        sinks.crash?.noteConsole('warn', message);
      }
    } catch (_) {
      // Observation must never break the app being observed.
    }
    original(message, wrapWidth: wrapWidth);
  }

  debugPrint = patched;
  return () {
    if (debugPrint == patched) debugPrint = original;
  };
}

// ── Crashes ────────────────────────────────────────────────────────────────

/// File errors Flutter caught in its own framework — the `boundary` kind.
///
/// `FlutterError.onError` is where a widget build failure lands, and it is the
/// channel that matters most: the red screen (or the blank one in release) is
/// the most common fatal a Flutter app has, and NOTHING else reports it. The
/// previous handler is called afterwards, so an app with Crashlytics keeps it.
Unbind bindFlutterErrors(CrashReporter crash) {
  final previous = FlutterError.onError;
  void handler(FlutterErrorDetails details) {
    try {
      unawaited(crash.capture(
        kind: 'boundary',
        name: details.exception.runtimeType.toString(),
        message: details.exceptionAsString(),
        stack: details.stack?.toString(),
      ));
    } catch (_) {
      // Never let the reporter be the reason an error handler throws.
    }
    previous?.call(details);
  }

  FlutterError.onError = handler;
  return () {
    if (FlutterError.onError == handler) FlutterError.onError = previous;
  };
}

/// File errors that escaped the framework entirely — the `error` kind.
///
/// `PlatformDispatcher.onError` catches what `FlutterError.onError` cannot: an
/// exception thrown outside a widget lifecycle, in a callback or a stray async
/// gap. Returning the previous handler's answer (or `false`) preserves the
/// app's own decision about whether the error was handled — answering `true`
/// on its behalf would silently swallow crashes it wanted to see.
Unbind bindPlatformErrors(CrashReporter crash) {
  final previous = PlatformDispatcher.instance.onError;
  bool handler(Object error, StackTrace stack) {
    try {
      unawaited(crash.capture(
        kind: 'error',
        name: error.runtimeType.toString(),
        message: error.toString(),
        stack: stack.toString(),
      ));
    } catch (_) {
      // As above.
    }
    return previous?.call(error, stack) ?? false;
  }

  PlatformDispatcher.instance.onError = handler;
  return () {
    if (PlatformDispatcher.instance.onError == handler) {
      PlatformDispatcher.instance.onError = previous;
    }
  };
}

// ── Navigation ─────────────────────────────────────────────────────────────

/// Follows the app's navigation so a step can say which screen it happened on,
/// and a crash knows the route it died on.
///
/// A `NavigatorObserver` rather than a route-name callback, because Flutter
/// gives one interface every router honours — `MaterialApp.navigatorObservers`,
/// go_router's `observers`, auto_route's. The RN side takes a name instead, for
/// the opposite reason: React Native has no such shared interface.
///
/// `didPop` reports `cause: 'user'` and `didReplace` reports `'app'`: a pop is
/// something the reporter did, a replace is almost always a guard or a redirect
/// — and a reproduction that lists an app's own redirect as a step sends
/// whoever follows it looking for a control that does not exist.
class AlgoNavigatorObserver extends NavigatorObserver {
  AlgoNavigatorObserver(this.sinks);

  final Sinks sinks;
  String _current = '';

  /// Read FRESH by the crash reporter on every crash. An app navigates for the
  /// whole life of its process, so a route captured once at launch would put
  /// every crash on the first screen.
  String get currentRoute => _current;

  void _to(Route<dynamic>? route, String cause) {
    final name = _nameOf(route);
    if (name == null || name == _current) return;
    _current = name;
    sinks.recorder?.navigate(name, cause: cause);
  }

  /// A route's name, or null when it has none. Unnamed routes are SKIPPED
  /// rather than labelled `<unnamed>`: a reproduction step naming a screen that
  /// does not exist in the app's source is worse than one that says nothing.
  static String? _nameOf(Route<dynamic>? route) {
    final name = route?.settings.name;
    if (name == null || name.isEmpty) return null;
    return clampText(name, kTraceMaxPathLen);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _to(route, 'user');

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _to(previousRoute, 'user');

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _to(newRoute, 'app');

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _to(previousRoute, 'app');
}

// ── Lifecycle ──────────────────────────────────────────────────────────────

/// Records the app going to the background and coming back.
///
/// Its whole job is to give a SILENCE a meaning: thirty seconds spent in
/// another app looks exactly like thirty seconds of reading, and they are
/// opposite kinds of evidence. A distiller working from a voice track over the
/// gap will otherwise narrate the wrong one.
class AlgoLifecycleObserver with WidgetsBindingObserver {
  AlgoLifecycleObserver(this.sinks);
  final Sinks sinks;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final hidden = state != AppLifecycleState.resumed;
    sinks.recorder?.visibility(hidden: hidden);
  }
}

/// Register the lifecycle observer and return its teardown.
Unbind bindLifecycle(Sinks sinks) {
  final observer = AlgoLifecycleObserver(sinks);
  final binding = WidgetsBinding.instance..addObserver(observer);
  return () => binding.removeObserver(observer);
}

// ── Network ────────────────────────────────────────────────────────────────

/// Records one FINISHED request. Call this from whatever HTTP client the app
/// uses — a Dio `InterceptorsWrapper`, an `http` `BaseClient`, a hand-rolled
/// wrapper.
///
/// Exposed as a function rather than shipped as a Dio interceptor on purpose:
/// binding to Dio would make it a dependency of this package for every app,
/// including the ones that do not use it. Two lines in the host beats a
/// dependency in everybody's `pubspec.yaml`.
///
/// A success is not evidence — recording every 200 would bury the request that
/// mattered and spend the trace's 500-event budget on noise.
void recordRequest(
  Sinks sinks, {
  required String method,
  required String path,
  required int status,
  num? ms,
}) {
  if (status > 0 && status < 400) return;
  sinks.recorder?.request(method: method, path: path, status: status, ms: ms);
  sinks.crash
      ?.noteFailedRequest(method: method, path: path, status: status, ms: ms);
}

// ── Everything, once ───────────────────────────────────────────────────────

/// Install every binding that does not need the host to hand us something, and
/// return ONE teardown.
///
/// Navigation is absent deliberately: it needs an observer the host adds to its
/// own `MaterialApp`, and an SDK cannot reach in and do that. So is the network
/// interceptor, for the reason above. Both are two lines in the app, and both
/// are named in the install task.
///
/// Teardown runs in reverse install order, so a handler chained on top of
/// another is removed before the one beneath it — otherwise unbinding ours
/// leaves the host's handler pointing at a function we have discarded.
Unbind bindAll({
  required Sinks sinks,
  bool logs = true,
  bool crashes = true,
  bool lifecycle = true,
}) {
  final undo = <Unbind>[];
  if (logs) undo.add(bindDebugPrint(sinks));
  if (lifecycle) undo.add(bindLifecycle(sinks));
  final crash = sinks.crash;
  if (crashes && crash != null) {
    undo.add(bindFlutterErrors(crash));
    undo.add(bindPlatformErrors(crash));
  }
  return () {
    for (final fn in undo.reversed) {
      try {
        fn();
      } catch (_) {
        // A teardown that throws must not strand the others.
      }
    }
    undo.clear();
  };
}
