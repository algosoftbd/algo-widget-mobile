# @algosoftltd/algo-widget-react-native

In-app bug reporting for React Native apps. A user reports a problem from inside
your app — text, screenshot, voice narration, screen recording, and a recorded
**interaction trace** — and reports land in
[AlgoSoft OS](https://github.com/algosoftbd) as first-class issues.

Part of [algo-widget-mobile](https://github.com/algosoftbd/algo-widget-mobile).
The wire contract is in
[PROTOCOL.md](https://github.com/algosoftbd/algo-widget-mobile/blob/main/docs/PROTOCOL.md).

## `testID` is the whole trick

The **interaction trace** is the part a fix is derived from, and every event
names the element it touched through an identity ladder. React Native has the
best top rung of any platform, because `testID` is a literal string in your own
source:

```tsx
<Pressable testID="submit_order" onPress={save}>
  <Text>Save</Text>
</Pressable>
```

That string travels from the tap, through the trace, into the reproduction
steps, and ends up as something an agent greps for in your repository. If your
components already carry `testID`s, you are most of the way there.

## Privacy

Not negotiable, and checked in CI rather than promised in prose:

- the trace records **that** a field was typed into, never what — there is no
  code path that reads a value;
- nothing is captured before Record is pressed. No always-on buffer, ever;
- requests carry no headers, no bodies and no query strings;
- `cancel()` discards everything on-device.

## Usage

```ts
import { AlgoWidgetClient, TraceRecorder } from '@algosoftltd/algo-widget-react-native';

const client = new AlgoWidgetClient({
  host: 'https://os.example.com',
  portalKey: 'pk_…',
  platform: 'android',
  appId: 'com.acme.orders',
  app: { appVersion: '3.2.1', buildNumber: '451' },
  attest: (challenge) => PlayIntegrity.token(challenge),
});

// null means the portal will not have us — hide the report button, never show
// an error a reporter cannot act on.
const ticket = await client.session();
if (!ticket) return;

const rec = new TraceRecorder({
  platform: 'android',
  framework: 'react_native',
  maxSeconds: ticket.portal.recordingMaxSeconds,
});
rec.start('/orders/42');
rec.tap({ testid: 'orders_refresh' });
rec.request('POST', '/api/orders/42', 500, 240);

const trace = await client.stageTrace(rec.stop());
await client.report({
  description: 'Saving an order shows a spinner forever.',
  route: '/orders/42',
  attachments: trace ? [trace] : [],
});
```

Register your app first in AlgoSoft OS — **Settings → Algo Widget → Mobile
apps** — with its package name / bundle id and, on Android, **both** signing
certificate fingerprints.

## Licence

Apache-2.0.
