// What the report panel DOES, as opposed to what it looks like — the Dart twin
// of packages/react-native/src/panelController.ts.
//
// The widget around this is a shell: it renders a WebView, forwards messages in
// and evaluates the JavaScript this returns. Everything that can actually be
// wrong — the init payload, the recording lifecycle, staging a capture, the
// countdown, what happens when the reporter cancels — lives here, where it can
// be driven message-by-message in a test with no device.
//
// THE RULE THIS FILE EXISTS TO KEEP: a reporter who cancels must be able to
// believe that nothing they recorded left the phone, and nothing stayed on it.
// `cancel` therefore stops the capture, discards the trace AND purges the bytes,
// in that order, before the panel is told.
library;

import 'dart:typed_data';

import 'algo_widget_base.dart';
import 'client.dart';
import 'frame_bridge.dart';

/// The native capture surface. An interface rather than an implementation:
/// everything on it crosses a platform channel, so the useful thing to do here
/// is define the contract and degrade honestly when it is absent.
abstract class NativeCapture {
  /// A PNG of the app's own window. No permission and no consent dialog, and it
  /// cannot see another app — which is why it is the default evidence rather
  /// than a recording.
  Future<String?> screenshot();

  /// `.m4a` by contract: AAC-in-MP4 is what both platforms write natively AND
  /// what the transcription service accepts by name, so a voice note reaches a
  /// transcript with no re-encode anywhere.
  Future<String?> startVoice();
  Future<String?> stopVoice();

  Future<void> startScreen({required bool withMicrophone});
  Future<String?> stopScreen();

  /// Delete everything this SDK has written. Cancel must guarantee both that
  /// nothing recorded left the device AND that nothing stayed on it.
  Future<void> purge();
}

/// How often the countdown the reporter watches is refreshed. One second,
/// because the panel renders `2:31 left` and anything finer is invisible.
const Duration kTick = Duration(seconds: 1);

class PanelSession {
  PanelSession({
    required this.widget,
    required this.send,
    required this.readFile,
    this.native,
    this.identity,
    this.onClose,
    this.onSubmitted,
    this.onHeight,
    this.onFullscreen,
  });

  final AlgoWidget widget;

  /// Evaluate JavaScript in the WebView. The widget wires this to its
  /// controller.
  final void Function(String js) send;

  /// Read a file the native side produced. Injected so this module needs no
  /// filesystem package — an app already has one.
  final Future<Uint8List> Function(String path) readFile;

  final NativeCapture? native;
  final Map<String, String>? identity;
  final void Function()? onClose;
  final void Function(String? issueId)? onSubmitted;
  final void Function(int height)? onHeight;
  final void Function({required bool on})? onFullscreen;

  String? _mode;

  /// True while a recording is running — the host drives ticks only then.
  bool get recording => _mode != null;

  /// Handle one raw message from the WebView. Unparseable or unknown input is
  /// ignored: the panel and the SDK version independently.
  Future<void> handle(Object? raw) async {
    final message = parseFrameMessage(raw);
    if (message == null) return;
    await _dispatch(message);
  }

  Future<void> _dispatch(FrameMessage message) async {
    switch (message) {
      case FrameReady():
        await _sendInit();
      case FrameSize(:final height):
        onHeight?.call(height);
      case FrameFullscreen(:final on):
        onFullscreen?.call(on: on);
      case FrameClose():
        // Closing mid-recording is a cancel, not a pause. The panel is gone;
        // leaving a capture running would keep the platform's recording
        // indicator on with nothing to stop it.
        if (recording) await _stop(cancel: true);
        onClose?.call();
      case FrameSnipRequest():
        await _screenshot();
      case FrameRecordStart(:final mode):
        await _start(mode);
      case FrameRecordStop(:final cancel):
        await _stop(cancel: cancel);
      case FrameSubmitted(:final issueId):
        onSubmitted?.call(issueId);
    }
  }

  /// The TICKET goes across, because the panel calls the staging and report
  /// routes itself — it is a page on the OS origin, so the ticket never enters
  /// the customer's own code, which is the same trust boundary the web widget
  /// uses.
  ///
  /// THREE messages, not one, because that is what the frame listens for —
  /// `init`, then `identity`, then `record-capabilities`, exactly as the web
  /// loader sends them. Folded into init they were dropped without a word, so a
  /// host that had already told us the reporter's name got no prefill from it.
  ///
  /// A session that cannot be minted leaves the panel on its loading state and
  /// nothing else happens: the frame requires a token before it renders a form,
  /// and there is no message for "this failed". The host is expected not to have
  /// opened the panel at all ([AlgoWidget.available]), and that is a real gap
  /// rather than a design — a frame-side unavailable state is the fix, not a
  /// client-side one.
  Future<void> _sendInit() async {
    Ticket? ticket;
    try {
      ticket = await widget.client.session();
    } catch (_) {
      ticket = null;
    }
    if (ticket == null) return;
    final offered = widget.offeredModes;
    send(postToFrame(frameInit(
      token: ticket.token,
      exp: ticket.exp,
      page: widget.observer.currentRoute,
      // The tiers the panel may offer are OURS, not the portal's raw list: a
      // device without a microphone must not be shown a voice tier the portal
      // happens to allow.
      portal: <String, Object?>{
        'title': ticket.portal.title,
        'accentColor': ticket.portal.accentColor,
        'recordingEnabled': offered.isNotEmpty,
        'recordingModes': offered,
        'recordingMaxSeconds': ticket.portal.recordingMaxSeconds,
        'crashCapture': ticket.portal.crashCapture,
        'maxAttachments': ticket.portal.maxAttachments,
      },
    )));
    final who = identity;
    if (who != null && (who['name'] != null || who['email'] != null)) {
      send(
          postToFrame(identityMessage(name: who['name'], email: who['email'])));
    }
    // Both halves must be true: a native module that reports it can screenshot
    // is no use if the panel was constructed without one to call.
    send(postToFrame(recordCapabilitiesMessage(
      offered,
      snip: native != null && widget.capabilities.canScreenshot,
    )));
  }

