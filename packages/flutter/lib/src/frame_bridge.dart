// The report panel's message protocol — the Dart half of
// packages/react-native/src/frameBridge.ts.
//
// The panel a reporter types into is NOT reimplemented per platform. It is the
// SAME page the web widget serves — `/widget/frame` on the OS host — loaded in
// a WebView. The form, the draft store, the annotation UI, the attachment caps,
// the tier picker and the countdown are one implementation, maintained once,
// and every fix to them reaches four clients.
//
// Kept free of any WebView package so the parsing and the payload construction
// — the parts that can be wrong — are testable without a device.
library;

import 'dart:convert';

/// What the frame sends us. Names match the web loader's exactly; the frame
/// cannot tell which client it is talking to and must not have to.
sealed class FrameMessage {
  const FrameMessage();
}

class FrameReady extends FrameMessage {
  const FrameReady();
}

class FrameClose extends FrameMessage {
  const FrameClose();
}

class FrameSnipRequest extends FrameMessage {
  const FrameSnipRequest();
}

class FrameSize extends FrameMessage {
  const FrameSize(this.height);
  final int height;
}

class FrameFullscreen extends FrameMessage {
  const FrameFullscreen({required this.on});
  final bool on;
}

class FrameRecordStart extends FrameMessage {
  const FrameRecordStart(this.mode);

  /// 'steps' | 'voice' | 'screen'.
  final String mode;
}

class FrameRecordStop extends FrameMessage {
  const FrameRecordStop({required this.cancel});
  final bool cancel;
}

class FrameSubmitted extends FrameMessage {
  const FrameSubmitted(this.issueId);
  final String? issueId;
}

const Set<String> _recordModes = {'steps', 'voice', 'screen'};

/// The frame's URL.
///
/// The accent rides in the query so the panel's FIRST paint is already the
/// portal's colour rather than brand red. Everything else arrives by message,
/// because it changes after load and a URL change would reload the page and
/// lose a half-typed report.
String frameUrl(String host, {String? accentColor}) {
  final base = '${host.replaceAll(RegExp(r'/+$'), '')}/widget/frame';
  if (accentColor == null || accentColor.isEmpty) return base;
  return '$base?accent=${Uri.encodeComponent(accentColor)}';
}

/// Parse a message from the frame, or null.
///
/// Null for ANYTHING unrecognised rather than an exception. The frame and the
/// SDK version independently: a panel newer than the app will send messages
/// this build has never heard of, and the correct response to one is to ignore
/// it, not to tear down the reporter's session.
FrameMessage? parseFrameMessage(Object? raw) {
  Object? data = raw;
  if (raw is String) {
    try {
      data = jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }
  if (data is! Map) return null;
  final type = data['type'];
  if (type is! String || !type.startsWith('algo-widget:')) return null;

  switch (type) {
    case 'algo-widget:ready':
      return const FrameReady();
    case 'algo-widget:close':
      return const FrameClose();
    case 'algo-widget:snip-request':
      return const FrameSnipRequest();
    case 'algo-widget:size':
      final height = data['height'];
      // A size with no height would resize the panel to nothing.
      if (height is! num) return null;
      return FrameSize(height.round().clamp(0, 100000));
    case 'algo-widget:fullscreen':
      return FrameFullscreen(on: data['on'] == true);
    case 'algo-widget:record-start':
      final mode = data['mode'];
      if (mode is! String || !_recordModes.contains(mode)) return null;
      return FrameRecordStart(mode);
    case 'algo-widget:record-stop':
      return FrameRecordStop(cancel: data['cancel'] == true);
    case 'algo-widget:submitted':
      final id = data['issueId'];
      return FrameSubmitted(id is String ? id : null);
    default:
      // A message from a newer panel. Ignoring it is the whole point.
      return null;
  }
}

/// JavaScript to evaluate in the WebView to deliver one message.
///
/// Double-encoded deliberately: the payload becomes a single JS string literal,
/// so a reporter's own text — a name with an apostrophe, a description with a
/// newline — stays data rather than breaking out of the expression.
String postToFrame(Map<String, Object?> message) {
  final payload = jsonEncode(jsonEncode(message));
  // Prefer the un-patched function the shim stashed: going through the patched
  // one would forward our own init straight back to us.
  return "(window.__algoPost || window.postMessage)($payload, '*');true;";
}

/// The bridge the frame needs in order to be heard at all.
///
/// The frame posts with `window.parent.postMessage(...)` — correct, because on
/// the web it lives in an iframe talking to the loader. In a WebView there is
/// no parent: `window.parent == window`, so the call lands on
/// `window.postMessage`, which goes nowhere a native host can see. A Flutter
/// JavaScript channel only fires for its own named object, which the frame
/// never calls — so without this shim NOT ONE message arrives: the panel loads,
/// waits for an `init` that is never sent, and its Close button does nothing.
///
/// IT MUST RUN BEFORE THE PAGE'S OWN SCRIPTS. The frame announces `ready` as
/// soon as it mounts, which can precede the load event.
String frameShim(String channel) => '''
(function(){
  if (window.__algoWidgetShim) return; window.__algoWidgetShim = true;
  var native = function (s) { try { $channel(s); } catch (e) {} };
  var original = window.postMessage.bind(window);
  window.__algoPost = original;
  window.postMessage = function (data, origin, transfer) {
    try { native(typeof data === 'string' ? data : JSON.stringify(data)); } catch (e) {}
    try { return original(data, origin, transfer); } catch (e) { return undefined; }
  };
})();''';

/// The init payload. `token` is the widget ticket, and it goes to a page on the
/// OS ORIGIN — the same trust boundary the web widget uses: the frame is ours,
/// the host app around it is the customer's, and the ticket never enters the
/// customer's own code.
Map<String, Object?> frameInit({
  required String token,
  required int exp,
  required String page,
  required Map<String, Object?> portal,
  String? name,
  String? email,
  Map<String, bool>? capabilities,
}) =>
    <String, Object?>{
      'type': 'algo-widget:init',
      'token': token,
      'exp': exp,
      'page': page,
      'portal': portal,
      if (name != null || email != null)
        'identity': <String, Object?>{
          if (name != null) 'name': name,
          if (email != null) 'email': email,
        },
      // Which tiers this CLIENT can actually offer, ANDed with what the portal
      // allows. A device without a microphone permission must not be shown a
      // tier that will fail the moment it is pressed.
      if (capabilities != null) 'capabilities': capabilities,
    };

/// Live recording status — the countdown the reporter watches, sent on a timer
/// so the panel can show `2:31 left` without owning the clock.
Map<String, Object?> recordTick(int remainingMs, int events) =>
    <String, Object?>{
      'type': 'algo-widget:record-tick',
      'remainingMs': remainingMs < 0 ? 0 : remainingMs,
      'events': events,
    };

/// Recording ended. `cancel` means the reporter discarded it — the panel shows
/// no attachment, and the SDK must already have deleted the bytes.
Map<String, Object?> recordResult({bool cancel = false, String? error}) {
  if (cancel) return <String, Object?>{'type': 'algo-widget:record-cancelled'};
  if (error != null) {
    return <String, Object?>{
      'type': 'algo-widget:record-error',
      'message': error
    };
  }
  return <String, Object?>{'type': 'algo-widget:record-result'};
}
