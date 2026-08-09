# Releasing

Versions, changelogs and tags come from the commits — see *Cutting a release*.
Tags are **per package**, because the packages have different release cadences
and forcing them to move together would mean publishing a Dart package to fix a
Kotlin bug. What keeps them compatible is the wire contract, and what keeps the
contract honest is CI's `contract` job — a shared version number would only look
like a guarantee.

```
react-native-v0.1.0   → npm      @algosoftltd/algo-widget-react-native
flutter-v0.1.0        → pub.dev  algo_widget
```

The workflow checks the tag against the manifest **before** publishing, because
neither registry lets you replace a published version. A mismatch fails the run
rather than shipping a wrong number.

## Registry setup

Both registries are configured. Kept here because neither could be done from
inside this repository, and both would have to be redone on a new one.

### npm — done

`NPM_TOKEN` is set and the `release` environment exists. Two things cost a
failed run each while setting this up, and are worth knowing if the token is
ever rotated:

- a scoped `PUT` npm cannot place answers **404, not 403** — it does not leak
  whether an org exists, so "not found" can mean the org, the token's scope, or
  a granular token limited to *existing* packages;
- an org with 2FA enforced refuses an ordinary token with *"Two-factor
  authentication or granular access token with bypass 2fa enabled is required"*.
  CI has nobody to tap a phone: use a **Classic → Automation** token, which
  exists for exactly this.

The workflow publishes with `--provenance`, so the package carries a signed,
verifiable link back to this repository and the exact commit — worth having on a
package that customers install into their own apps.

### pub.dev — done

There is no publish secret in this repository at all: pub.dev authenticates the
workflow by OIDC. The package was published manually once (pub.dev cannot
configure automation for a package that does not exist yet), and its admin page
now has **Automated publishing → GitHub Actions** enabled for
`algosoftbd/algo-widget-mobile` with the tag pattern `flutter-v{{version}}`.

**`workflow_dispatch` events must be enabled there**, because that is how this
repo publishes — see the section above on why the dispatch has to run against
the tag ref.

## Cutting a release

Nobody edits a version by hand. **Version** (`.github/workflows/version.yml`)
runs on every push to `main`, reads the conventional commits since the last tag
and does the rest — the same action and the same shape the AlgoSoft OS repo
uses, with one difference this repo forces.

That difference is `git-path`. Two packages sit on independent version lines, so
the action runs once per package, scoped to its own directory: a commit touching
only `packages/flutter` bumps `algo_widget` and leaves the npm package
untouched.

They are **two jobs, not two steps**, and that cost a spurious release to learn.
The action bumps the version file *before* deciding whether there is anything to
release, and it commits with `git add .` — so with both packages in one job, the
package with nothing to release still had its manifest bumped, and the other
package's release commit swept that bump up. The result was a React Native
manifest reading `0.1.1` with no tag, no changelog and no release, buried inside
a Flutter release commit. Separate jobs mean separate working trees.

They run sequentially (`needs:`) because both push to `main` and the loser of a
race gets a non-fast-forward — intermittently, which is the worst kind of
release failure to diagnose.

**The changelog is generated, not written.** `release-count` means *preserve N
releases* — it truncates rather than protects, so no setting keeps hand-written
prose in the file. That is the tool working as designed: `CHANGELOG.md` is a
function of the commits, which is why the commits are worth writing carefully.
Prose that deserves to survive goes in the **GitHub release notes**, which are
permanent and are what a customer arriving from npm or pub.dev actually reads —
see the `0.1.0` releases.

**Tag every published version, even one published by hand.** A missing baseline
tag is why the first automated run proposed `flutter-v0.2.0` for a package whose
`0.1.0` was already on pub.dev: with no `flutter-v*` tag to bound from, the
action read the entire history, found the `feat:` commits that went into `0.1.0`
and bumped the minor. Both packages now have a `v0.1.0` tag on the commit whose
tree was published.

Write commits that say what they did, and the version follows:

| commit | effect |
|---|---|
| `fix(rn): …` | patch |
| `feat(rn): …` | minor |
| `feat!: …` or a `BREAKING CHANGE:` footer | major |
| `docs:`, `chore:`, `test:` | nothing — `skip-on-empty` keeps the workflow silent |

The run bumps the manifest, writes the CHANGELOG, commits with `[skip ci]` (so
it does not retrigger itself), tags, and opens a **draft** GitHub release
carrying the generated notes.

## Publishing

**Version does not publish.** Both registries refuse to replace a published
version, so the gap between tagging and publishing is the last place a wrong
number is still free — read the draft release, then publish deliberately:

```bash
gh workflow run release.yml --repo algosoftbd/algo-widget-mobile \
  --ref react-native-v0.1.1
```

or pick the tag in the **Run workflow** ref selector.

**Run it against the TAG, not against `main` with the tag as an input.** That is
not tidiness: pub.dev authenticates the run by OIDC and checks the ref the
workflow ran *for* against its configured tag pattern. A workflow dispatched on
`main` presents a claim that says `main`, and checking the tag out afterwards
does not change what the token says — pub.dev refuses it. The jobs guard on
`refs/tags/…` so a dispatch on a branch is refused here first, with a clearer
result than a registry rejection.

The workflow re-checks the tag against the manifest before publishing, so a tag
that disagrees with `package.json` or `pubspec.yaml` fails the run rather than
shipping the wrong number.

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
