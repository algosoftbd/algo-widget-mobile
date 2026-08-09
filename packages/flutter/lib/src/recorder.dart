// The interaction recorder (docs/PROTOCOL.md §3).
//
// Collects what the reporter did, on one clock shared with the narration and
// the video, so "I tap HERE and THIS breaks" resolves to a string an AI agent
// can grep for in the repository.
//
// THE RULE THAT OUTRANKS EVERYTHING HERE: values are never captured. There is
// no code path in this file that reads a field's value, and there must never be
// one. `input` records THAT a field was typed into. Adding a value is a product
// decision, not a refactor — and this repository is public partly so a
// customer's security team can check that claim rather than take it.
library;

import 'protocol.dart';

class TraceRecorder {
  TraceRecorder({
    required this.platform,
    required this.framework,
    required int maxSeconds,
    DateTime Function()? clock,
    this.onAutoStop,
  })  : _clock = clock ?? DateTime.now,
        _maxMs = maxSeconds <= 0
            ? kTraceMaxDurationMs
            : (maxSeconds * 1000).clamp(1000, kTraceMaxDurationMs);

  final AlgoPlatform platform;
  final AlgoFramework framework;

  /// Fired when the cap is reached, so the host can tear down media capture.
  final void Function()? onAutoStop;

  final DateTime Function() _clock;
  final int _maxMs;

  final List<TraceEvent> _events = [];
  int _startedAt = 0;
  int? _pausedAt;
  int _pausedMs = 0;
  bool _recording = false;
  String _route = '';
  String? _title;
  int _frozenMs = 0;

  bool get isRecording => _recording;
  int get eventCount => _events.length;
  String get route => _route;

  /// Milliseconds left, for the countdown the reporter watches.
  int get remainingMs =>
      _recording ? (_maxMs - _elapsed()).clamp(0, _maxMs) : _maxMs;

  /// Elapsed and cap, which is the pair the PANEL wants: it renders the
  /// countdown itself from `maxMs - ms` (see the frame's record-tick handler),
  /// so handing it a pre-computed remainder left it nothing to fall back on when
  /// a tick was missed. Media time, like everything else here — a paused
  /// recording does not advance.
  int get elapsedMs => _elapsed().clamp(0, _maxMs);

  int get limitMs => _maxMs;

  int get _nowMs => _clock().millisecondsSinceEpoch;

  /// Begin. [route] is where the reporter is standing when they press Record —
  /// the trace has to say where it starts or the first steps float.
  void start(String route, {String? title}) {
    _events.clear();
    _startedAt = _nowMs;
    _pausedAt = null;
    _pausedMs = 0;
    _frozenMs = 0;
    _recording = true;
    _route = route;
    _title = title;
  }

  void pause() {
    if (!_recording || _pausedAt != null) return;
    _pausedAt = _nowMs;
  }

  void resume() {
    final pausedAt = _pausedAt;
    if (pausedAt == null) return;
    _pausedMs += _nowMs - pausedAt;
    _pausedAt = null;
  }

  /// Media time, not wall clock — a paused recording must not accumulate a gap
  /// the video does not have, or every later event lands off the clock the
  /// narration shares.
  int _elapsed() {
    if (!_recording) return _frozenMs;
    final pausedAt = _pausedAt;
    final paused = _pausedMs + (pausedAt != null ? _nowMs - pausedAt : 0);
    return _nowMs - _startedAt - paused;
  }

  /// The one entry point. Every collector funnels through it, so the pause
  /// rule, the cap and the auto-stop cannot be bypassed by a new collector
  /// forgetting one of them.
  void _push(TraceEvent event) {
    if (!_recording || _pausedAt != null) return;
    final t = _elapsed();
    if (t >= _maxMs) {
      _stopAtCap();
      return;
    }
    event.t = clampNum(t, 0, kTraceMaxDurationMs) ?? 0;
    _events.add(event);
    // Soft ceiling: retention runs at build time, but an unbounded list on a
    // phone is a memory problem long before it is a format problem.
    if (_events.length > kTraceMaxEvents * 2) {
      final trimmed = applyRetention(_events);
      _events
        ..clear()
        ..addAll(trimmed.events);
    }
  }

  void _stopAtCap() {
    if (!_recording) return;
    _frozenMs = _maxMs;
    _recording = false;
    onAutoStop?.call();
  }

  // ── Collectors ───────────────────────────────────────────────────────────

  void tap({TraceElement? el, num? x, num? y}) =>
      _push(TraceEvent.tap(el: el, x: x, y: y));

  /// A field was typed into. Callers pass the ELEMENT and nothing else — there
  /// is deliberately no parameter that could carry a value.
  void input({TraceElement? el}) => _push(TraceEvent.input(el: el));

  void submit({TraceElement? el}) => _push(TraceEvent.submit(el: el));

  /// A screen transition. [cause] is what stops a route guard's redirect being
  /// written up as a step the reader should perform.
  void navigate(String to, {String cause = 'user'}) {
    final from = _route;
    _route = to;
    _push(TraceEvent.nav(from: from, to: to, cause: cause));
  }

  void key(String name) => _push(TraceEvent.key(name));

  void scroll(num dy, {TraceElement? el}) =>
      _push(TraceEvent.scroll(dy: dy, el: el));

  void resize(num w, num h) => _push(TraceEvent.resize(w: w, h: h));

  void console(String level, String message) =>
      _push(TraceEvent.console(level, message));

  /// A FAILED request only, and never headers, bodies or query strings.
  void request({
    required String method,
    required String path,
    required int status,
    num? ms,
  }) {
    if (status > 0 && status < 400) return;
    _push(
        TraceEvent.request(method: method, path: path, status: status, ms: ms));
  }

  void visibility({required bool hidden}) =>
      _push(TraceEvent.visibility(hidden: hidden));

  /// [AlgoGesture.back] especially — Android's system back is a navigation the
  /// app never sees as a control, so without it a reproduction reads as though
  /// the reporter teleported between screens.
  void gesture(AlgoGesture kind, {TraceElement? el}) =>
      _push(TraceEvent.gesture(kind, el: el));

  // ── Output ───────────────────────────────────────────────────────────────

  /// Assemble the document. Safe after [stop]; safe to call twice.
  Map<String, Object?> build() {
    final retained = applyRetention(_events);
    final title = clampText(_title, kTraceMaxTitleLen);
    return <String, Object?>{
      'startedAt': _startedAt,
      'durationMs': _elapsed().clamp(0, _maxMs),
      'page': <String, Object?>{
        'route': _route,
        if (title != null) 'title': title,
      },
      'client': <String, Object?>{
        'kind': platform.wire,
        'framework': framework.wire,
      },
      'events': retained.events.map((e) => e.toJson()).toList(),
      if (retained.dropped > 0) 'dropped': retained.dropped,
    };
  }

  Map<String, Object?> stop() {
    _frozenMs = _elapsed();
    final doc = build();
    _recording = false;
    return doc;
  }

  /// Discard everything, on-device. Cancel must guarantee that nothing recorded
  /// ever left the phone.
  void cancel() {
    _recording = false;
    _frozenMs = 0;
    _events.clear();
    _startedAt = 0;
  }
}
