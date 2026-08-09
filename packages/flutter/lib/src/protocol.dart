// The Algo Widget wire contract — see docs/PROTOCOL.md.
//
// This file is the Dart half of a contract that also exists in TypeScript
// (packages/react-native/src/protocol.ts). The two are written from the same
// document and land in the same commit; changing one without the other leaves
// one SDK quietly wrong, and nothing will say so until a report is refused in
// production.
//
// Deliberately free of Flutter: no widgets, no BuildContext, no platform
// channels. It is the part that can be reasoned about and tested without a
// device, which is most of what goes wrong.
library;

/// Which platform is asking. Decides which attestation the server expects.
enum AlgoPlatform {
  android,
  ios;

  String get wire => name;
}

/// Which toolkit built the app. Shapes the element descriptors a reader should
/// expect, and nothing else.
enum AlgoFramework {
  flutter,
  reactNative,
  native;

  String get wire => switch (this) {
        AlgoFramework.flutter => 'flutter',
        AlgoFramework.reactNative => 'react_native',
        AlgoFramework.native => 'native',
      };
}

/// Trace format version this SDK writes.
///
/// DO NOT BUMP THIS AHEAD OF THE SERVER. The staging boundary accepts a range
/// going back but still refuses anything above its own ceiling, so a client
/// that ships a higher version has every recording refused — from every
/// installed copy, until every user updates. Server first, always.
const int kTraceVersion = 1;
const int kCrashVersion = 1;

// ── Caps (PROTOCOL.md §3) ───────────────────────────────────────────────────

const int kTraceMaxEvents = 500;

/// Head+tail retention, NOT a ring buffer: the beginning of a recording is the
/// setup a reproduction needs ("log in, open Orders, switch to Draft"), and a
/// ring buffer throws exactly that away. Must sum to [kTraceMaxEvents].
const int kTraceHeadEvents = 150;
const int kTraceTailEvents = 350;

const int kTraceMaxDurationMs = 15 * 60 * 1000;
const int kTraceMaxBytes = 512 * 1024;

const int kTraceMaxTextLen = 80;
const int kTraceMaxPathLen = 256;
const int kTraceMaxMessageLen = 200;
const int kTraceMaxAttrLen = 120;
const int kTraceMaxKeyLen = 32;
const int kTraceMaxMethodLen = 12;
const int kTraceMaxTitleLen = 200;

const int kCrashMaxConsole = 20;
const int kCrashMaxRequests = 10;
const int kCrashMaxStackFrames = 30;

const int kMaxAttachments = 6;
const Map<String, int> kMaxBytes = {
  'image': 10 * 1024 * 1024,
  'audio': 25 * 1024 * 1024,
  'video': 60 * 1024 * 1024,
  'trace': kTraceMaxBytes,
};

// ── The element descriptor ─────────────────────────────────────────────────

/// An identity ladder — fill in what you can, best rung first.
///
/// The point is not to identify a pixel; it is to hand an AI agent a string it
/// can grep for in the repository. On Flutter the best rung is a widget [Key]
/// or a `Semantics(identifier:)`, because those are literal strings in the
/// app's own source.
class TraceElement {
  const TraceElement({
    this.testid,
    this.id,
    this.name,
    this.component,
    this.role,
    this.label,
    this.tag,
    this.text,
    this.path,
  });

  final String? testid;
  final String? id;
  final String? name;

  /// The widget's runtime type — `QuotationFilters` is a filename in the
  /// customer's repository, which makes it the most valuable rung after a key.
  final String? component;
  final String? role;
  final String? label;
  final String? tag;

  /// Visible text, redaction rules applied. NEVER a field's value.
  final String? text;
  final String? path;

  /// Clamped, and empty when every rung was empty — an all-null descriptor
  /// costs bytes against [kTraceMaxBytes] and says nothing.
  Map<String, Object?>? toJson() {
    final json = <String, Object?>{};
    void put(String key, String? value, int max) {
      final clamped = clampText(value, max);
      if (clamped != null) json[key] = clamped;
    }

    put('testid', testid, kTraceMaxAttrLen);
    put('id', id, kTraceMaxAttrLen);
    put('name', name, kTraceMaxAttrLen);
    put('component', component, kTraceMaxAttrLen);
    put('role', role, kTraceMaxAttrLen);
    put('label', label, kTraceMaxAttrLen);
    put('tag', tag, kTraceMaxAttrLen);
    put('text', text, kTraceMaxTextLen);
    put('path', path, kTraceMaxPathLen);
    return json.isEmpty ? null : json;
  }
}

// ── Events ─────────────────────────────────────────────────────────────────

/// Gestures with no web analogue.
///
/// [back] is why this type exists at all: Android's system back — button or
/// edge swipe — is a NAVIGATION the app never sees as a control, so without it
/// a reproduction reads as though the reporter teleported between screens.
enum AlgoGesture {
  swipe,
  longPress,
  pinch,
  back,
  shake;

  String get wire => switch (this) {
        AlgoGesture.longPress => 'long_press',
        _ => name,
      };
}

/// One recorded event. Built through the named constructors so a caller cannot
/// invent a type the server does not know.
class TraceEvent {
  TraceEvent._(this.type, this.t, this._fields);

  final String type;
  int t;
  final Map<String, Object?> _fields;

  factory TraceEvent.tap({TraceElement? el, num? x, num? y}) =>
      TraceEvent._('click', 0, {
        'el': el?.toJson(),
        'x': clampNum(x, -1000000, 1000000),
        'y': clampNum(y, -1000000, 1000000),
      });

  /// A field was typed into. There is deliberately NO parameter here that could
  /// carry a value — see the privacy rule in the recorder.
  factory TraceEvent.input({TraceElement? el}) =>
      TraceEvent._('input', 0, {'el': el?.toJson()});

