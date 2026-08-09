# Releasing

Tags are **per package**, because the packages have different release cadences
and forcing them to move together would mean publishing a Dart package to fix a
Kotlin bug. What keeps them compatible is the wire contract, and what keeps the
contract honest is CI's `contract` job — a shared version number would only look
like a guarantee.

```
react-native-v0.1.0   → npm      @algosoft/algo-widget-react-native
flutter-v0.1.0        → pub.dev  algo_widget
```

The workflow checks the tag against the manifest **before** publishing, because
neither registry lets you replace a published version. A mismatch fails the run
rather than shipping a wrong number.

## One-time setup

Neither registry is configured yet, and neither can be from inside this
repository — both need an account action.

### npm

1. On npmjs.com, create the `@algosoft` org (or confirm it exists) and add
   whoever will own the package.
2. Create a **Granular Access Token** scoped to `@algosoft/*` with
   *Read and write*.
3. Add it here as the repository secret **`NPM_TOKEN`**
   (Settings → Secrets and variables → Actions).
4. Create the `release` **environment** (Settings → Environments). The workflow
   requires it, which is what lets you put an approval gate in front of a
   publish if you want one.

The workflow publishes with `--provenance`, so the package carries a signed,
verifiable link back to this repository and the exact commit — worth having on a
package that customers install into their own apps.

### pub.dev

pub.dev prefers **automated publishing** over a long-lived credential, and the
result is that there is no publish secret in this repository at all:

1. Publish `algo_widget` manually **once**, from a machine logged in with
   `dart pub login` — pub.dev cannot configure automation for a package that
   does not exist yet.
2. On the package's admin page, enable **Automated publishing → GitHub Actions**,
   set the repository to `algosoftbd/algo-widget-mobile` and the tag pattern to
   `flutter-v{{version}}`.
3. Everything after that is the tag.

## Cutting a release

```bash
# 1. bump the manifest and write the changelog entry in the same commit
#    packages/react-native/package.json  ·  packages/flutter/pubspec.yaml
# 2. merge to main, wait for CI
# 3. tag
git tag react-native-v0.1.0 && git push origin react-native-v0.1.0
git tag flutter-v0.1.0     && git push origin flutter-v0.1.0
```

## Before the first release

Both packages are honest at `0.1.0` — the client API is complete and an app can
build its own report UI against it today — but two things in the README are
promises rather than facts, and the CHANGELOG says so:

- the **native capture layer** (screen, voice, screenshot) is an interface with
  a Kotlin/Swift core behind it and no module registration yet;
- the **WebView host** that presents the report panel has its bridge but not its
  widget.

Until those land, an app integrating this SDK writes its own report UI. That is
a reasonable 0.1.0 and an unreasonable thing to discover after installing, which
is why it is at the top of the README rather than in a footnote.
