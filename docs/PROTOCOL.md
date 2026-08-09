# The Algo Widget mobile wire protocol

What every SDK in this repo speaks, and the one document to read before changing any of them. The
server side lives in AlgoSoft OS (`apps/web/app/api/widget/*`); this is its client contract.

Two implementations exist — Dart and TypeScript — because there is no way to have one. They are kept
adjacent, and **any change here lands in both in the same commit**.

## 0. The shape

Four calls. Three of them are the same three the web widget makes; only the first differs.

```
POST /api/widget/session   → a short-lived ticket           (differs on mobile — see §1)
POST /api/widget/files     → stage evidence, get a fileId   (x-widget-token)
POST /api/widget/report    → create the issue               (x-widget-token)
POST /api/widget/crash     → file an unattended crash       (x-widget-token)
```

`x-widget-token` is the ticket from §1 on every call after it. Tickets last 30 minutes; re-mint
rather than caching one across a session.

## 1. Session — and why mobile is different

The web widget's `pk_…` key is an identifier, not a secret: it ships in customer HTML. What makes
that safe is that the **browser** writes an `Origin` header the page cannot forge, so the server
checks key *and* origin.

A native app has no Origin and cannot forge a substitute — the key ships inside an artifact anyone
can unzip. So the app proves itself with a **platform attestation** bound to a **server-issued
challenge**, and the exchange is two calls:

```jsonc
// 1 — name yourself, get a challenge
POST /api/widget/session
{ "key": "pk_…", "client": { "platform": "android", "appId": "com.acme.orders" } }

→ 401 { "challenge": "<opaque>", "exp": 1234567890123 }

// 2 — come back with a token minted against that challenge
POST /api/widget/session
{ "key": "pk_…",
  "client": { "platform": "android", "appId": "com.acme.orders",
              "challenge": "<opaque>", "attestation": "<Play Integrity token>",
              "app": { "appVersion": "3.2.1", "buildNumber": "451",
                       "osVersion": "Android 14", "deviceModel": "Pixel 8", "locale": "en-US" } } }

→ 200 { "token": "…", "exp": …, "portal": { … } }
```

A 401 carrying a `challenge` is **not an error** — it is step one. Treat it as such: an SDK that
surfaces it to the user has misread the protocol.

The `appId` in the body is a **lookup key, never an identity**. The server compares it against what
the attestation reports and uses the attestation's answer. Sending a different one does not get you
that app's data; it gets you a refusal.

### Challenge rules

- Bound to `(portal, platform, appId)` — a challenge for one app cannot be spent proving another.
- Short-lived (~2 minutes). Request the attestation immediately; do not cache challenges.
- Opaque. Do not parse it.

### Attestation, per platform

| platform | token | notes |
|---|---|---|
| `android` | Play Integrity | request with the challenge as the nonce |
| `ios` | App Attest | **server support is not shipped yet** — see below |

**iOS today**: the server refuses `attestation: 'required'` for iOS. An iOS app can only obtain a
session from a portal whose registration sets `attestation: 'off'`. That is an explicit, audited
downgrade an admin makes in AlgoSoft OS, not something an SDK can arrange.

### Attestation off

When the portal registration sets `attestation: 'off'`, call 1 returns a ticket directly — no
challenge, no token. The SDK does not decide this and cannot detect it in advance; it simply handles
both replies:

```
200 + token      → proceed
401 + challenge  → attest, then call again
401 without a challenge, or 403 → a real refusal; surface it in logs, never to the end user
```

### Refusals

| status | meaning | what an SDK should do |
|---|---|---|
| 401 + `challenge` | not an error — step one | attest and retry once |
| 401 no challenge | challenge expired | request a fresh one, retry once |
| 403 | attestation rejected, or portal disabled | log; do not retry |
| 404 | unknown portal, unregistered app, or disabled — deliberately uniform | log; do not retry |
| 409 | the registration is misconfigured (e.g. Android with no fingerprint) | log the message; it names the fix |
| 429 | portal hourly cap spent | back off; do not retry this session |

