// The public façade — `AlgoWidget.init(...)` and the handful of calls an app
// author is expected to hold in their head. The Dart twin of
// packages/react-native/src/algoWidget.ts.
//
// Everything underneath is separately usable, and deliberately so: an app with
// its own navigation shape or its own crash reporter can take the recorder and
// the client and leave this alone. This is the ninety-percent path, not the
// only one.
library;

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'bindings.dart';
import 'client.dart';
import 'crash.dart';
import 'protocol.dart';
import 'recorder.dart';

/// What this device/build can actually capture. Absent capabilities are
/// reported as absent, never as failures: a reporter must never be shown a
/// Record button that throws the moment it is pressed, because by then they
/// have already decided to spend the effort.
class CaptureInfo {
  const CaptureInfo({
    this.canScreenshot = false,
    this.canRecordVoice = false,
    this.canRecordScreen = false,
    this.wholeDevice = false,
  });

  final bool canScreenshot;
  final bool canRecordVoice;
  final bool canRecordScreen;

  /// True when a screen recording captures the whole device rather than just
  /// this app (Android). Surfaced rather than smoothed over: a reporter is
  /// about to record everything on screen, and telling them so is the
  /// difference between consent and a surprise.
  final bool wholeDevice;
}

/// The whole SDK, wired.
///
/// [init] never throws. A portal that refuses us, a device with no platform
/// channel, a network that is down — each means some part of the widget is
/// unavailable, and the response to all of them is the same: report less, hide
/// the entry point, and let the app get on with being an app. An SDK that can
/// break a customer's launch path is not one they can ship.
class AlgoWidget {
  AlgoWidget._({
    required this.client,
    required this.recorder,
    required this.observer,
    required this.capabilities,
    required Unbind unbind,
    this.crash,
  }) : _unbind = unbind;

  final AlgoWidgetClient client;
  final TraceRecorder recorder;

  /// Add this to `MaterialApp.navigatorObservers` (or your router's
  /// `observers`). Without it a recorded step cannot say which screen it
  /// happened on, and a crash cannot say where it died.
  final AlgoNavigatorObserver observer;
  final CrashReporter? crash;
  final CaptureInfo capabilities;
  final Unbind _unbind;

  static Future<AlgoWidget> init({
    required String host,
    required String portalKey,
    required AlgoPlatform platform,
    required String appId,
    AppFacts? app,
    AttestationProvider? attest,
    CrashStore? crashStore,
    bool Function()? crashCaptureEnabled,
    CaptureInfo capabilities = const CaptureInfo(),
    http.Client? httpClient,
    void Function(String filename, String reason)? onEvidenceDropped,
  }) async {
    // The binding must exist before any observer is registered — an app that
    // calls init before runApp is the common case, and it is the one that
    // otherwise fails with a message about the binding rather than about us.
    WidgetsFlutterBinding.ensureInitialized();

    final client = AlgoWidgetClient(
      host: host,
      portalKey: portalKey,
      platform: platform,
      appId: appId,
      app: app,
      attest: attest,
      httpClient: httpClient,
      onEvidenceDropped: onEvidenceDropped,
    );

    // One round trip up front, so the portal's config — the tiers on offer, the
    // recording cap, whether crash capture is on at all — is known before the
    // reporter can press anything. A null ticket is not an error: it means the
    // entry point stays hidden.
    Ticket? ticket;
    try {
      ticket = await client.session();
    } catch (_) {
      ticket = null;
    }
    final portal = ticket?.portal;

    final recorder = TraceRecorder(
      platform: platform,
      framework: AlgoFramework.flutter,
      maxSeconds: portal?.recordingMaxSeconds ?? 300,
    );

    // Crash capture needs somewhere to persist. Without a store the reports
    // would be built on a dying process and immediately lost, so the feature is
    // OFF rather than pretending — the same absent-means-off rule the portal
    // flag follows.
    final observer = AlgoNavigatorObserver(Sinks(recorder: recorder));
    final crash = (crashStore != null && (portal?.crashCapture ?? true))
        ? CrashReporter(
            store: crashStore,
            currentRoute: () => observer.currentRoute,
            appFacts: app == null ? null : () => app.toJson(),
            enabled: crashCaptureEnabled,
          )
        : null;

    final sinks = Sinks(recorder: recorder, crash: crash);
    final unbind = bindAll(sinks: sinks);

    final widget = AlgoWidget._(
      client: client,
      recorder: recorder,
      observer: observer,
      crash: crash,
      capabilities: capabilities,
      unbind: unbind,
    );

    // Anything a previous launch persisted goes now — a crash report is worth
    // most when it arrives before the user hits the same wall again.
    if (crash != null) {
      unawaited(crash.flush(client.crash));
    }
    return widget;
  }

  /// Whether the widget can be opened at all. False when the portal refused the
  /// session — the host should hide its report entry point rather than show one
  /// that fails.
  bool get available => client.portal != null;

  /// Which recording tiers to actually offer: the portal's, ANDed with what
  /// this device can do. A portal that never enabled voice is not overridden by
  /// a microphone, and one that did is not offered on a device without one.
  List<String> get offeredModes {
    final portal = client.portal;
    if (portal == null || !portal.recordingEnabled) return const [];
    return portal.recordingModes.where((m) {
      if (m == 'steps') return true;
      if (m == 'voice') return capabilities.canRecordVoice;
      return capabilities.canRecordScreen;
    }).toList();
  }

  /// Submit. Returns the issue id, or null when it could not be filed —
  /// callers show the reporter a failure, never a stack trace.
  Future<String?> report({
    required String description,
    String reportType = 'bug',
    String? name,
    String? email,
    List<StagedFile> attachments = const [],
  }) =>
      client.report(
        description: description,
        reportType: reportType,
        name: name,
        email: email,
        route: observer.currentRoute,
        attachments: attachments,
      );

  /// Remove every global handler this SDK installed. Rarely needed in an app;
  /// essential in a test, and in a host that swaps portals at runtime.
  void dispose() {
    recorder.cancel();
    _unbind();
    client.close();
  }
}

/// `unawaited` without importing dart:async at every call site.
void unawaited(Future<void> future) {
  // ignore: avoid_catches_without_on_clauses
  future.catchError((Object _) {});
}
