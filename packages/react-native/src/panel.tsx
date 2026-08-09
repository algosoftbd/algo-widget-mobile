// The report panel, as a React Native component.
//
// A SHELL on purpose. Everything that can be wrong — the init payload, the
// recording lifecycle, staging a capture, the cancel guarantee — lives in
// `PanelSession`, which is driven message-by-message in tests with no device.
// What is left here is a WebView, a ref and a timer.
//
// Behind a subpath (`@algosoftltd/algo-widget-react-native/panel`) rather than the
// main entry, so an app that builds its own report UI never pulls in React or
// react-native-webview, and so the core stays runnable by `node --test` with no
// build step.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { AlgoWidget } from './algoWidget.ts';
import type { NativeCapture } from './capture.ts';
import { frameShim, frameUrl } from './frameBridge.ts';
import { PanelSession, TICK_MS } from './panelController.ts';

/** The bits of `react-native-webview`'s API this component uses. Structural, so
 *  the package is a peer dependency an app already has rather than one this SDK
 *  forces on every consumer. */
export interface WebViewLike {
  injectJavaScript: (js: string) => void;
}

export interface AlgoWidgetPanelProps {
  widget: AlgoWidget;
  /** `WebView` from react-native-webview. Passed in rather than imported so
   *  this file has no hard dependency on it — an Expo app and a bare app
   *  resolve it differently, and neither should be forced. */
  WebView: React.ComponentType<{
    ref?: React.Ref<WebViewLike>;
    source: { uri: string };
    onMessage: (event: { nativeEvent: { data: string } }) => void;
    injectedJavaScriptBeforeContentLoaded?: string;
    onLoadEnd?: () => void;
    style?: unknown;
    originWhitelist?: string[];
    javaScriptEnabled?: boolean;
    mediaPlaybackRequiresUserAction?: boolean;
  }>;
  native?: NativeCapture | null;
  readFile: (path: string) => Promise<Uint8Array>;
  identity?: { name?: string; email?: string };
  onClose?: () => void;
  onSubmitted?: (issueId: string | null) => void;
  style?: unknown;
}

export function AlgoWidgetPanel({
  widget,
  WebView,
  native = null,
  readFile,
  identity,
  onClose,
  onSubmitted,
  style,
}: AlgoWidgetPanelProps) {
  const ref = useRef<WebViewLike | null>(null);
  const [, setHeight] = useState(0);

  const session = useMemo(
    () =>
      new PanelSession({
        widget,
        native,
        readFile,
        // The ref is read at CALL time, not captured: the first messages arrive
        // before the WebView has mounted its ref in some versions, and dropping
        // them would leave the panel un-initialised and blank.
        send: (js) => ref.current?.injectJavaScript(js),
        ...(identity ? { identity } : {}),
        ...(onClose ? { onClose } : {}),
        ...(onSubmitted ? { onSubmitted } : {}),
        onHeight: setHeight,
      }),
    [widget, native, readFile, identity, onClose, onSubmitted],
  );

  // Disposing is not optional: a panel unmounted mid-recording must stop the
  // capture, or the platform's recording indicator stays on with nothing left
  // to stop it.
  useEffect(() => () => void session.dispose(), [session]);

  // The countdown the reporter watches. Driven here rather than inside the
  // session so that module owns no timer and no test has to wait on one.
  useEffect(() => {
    const id = setInterval(() => session.tick(), TICK_MS);
    return () => clearInterval(id);
  }, [session]);

  const onMessage = useCallback(
    (event: { nativeEvent: { data: string } }) => void session.handle(event.nativeEvent.data),
    [session],
  );

  // A SECOND chance at init. The frame sends `ready` once, on mount; if that
  // arrives before the bridge is listening the panel waits forever on a message
  // that will never be repeated. Sending init again on load costs one redundant
  // message and removes an unrecoverable state — the frame treats a second init
  // as a config refresh, which is what the web loader already does.
  const onLoadEnd = useCallback(
    () => void session.handle({ type: 'algo-widget:ready' }),
    [session],
  );

  const uri = frameUrl(widget.client.host, widget.client.portal ?? { accentColor: null });

  return (
    <WebView
      ref={ref}
      source={{ uri }}
      onMessage={onMessage}
      // BEFORE the page's scripts: the frame announces `ready` as soon as React
      // mounts, which can precede the load event.
      injectedJavaScriptBeforeContentLoaded={frameShim('window.ReactNativeWebView.postMessage')}
      onLoadEnd={onLoadEnd}
      javaScriptEnabled
      // The panel plays back nothing, but a voice note recorded through it is
      // reviewed in place before sending — and a gesture requirement would make
      // that silently do nothing.
      mediaPlaybackRequiresUserAction={false}
      // The frame is served from the OS host and navigates nowhere else. This
      // is the boundary that keeps a customer's app from being a browser.
      originWhitelist={[new URL(uri).origin]}
      style={style}
    />
  );
}