**Never surface a session failure to the end user.** A reporter pressing "report a problem" and being
shown an attestation error learns nothing they can act on. Log it, and hide the entry point.

## 2. Staging evidence

`POST /api/widget/files`, `multipart/form-data`, ticket in `x-widget-token`.

The part is named **`files`** — plural, and repeatable up to six per request. The route reads
`getAll('files')`; a part named `file` gets a `400 {"error":"no files"}`.

```jsonc
→ 200 {
  "ok": true,
  "uploaded": [ { "fileId": "…", "filename": "trace.json", "kind": "trace" } ],
  "rejected": [ { "filename": "huge.mp4", "reason": "too large (max 60 MB for video)" } ]
}
```

**A 200 does not mean accepted.** A per-file rejection comes back in `rejected` beside whatever
succeeded — one bad attachment must never fail a whole submission — so an SDK checks the arrays, not
the status. Evidence that goes missing is reported to the host, never swallowed.

The STORED content type is derived server-side from the **extension**; what the client declares is
only checked for agreement with it. Name files correctly.

Caps (server-enforced; an SDK should enforce them too, so a reporter is told before the upload):

| kind | max | accepted extensions |
|---|---|---|
| image | 10 MB | `png` `jpg` `jpeg` `gif` `webp` |
| audio | 25 MB | `m4a` `aac` `mp3` `wav` `weba` `ogg` `oga` |
| video | 60 MB | `mp4` `mov` `3gp` `3gpp` `webm` |
| trace | 512 KB | `json` |

**Prefer `.m4a` for audio.** It is AAC-in-MP4, which both platforms write natively and which the
transcription service accepts by name with no re-encode. `.aac` and `.3gp` are accepted but cost a
server-side transcode.

Six attachments per report.

## 3. The interaction trace

A JSON document, staged like any other file, describing what the reporter did. ~50 KB against a
video's ~50 MB, and it is the part the fix is actually derived from.

```jsonc
{
  "v": 1,
  "startedAt": 1712345678901,       // epoch ms — the clock the trace, narration and video share
  "durationMs": 42000,
  "page": { "route": "/orders/:id", "title": "Order detail" },
  "client": { "kind": "android", "framework": "flutter" },
  "events": [ … ],                  // ascending by t; the server sorts anyway
  "dropped": 0                      // events the head+tail rule discarded
}
```

`page` must carry **`route`** (mobile) or `url` (web). Never both, and never a synthetic `app://…`
URL — a fabricated address is indistinguishable downstream from a real one.

### Events

`t` is milliseconds since `startedAt` on every event.

| type | fields | when |
|---|---|---|
| `click` | `el`, `x`, `y` | a tap. **Not** a separate `tap` type — one vocabulary for both clients |
| `input` | `el` | a field was typed into. **Never the value** |
| `submit` | `el` | a form submitted |
| `nav` | `from`, `to`, `cause: 'user' \| 'app'` | a screen transition. `cause` separates a tap from a router guard |
| `key` | `key` | a non-character key |
| `scroll` | `el`, `dy` | coalesced |
| `resize` | `w`, `h` | orientation change |
| `console` | `level: 'error' \| 'warn'`, `message` | a logged error |
| `request` | `method`, `path`, `status`, `ms` | a **failed** request only. No headers, bodies or query strings |
| `visibility` | `hidden` | the app went to the background or came back |
| `gesture` | `gesture`, `el` | `swipe \| long_press \| pinch \| back \| shake` |
| `mark` | `label` | the retention marker |

`gesture: 'back'` matters more than it looks: Android's system back is a **navigation the app never
sees as a control**, and without it a reproduction reads as though the reporter teleported.

### The element descriptor (`el`)

An identity **ladder** — fill in what you can, best rung first. The point is not to identify a pixel;
it is to hand an AI agent a string it can grep for in the repository.

