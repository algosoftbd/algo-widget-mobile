// The report panel, as a Flutter widget.
//
// A SHELL on purpose, exactly like the React Native one. Everything that can be
// wrong — the init payload, the recording lifecycle, staging a capture, the
// cancel guarantee — lives in [PanelSession], which is driven message-by-message
// in tests with no device. What is left here is a WebView, a controller and a
// timer.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'algo_widget_base.dart';
import 'frame_bridge.dart';
import 'panel_controller.dart';

/// Presents the Algo Widget report panel.
///
/// Put it in a sheet, a dialog or a route — the panel sizes itself and asks for
/// the whole screen when its annotation editor needs it ([PanelSession] reports
/// that through `onFullscreen`).
class AlgoWidgetPanel extends StatefulWidget {
  const AlgoWidgetPanel({
    required this.widget,
    required this.readFile,
    super.key,
    this.native,
    this.identity,
    this.onClose,
    this.onSubmitted,
  });

  final AlgoWidget widget;

  /// Read a file the native side produced. Injected so this package needs no
  /// filesystem dependency — an app already has one.
  final Future<Uint8List> Function(String path) readFile;

  final NativeCapture? native;
  final Map<String, String>? identity;
  final void Function()? onClose;
  final void Function(String? issueId)? onSubmitted;

  @override
  State<AlgoWidgetPanel> createState() => _AlgoWidgetPanelState();
}

class _AlgoWidgetPanelState extends State<AlgoWidgetPanel> {
  late final WebViewController _controller;
  late final PanelSession _session;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();

    _session = PanelSession(
      widget: widget.widget,
      native: widget.native,
      readFile: widget.readFile,
      identity: widget.identity,
      onClose: widget.onClose,
      onSubmitted: widget.onSubmitted,
      // The controller is read at CALL time rather than captured, because the
      // first messages can arrive before this State has finished building.
      send: (js) => _controller.runJavaScript(js),
    );

    final url = frameUrl(
      widget.widget.client.host,
      accentColor: widget.widget.client.portal?.accentColor,
    );

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // The panel talks back through one named channel. `postMessage` inside
      // the frame is shimmed onto it below, so the frame's code is identical to
      // the one the web widget runs — it cannot tell which client it is in.
      ..addJavaScriptChannel(
        'AlgoWidgetHost',
        onMessageReceived: (message) =>
            unawaited(_session.handle(message.message)),
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => unawaited(_installShim()),
          // The frame is served from the OS host and navigates nowhere else.
          // This is the boundary that keeps a customer's app from becoming a
          // browser if a link ever appears in the panel.
          onNavigationRequest: (request) {
            final target = Uri.tryParse(request.url);
            final home = Uri.tryParse(url);
            final same =
                target != null && home != null && target.origin == home.origin;
            return same
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
        ),
      )
      ..loadRequest(Uri.parse(url));

    // The countdown the reporter watches. Driven here rather than inside the
    // session so that class owns no timer and no test has to wait on one.
    _ticker = Timer.periodic(kTick, (_) => _session.tick());
  }

  /// Bridge `window.postMessage` onto the named channel.
  ///
  /// Without this the frame would have to know it is in a Flutter WebView. With
  /// it, the page runs the same code it runs on the web — which is the entire
  /// reason the panel is one implementation rather than four.
  Future<void> _installShim() => _controller.runJavaScript('''
    (function () {
      if (window.__algoShim) return;
      window.__algoShim = true;
      var post = window.postMessage.bind(window);
      window.postMessage = function (data, origin) {
        try {
          AlgoWidgetHost.postMessage(typeof data === 'string' ? data : JSON.stringify(data));
        } catch (e) {}
        return post(data, origin);
      };
    })();
  ''');

  @override
  void dispose() {
    _ticker?.cancel();
    // Not optional: a panel disposed mid-recording must stop the capture, or
    // the platform's recording indicator stays on with nothing left to stop it.
    unawaited(_session.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}
