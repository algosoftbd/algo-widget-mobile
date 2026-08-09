// Auto crash capture (docs/PROTOCOL.md §5).
//
// Two things make this different from a reporter-driven report, and both shape
// the whole file:
//
//  1. THE PROCESS IS DYING. A network call inside `FlutterError.onError` or a
//     zone error handler is a race the handler usually loses, so the payload is
//     PERSISTED and sent on next launch.
//  2. NOBODY IS WATCHING. An unattended writer with a bug becomes a flood, so
//     the throttles below are required rather than defensive.
library;

import 'protocol.dart';

/// Somewhere to put a report while the process dies. Injected rather than
/// imported so this file stays testable and free of path_provider.
abstract class CrashStore {
  Future<void> save(List<Map<String, Object?>> reports);
  Future<List<Map<String, Object?>>> load();
  Future<void> clear();
}

/// One burst per launch: a screen that throws forty times in a second is ONE
/// crash, not forty.
const int _maxPerLaunch = 1;

/// Per route, per process. Three is enough to see a pattern, few enough that a
/// broken app cannot spend a portal's whole hourly budget.
const int _maxPerRoute = 3;

/// Same signature, same half hour — almost certainly the same user hitting the
/// same wall again.
const int _cooldownMs = 30 * 60 * 1000;

/// At most this many queued reports survive on the device: an app that crashes
/// on every launch must not accumulate an unbounded backlog.
const int _maxQueued = 5;

class CrashReporter {
  CrashReporter({
    required this.store,
    required this.currentRoute,
    this.appFacts,
    this.enabled,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final CrashStore store;

  /// The route AT CRASH TIME, read fresh. See [capture].
  final String Function() currentRoute;
  final Map<String, Object?> Function()? appFacts;

  /// Absent ⇒ on. The host keeps a kill switch the portal cannot take away.
  final bool Function()? enabled;

  final DateTime Function() _clock;

  final List<Map<String, Object?>> _console = [];
  final List<Map<String, Object?>> _requests = [];
  final Map<String, int> _perRoute = {};
  final Map<String, int> _cooldown = {};
  int _burst = 0;

  int get _nowMs => _clock().millisecondsSinceEpoch;

  /// The last errors before the crash. Shapes and statuses only — an argument's
  /// VALUE is never recorded, here or anywhere.
  void noteConsole(String level, String message) {
    _console.add({
      'level': level,
      'message': clampText(message, kTraceMaxMessageLen) ?? '',
      'at': _nowMs,
    });
    if (_console.length > kCrashMaxConsole) _console.removeAt(0);
  }

  void noteFailedRequest({
    required String method,
    required String path,
    required int status,
    num? ms,
  }) {
    if (status > 0 && status < 400) return;
    final clampedMs = clampNum(ms, 0, 600000);
    _requests.add({
      'method': clampText(method, kTraceMaxMethodLen) ?? '',
      'path': clampText(stripQuery(path), kTraceMaxPathLen) ?? '',
      'status': clampNum(status, 0, 599) ?? 0,
      if (clampedMs != null) 'ms': clampedMs,
      'at': _nowMs,
    });
    if (_requests.length > kCrashMaxRequests) _requests.removeAt(0);
  }

  /// Record a crash. Returns false when a throttle suppressed it.
  ///
  /// Persists rather than sends: the caller is inside a handler on a dying
  /// process and must do as little as possible.
  Future<bool> capture({
    required String kind,
    String? name,
    String? message,
    String? stack,
  }) async {
    if (enabled != null && !enabled!()) return false;
    if (_burst >= _maxPerLaunch) return false;

    // Read the route NOW, not at launch. A Flutter app navigates for the whole
    // life of its process without restarting, so a route captured at startup
    // would make every crash look like it happened on the first screen — and a
    // per-launch budget would silently become a per-user-session one, where one
    // screen's crash suppresses another's.
    final route = currentRoute();

    final seenOnRoute = _perRoute[route] ?? 0;
    if (seenOnRoute >= _maxPerRoute) return false;

    final signature =
        crashSignature(kind: kind, name: name, message: message, route: route);
    final last = _cooldown[signature];
    if (last != null && _nowMs - last < _cooldownMs) return false;

    _burst += 1;
    _perRoute[route] = seenOnRoute + 1;
    _cooldown[signature] = _nowMs;

    final clampedStack = clampStack(stack);
    final report = <String, Object?>{
      'at': _nowMs,
      'error': <String, Object?>{
        'kind': kind,
        'name': clampText(name, 120) ?? 'Error',
        'message': clampText(message, 500) ?? '(no message)',
        if (clampedStack != null) 'stack': clampedStack,
      },
      'page': <String, Object?>{'route': route},
      if (_console.isNotEmpty)
        'console': List<Map<String, Object?>>.from(_console),
      if (_requests.isNotEmpty)
        'requests': List<Map<String, Object?>>.from(_requests),
      if (appFacts != null) 'app': appFacts!(),
    };

    try {
      final queued = await store.load();
      final next = [...queued, report];
      await store.save(
        next.length <= _maxQueued
            ? next
            : next.sublist(next.length - _maxQueued),
      );
    } catch (_) {
      // A failed write loses one crash report. Throwing here would lose the
      // crash the app was already having.
      return false;
    }
    return true;
  }

  /// Send anything persisted by a previous launch, then clear.
  ///
  /// A report that fails to send is retained for the next launch; one that
  /// succeeds is dropped. A permanently unacceptable report would otherwise be
  /// retried on every launch for the life of the install, which is why the
  /// queue is capped.
  Future<int> flush(Future<bool> Function(Map<String, Object?>) send) async {
    List<Map<String, Object?>> queued;
    try {
      queued = await store.load();
    } catch (_) {
      return 0;
    }
    if (queued.isEmpty) return 0;

    var sent = 0;
    final failed = <Map<String, Object?>>[];
    for (final report in queued) {
      bool ok;
      try {
        ok = await send(report);
      } catch (_) {
        ok = false;
      }
      if (ok) {
        sent += 1;
      } else {
        failed.add(report);
      }
    }
    try {
      if (failed.isEmpty) {
        await store.clear();
      } else {
        await store.save(failed);
      }
    } catch (_) {
      // The next launch tries again.
    }
    return sent;
  }
}

/// A grouping key, never a security primitive.
///
/// The ROUTE is part of it deliberately: the same error on two screens is two
/// bugs, and merging them hides one. Numbers and hex ids are normalized out so
/// one bug groups with its own repeats rather than filing one issue per user.
String crashSignature({
  required String kind,
  required String route,
  String? name,
  String? message,
}) {
  final normalized = (message ?? '')
      .toLowerCase()
      .replaceAll(
        RegExp(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'),
        '<uuid>',
      )
      .replaceAll(RegExp(r'\b[0-9a-f]{16,}\b'), '<hash>')
      .replaceAll(RegExp(r'\d+'), '<n>')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final capped = normalized.length <= kTraceMaxMessageLen
      ? normalized
      : normalized.substring(0, kTraceMaxMessageLen);
  return [kind, (name ?? '').toLowerCase(), capped, route.toLowerCase()]
      .join('|');
}