| rung | Flutter | React Native | Android | iOS |
|---|---|---|---|---|
| `testid` | `Key('…')` / `Semantics(identifier:)` | `testID` | `Modifier.testTag` | `accessibilityIdentifier` |
| `id` | — | `nativeID` | resource entry name | restoration id |
| `component` | widget runtime type | component `displayName` | composable / class | view / class |
| `role` | `SemanticsRole` | `accessibilityRole` | a11y node role | traits |
| `label` | `Semantics(label:)` | `accessibilityLabel` | `contentDescription` | `accessibilityLabel` |
| `tag` | `ElevatedButton` | `Pressable` | `MaterialButton` | `UIButton` |
| `text` | visible text — **redaction rules apply** | | | |
| `path` | depth-capped widget-tree path | | | |

### Caps

| | |
|---|---|
| events | 500 (keep the first 150 and last 350, insert one `mark`) |
| duration | 15 minutes |
| document | 512 KB |
| `text` | 80 chars · `path` 256 · `message` 200 · attribute 120 |

An over-cap event array is **rejected**, not truncated — head+tail retention is the recorder's job.

### Versioning

The server accepts a **range**. Unknown event types are dropped and counted, unknown keys are
stripped. Both exist because an SDK is an app-store artifact that a server deploy cannot roll
forward.

**This does not license a client-side bump.** `v` above `TRACE_VERSION` is still refused, so the
server ships first, always. Raising `v` in an SDK before the server knows it means every recording
from every installed copy is refused.

## 4. Report

```jsonc
POST /api/widget/report
{ "description": "…",                 // required, ≤4000
  "reportType": "bug" | "feature" | "question",
  "name": "…", "email": "…",          // optional, unverified, display-only
  "page": "/orders/42",               // the screen route
  "app": { "appVersion": …, "buildNumber": …, "osVersion": …, "deviceModel": …, "locale": … },
  "attachments": [ { "fileId": …, "filename": … } ] }   // NOT the staging response echoed back

→ 200 { "issueId": "…" }
```

An attachment ref is `{ fileId, filename }`. A staging response echoed back verbatim is refused:
`kind` is tolerated, but `name` / `contentType` / `size` are not fields this route accepts.

`app` here is descriptive only. The identity half (platform, appId) is taken from the ticket, so
there is no point sending it and no way to spoof it.

## 5. Crash

Filed with nobody watching, so the rules differ from a report in two ways: arrays are **sliced**
rather than rejected, and the client throttles itself.

```jsonc
POST /api/widget/crash
{ "v": 1, "at": 1712345678901,
  "error": { "kind": "error" | "unhandledrejection" | "boundary",
             "name": "StateError", "message": "…", "stack": "…" },
  "page": { "route": "/orders/:id", "title": "…" },
  "console": [ { "level": "error", "message": "…", "at": … } ],   // last 20 before the crash
  "requests": [ { "method": …, "path": …, "status": …, "ms": …, "at": … } ],  // last 10 failed
  "app": { "appVersion": …, "buildNumber": …, "osVersion": …, "deviceModel": …,
           "online": true, "memoryMb": 128 } }
```

`kind` maps cleanly and needs no mobile-specific value:

| kind | Flutter | React Native | Android | iOS |
|---|---|---|---|---|
| `error` | uncaught | uncaught | uncaught exception | `NSSetUncaughtExceptionHandler` |
| `unhandledrejection` | unhandled `Future` | unhandled promise | unhandled coroutine | unhandled task |
| `boundary` | `FlutterError.onError` | `ErrorUtils` handler | caught, screen replaced | caught, screen replaced |

### Client throttles — required, not optional

The server dedupes by signature and reserves crashes a quarter of the portal's hourly cap, but an
unattended writer must not lean on that:

- one burst per launch (a screen that throws 40 times in a second is one crash);
- one report per **route**, keyed on the route **read at crash time** — not at launch. An app
  navigates for the whole life of its process, so a per-launch budget is silently a
  per-session-of-the-user's-day budget, and one screen's crash suppresses another's;
- a 30-minute cooldown per crash signature.

### Persistence

The process is dying. Write the payload to app-private storage and send it **on next launch** —
attempting a network call inside an uncaught-exception handler is a race the handler usually loses.

## 6. Privacy — not negotiable, and not "improvable"

These are product guarantees, and the SDK is where they are kept or broken. A customer's security
team can read this repository; that is why it is public.