  /// NOTE ON `algo-widget:attached`, sent here and from [_stop]: THE FRAME DOES
  /// NOT YET UNDERSTAND IT. Its attachments are local files it stages itself,
  /// and it has no case for one that is already on the server, so the message is
  /// currently dropped. Unreachable in practice — a screenshot needs a
  /// [NativeCapture], recording needs one plus a portal that enabled it, and no
  /// native capture layer ships yet — but a caller that DOES wire one up will
  /// see the capture succeed and no card appear. The frame half is the work that
  /// has to land alongside the native one; the name and shape are settled so
  /// both sides are written against the same thing.
  Future<void> _screenshot() async {
    String? path;
    try {
      path = await native?.screenshot();
    } catch (_) {
      path = null;
    }
    final staged = path == null ? null : await _stage(path);
    if (staged == null) {
      send(postToFrame(<String, Object?>{'type': 'algo-widget:snip-error'}));
      return;
    }
    send(postToFrame(<String, Object?>{
      'type': 'algo-widget:attached',
      'file': <String, Object?>{...staged.toRef(), 'kind': 'image'},
    }));
  }

  Future<void> _start(String mode) async {
    // Never start a tier this client cannot finish. The panel filters on what
    // init advertised, but a stale panel or a permission revoked since is
    // exactly the case this guard is for.
    if (!widget.offeredModes.contains(mode)) {
      send(postToFrame(
          recordResult(error: 'that recording option is not available')));
      return;
    }
    try {
      if (mode == 'voice') await native?.startVoice();
      if (mode == 'screen') await native?.startScreen(withMicrophone: true);
    } catch (_) {
      send(postToFrame(
          recordResult(error: 'the recording could not be started')));
      return;
    }
    _mode = mode;
    widget.recorder.start(widget.observer.currentRoute);
    send(postToFrame(recordStarted(mode, widget.recorder.limitMs)));
  }

  /// Refresh the countdown. Called by the host on a timer — this class owns no
  /// timer, so no test has to wait on one.
  void tick() {
    if (!recording) return;
    send(postToFrame(recordTick(
      elapsedMs: widget.recorder.elapsedMs,
      limitMs: widget.recorder.limitMs,
      events: widget.recorder.eventCount,
    )));
    // The recorder stops ITSELF at the portal's cap; the panel has to be told,
    // or the reporter watches a frozen countdown on a recording that ended.
    if (!widget.recorder.isRecording) unawaited(_stop(cancel: false));
  }

  Future<void> _stop({required bool cancel}) async {
    final mode = _mode;
    _mode = null;
    if (mode == null) return;

    // Stop the capture FIRST, whatever else happens. A running MediaProjection
    // keeps the system's recording indicator on, which tells the user something
    // is being captured when nothing is.
    String? path;
    try {
      if (mode == 'voice') path = await native?.stopVoice();
      if (mode == 'screen') path = await native?.stopScreen();
    } catch (_) {
      path = null;
    }

    if (cancel) {
      // Order matters and is the whole promise: discard the trace, delete the
      // bytes, then tell the panel.
      widget.recorder.cancel();
      try {
        await native?.purge();
      } catch (_) {
        // A purge that fails must not turn a cancel into an error.
      }
      send(postToFrame(recordResult(cancel: true)));
      return;
    }

    final trace = widget.recorder.stop();
    final staged = await widget.client.stageTrace(trace);
    if (staged != null) {
      send(postToFrame(<String, Object?>{
        'type': 'algo-widget:attached',
        'file': <String, Object?>{...staged.toRef(), 'kind': 'trace'},
      }));
    }
    if (path != null) {
      final media = await _stage(path);
      if (media != null) {
        send(postToFrame(<String, Object?>{
          'type': 'algo-widget:attached',
          'file': <String, Object?>{
            ...media.toRef(),
            'kind': mode == 'voice' ? 'audio' : 'video',
          },
        }));
      }
    }
    send(postToFrame(recordResult()));
    try {
      // The bytes are staged; the local copies must not outlive the report.
      await native?.purge();
    } catch (_) {
      // Best effort.
    }
  }

  Future<StagedFile?> _stage(String path) async {
    final filename = path.split('/').last;
    try {
      final bytes = await readFile(path);
      return widget.client.stage(bytes, filename, contentTypeFor(filename));
    } catch (_) {
      return null;
    }
  }

  /// The panel is going away. Same guarantee as cancel.
  Future<void> dispose() async {
    if (recording) await _stop(cancel: true);
  }
}

/// The content type to DECLARE. The server derives the stored one from the
/// extension regardless; this only has to agree with it.
String contentTypeFor(String filename) {
  final dot = filename.lastIndexOf('.');
  final ext = dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'm4a' => 'audio/mp4',
    'aac' => 'audio/aac',
    'mp4' => 'video/mp4',
    'mov' => 'video/quicktime',
    '3gp' || '3gpp' => 'video/3gpp',
    _ => 'application/octet-stream',
  };
}