  factory TraceEvent.submit({TraceElement? el}) =>
      TraceEvent._('submit', 0, {'el': el?.toJson()});

  /// [cause] is what stops a route guard's redirect being written up as a step
  /// the reader should perform.
  factory TraceEvent.nav({String? from, String? to, String cause = 'user'}) =>
      TraceEvent._('nav', 0, {
        'from': clampText(from, kTraceMaxPathLen),
        'to': clampText(to, kTraceMaxPathLen),
        'cause': cause,
      });

  factory TraceEvent.key(String name) =>
      TraceEvent._('key', 0, {'key': clampText(name, kTraceMaxKeyLen)});

  factory TraceEvent.scroll({num? dy, TraceElement? el}) =>
      TraceEvent._('scroll', 0, {
        'el': el?.toJson(),
        'dy': clampNum(dy, -1000000, 1000000),
      });

  factory TraceEvent.resize({num? w, num? h}) => TraceEvent._('resize', 0, {
        'w': clampNum(w, 0, 100000),
        'h': clampNum(h, 0, 100000),
      });

  factory TraceEvent.console(String level, String message) =>
      TraceEvent._('console', 0, {
        'level': level,
        'message': clampText(message, kTraceMaxMessageLen),
      });

  /// A FAILED request only, and never headers, bodies or query strings.
  factory TraceEvent.request({
    String? method,
    String? path,
    int? status,
    num? ms,
  }) =>
      TraceEvent._('request', 0, {
        'method': clampText(method, kTraceMaxMethodLen),
        'path': clampText(stripQuery(path ?? ''), kTraceMaxPathLen),
        'status': clampNum(status, 0, 599),
        'ms': clampNum(ms, 0, kTraceMaxDurationMs),
      });

  /// The app went to the background or came back. Its whole job is to give a
  /// SILENCE a meaning: thirty seconds in another app looks exactly like thirty
  /// seconds of reading, and they are opposite kinds of evidence.
  factory TraceEvent.visibility({required bool hidden}) =>
      TraceEvent._('visibility', 0, {'hidden': hidden});

  factory TraceEvent.gesture(AlgoGesture gesture, {TraceElement? el}) =>
      TraceEvent._('gesture', 0, {'gesture': gesture.wire, 'el': el?.toJson()});

  factory TraceEvent.mark(String label) =>
      TraceEvent._('mark', 0, {'label': clampText(label, kTraceMaxMessageLen)});

  Map<String, Object?> toJson() {
    final json = <String, Object?>{'type': type, 't': t};
    _fields.forEach((key, value) {
      if (value != null) json[key] = value;
    });
    return json;
  }
}

// ── Normalization ──────────────────────────────────────────────────────────
// The server clamps everything anyway. Doing it here too keeps the document
// inside [kTraceMaxBytes] so the upload is not refused wholesale, and keeps an
// over-long value from costing a reporter their whole recording.

String? clampText(String? value, int max) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return trimmed.length <= max ? trimmed : trimmed.substring(0, max);
}

int? clampNum(num? value, int min, int max) {
  if (value == null || value.isNaN || value.isInfinite) return null;
  return value.round().clamp(min, max);
}

/// Same-origin PATH only — never a full URL and never a query string. A query
/// is where tokens and email addresses live.
String stripQuery(String pathOrUrl) {
  final cut = pathOrUrl.indexOf(RegExp(r'[?#]'));
  final path = cut < 0 ? pathOrUrl : pathOrUrl.substring(0, cut);
  final uri = Uri.tryParse(path);
  // A cross-origin request contributes its HOST, not its path: another
  // service's URL structure is not this app's business.
  if (uri != null && uri.hasAuthority) return uri.host;
  return path;
}

/// Truncate a stack to [kCrashMaxStackFrames] frames and strip query strings.
///
/// The strip is not cosmetic: a frame location can be an app URL, and that is
/// exactly where a reset token or an email address lives.
String? clampStack(String? stack) {
  if (stack == null || stack.trim().isEmpty) return null;
  final frames = stack.split('\n').take(kCrashMaxStackFrames).join('\n');
  return frames.replaceAll(RegExp(r'\?[^\s)' "'" r'"]*'), '');
}

/// Apply the retention rule: keep the first [kTraceHeadEvents] and the last
/// [kTraceTailEvents], with one `mark` recording what went.
///
/// Reading a trace without that marker would suggest the middle simply never
/// happened.
({List<TraceEvent> events, int dropped}) applyRetention(
    List<TraceEvent> events) {
  if (events.length <= kTraceMaxEvents) return (events: events, dropped: 0);
  final head = events.take(kTraceHeadEvents).toList();
  final tail = events.sublist(events.length - kTraceTailEvents);
  final dropped = events.length - head.length - tail.length;
  final marker = TraceEvent.mark('$dropped events omitted')..t = head.last.t;
  return (events: [...head, marker, ...tail], dropped: dropped);
}

/// Which staging bucket an extension falls in — decides the size cap to enforce
/// before uploading. `null` means the server will not accept it at all.
String? kindForFilename(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return null;
  final ext = name.substring(dot + 1).toLowerCase();
  if (const ['png', 'jpg', 'jpeg', 'gif', 'webp'].contains(ext)) return 'image';
  if (const ['m4a', 'aac', 'mp3', 'wav', 'weba', 'ogg', 'oga'].contains(ext)) {
    return 'audio';
  }
  if (const ['mp4', 'mov', '3gp', '3gpp', 'webm'].contains(ext)) return 'video';
  if (ext == 'json') return 'trace';
  return null;
}