- **Values are never captured.** The trace records *that* a field was typed into. There is no code
  path that reads a field's value, and adding one is a product decision, not a refactor.
- **Nothing is captured before Record is pressed.** No always-on ring buffer, ever. The one exception
  is crash capture's console/request rings, which hold shapes and statuses — never values.
- **Requests carry no headers, no bodies, no query strings.**
- **Screen recording stops at the reporter's Stop**, and never starts without the platform's own
  consent dialog.
- **Host kill switches are honoured.** The embedding app can disable recording, crash capture and
  query capture, and the SDK must obey regardless of portal configuration.

## 7. Deploy order

Server first, always. The trace and crash version ceilings are server constants; a client ahead of
the server is refused, and on mobile "refused" means every installed copy until users update.

## 8. The panel bridge

The four HTTP calls above are only half of what an SDK speaks. The report UI itself is not
reimplemented per platform: it is the **same page the web widget serves** — `/widget/frame` on the OS
host — loaded in a WebView, and the SDK plays the part the web loader plays on a customer's page.
The messages have the same names in both directions and the frame cannot tell which client it is
talking to, which is the property that keeps one form, one draft store and one annotation editor
serving every platform.

Two things about the transport are load-bearing, and each of them has cost a shipped release.

**The frame is posted OBJECTS.** It reads `event.data.type` directly, because a web postMessage hands
it a structured clone. A WebView bridge has no structured clone — all it can inject is source text —
so `postToFrame` builds the payload as a JSON string *literal* (a reporter's apostrophe stays data)
and parses it back before posting:

```js
(window.__algoPost || window.postMessage)(JSON.parse("{…}"), '*');
```

Posted as the string, `data.type` is `undefined` and the frame drops **every** message the SDK sends:
the panel loads, waits for an `init` it has already been given, and sits on "Loading…" forever, with
a Close button that does nothing. The frame now also parses a string, so a build shipped before that
fix still works — but tolerance is not the contract, and one wire shape is what keeps the frame free
of a per-client branch.

**The frame must be able to HEAR the SDK**, which needs the shim (`frameShim`). The frame answers
with `window.parent.postMessage(...)` — right on the web, where it is an iframe talking to the
loader. In a WebView `window.parent === window`, so the call reaches no native channel at all. The
shim patches `window.postMessage` to forward to the channel while still delivering in-page, and it
**must run before the page's own scripts**: `ready` is announced once, as the frame mounts, which can
precede the load event. Both panels also re-answer on load, because a missed `ready` would otherwise
be unrecoverable.

### What the SDK sends

| message | when | notes |
|---|---|---|
| `init` | on `ready` | `{token, exp, page, portal}`. No token ⇒ send nothing: the frame renders no form without one. |
| `identity` | after `init` | Its own message. Nested inside `init` it is ignored. |
| `record-capabilities` | after `init` | Its own message, same reason. `{steps, voice, screen}`, ANDed by the frame with the portal's opt-in. |
| `record-started` | recording begins | `{mode, maxMs}` |
| `record-tick` | ~1 s while recording | `{ms, maxMs, events}` — **elapsed and cap**, not a remainder; the frame renders `2:31 left` itself. |
| `record-result` / `record-cancelled` / `record-error` | recording ends | |
| `snip-error` | a screenshot failed | |
| `attached` | a native capture was staged | **The frame does not implement this yet** — see below. |

### What the frame sends

`ready`, `size`, `close`, `fullscreen`, `snip-request`, `record-start`, `record-stop`, `submitted`.
Anything unrecognised is ignored rather than fatal: the frame ships continuously and an older app
will meet messages it has never heard of.

### Known gap: `attached`

The frame's attachments are local files it stages itself, and it has no case for one that is
*already* on the server — which is what a native screenshot or recording produces. The message is
currently dropped. It is unreachable in practice (a capture needs a `NativeCapture`, and none ships
yet), but a caller that wires one up will see the capture succeed and no card appear. The frame half
lands with the native one; the name and shape are settled here so both sides are written against the
same thing.
