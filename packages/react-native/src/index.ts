// Algo Widget for React Native — public API.
//
// Five calls and one component. Everything else in this package is an
// implementation detail, and everything exported here is something an app
// author is expected to hold in their head.
export {
  AlgoWidgetClient,
  type AttestationProvider,
  type ClientOptions,
} from './client.ts';
export { TraceRecorder, stripQuery, type RecorderOptions } from './recorder.ts';
export {
  CrashReporter,
  crashSignature,
  isIgnorableCrash,
  type CrashOptions,
  type CrashStore,
} from './crash.ts';
export {
  TRACE_VERSION,
  CRASH_VERSION,
  MAX_ATTACHMENTS,
  MAX_BYTES,
  applyRetention,
  kindForFilename,
  normalizeElement,
  type AppFacts,
  type CrashKind,
  type CrashReport,
  type Framework,
  type Gesture,
  type Platform,
  type PortalConfig,
  type SessionResult,
  type StagedFile,
  type Ticket,
  type Trace,
  type TraceElement,
  type TraceEvent,
  type TracePage,
} from './protocol.ts';
export { elementFromProps, type ReactNativeElementProps } from './element.ts';
export {
  bindAll,
  bindConsole,
  bindCrashHandler,
  bindNetwork,
  bindRejectionHandler,
  makeNavigationTracker,
  shapeOf,
  type BindOptions,
  type Sinks,
  type Unbind,
} from './bindings.ts';
