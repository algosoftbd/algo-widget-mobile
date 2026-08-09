// Turning a React Native component into an element descriptor
// (docs/PROTOCOL.md §3).
//
// React Native is the easiest of the four targets for exactly one reason:
// `testID` is a prop the app author already writes, it compiles through to a
// real native attribute on both platforms, and it is a LITERAL STRING IN THEIR
// SOURCE. The whole point of the identity ladder is to hand an AI agent
// something it can grep for, and there is nothing better to hand it than the
// string the developer typed.
//
// Everything below is best-effort by design: an extractor that throws inside a
// customer's app is worse than one that returns a thin descriptor.
import { TRACE_MAX_TEXT_LEN, clampText, type TraceElement } from './protocol.ts';

/** The props worth reading off a touched component. Structural rather than
 *  importing React Native's own types, so this file — and its tests — need no
 *  native runtime. */
export interface ReactNativeElementProps {
  testID?: string;
  nativeID?: string;
  accessibilityLabel?: string;
  accessibilityRole?: string;
  accessibilityHint?: string;
  children?: unknown;
  /** Set by React on the element type; a function or class component's name. */
  displayName?: string;
  name?: string;
}

/** Text nodes are worth capturing — "the reporter tapped the button that said
 *  Save" is how a human reads a reproduction — but ONLY visible labels. A value
 *  never reaches here: this walks `children`, and a TextInput's content is not
 *  a child. */
function visibleText(children: unknown, depth = 0): string | undefined {
  if (depth > 3) return undefined;
  if (typeof children === 'string') return children;
  if (typeof children === 'number') return String(children);
  if (Array.isArray(children)) {
    const parts = children
      .map((c) => visibleText(c, depth + 1))
      .filter((s): s is string => Boolean(s));
    return parts.length > 0 ? parts.join(' ') : undefined;
  }
  if (children && typeof children === 'object' && 'props' in children) {
    const props = (children as { props?: { children?: unknown } }).props;
    return visibleText(props?.children, depth + 1);
  }
  return undefined;
}

/**
 * Build a descriptor, best rung first.
 *
 * `componentName` comes from the fiber when the caller can read it. It is the
 * single most valuable rung after `testID` because it is a FILENAME in the
 * customer's repository — but production bundles routinely minify it, so a name
 * that looks minified is dropped rather than emitted as noise.
 */
export function elementFromProps(
  props: ReactNativeElementProps | undefined,
  componentName?: string,
): TraceElement | undefined {
  if (!props && !componentName) return undefined;
  const el: TraceElement = {};
  if (props?.testID) el.testid = props.testID;
  if (props?.nativeID) el.id = props.nativeID;
  if (componentName && !looksMinified(componentName)) el.component = componentName;
  if (props?.accessibilityRole) el.role = props.accessibilityRole;
  if (props?.accessibilityLabel) el.label = props.accessibilityLabel;

  // Visible text only when no stronger rung named the element — it is the
  // longest field and the least stable across a translation.
  if (!el.testid && !el.id && props?.children) {
    const text = clampText(visibleText(props.children), TRACE_MAX_TEXT_LEN);
    if (text !== undefined) el.text = text;
  }
  return Object.keys(el).length > 0 ? el : undefined;
}

/** A minified display name tells a reader nothing and costs bytes. Heuristic on
 *  purpose: short, and no lowercase-then-uppercase boundary that a real
 *  component name ("QuotationFilters") always has. */
export function looksMinified(name: string): boolean {
  if (name.length <= 2) return true;
  if (name.length > 4) return false;
  return !/[a-z][A-Z]/.test(name);
}
