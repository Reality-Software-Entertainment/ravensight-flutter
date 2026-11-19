# Flutter: feasibility against the SDK contract

Checked on 2026-11-06, with identify and campaign links added on
2026-11-19, against the Dart and Flutter API references
(`dart:io` `HttpClient`, `gzip` and `File`, `package:path_provider`,
`package:crypto`, `package:http`, `package:web`, `AppLifecycleListener`,
`FlutterError.onError`, `PlatformDispatcher.onError`). Neither Flutter nor
the Dart SDK was installed where this was written, so nothing here has been
compiled or run yet: every verdict is "documented", and the tests in
`packages/ravensight_core/test` and `test/` are written but unrun. CI runs
them (`dart test` for the pure core, `flutter test` for the package).

## The shape

Two packages in one repository:

- `packages/ravensight_core`: pure Dart, no Flutter. Sessions, batching, the
  saved queue, retries, signing, error capture limits, exposure and the
  typed helpers, with the transport, storage, clocks, random and gzip
  injected. Tested with `dart test` against a fake network and a fake clock.
- `ravensight` (the root): the Flutter package games add. It wires the core
  to `dart:io` or the browser, the app lifecycle and the error hooks.

## Verdicts

| Contract need | API | Verdict |
|---|---|---|
| HTTP with custom headers and a body | `dart:io` `HttpClient` on Android, iOS, macOS, Windows and Linux; `package:http` (the browser's fetch) on the web. | Possible. 15 seconds per request; a failure or timeout is status 0. On the web, `Retry-After` is readable only if the API exposes it to scripts (a CORS header). |
| Persistent storage | `getApplicationSupportDirectory()` (`path_provider`) plus `dart:io` files; `localStorage` on the web. | Possible. One file per name under `<application support>/ravensight`, written to a temporary file and renamed over the old one; where a rename cannot replace (it can on every documented platform), the old file is removed first and a read falls back to the temporary file. Leftover temporary files are removed at start. |
| gzip | `dart:io` `gzip.encode`. | Possible on every native platform. Web: bodies go plain (the contract's SHOULD). |
| HMAC-SHA256 | `package:crypto` `Hmac(sha256, key)`. | Possible; the delivery vectors are in the core tests. |
| Random bytes for the device id and nonce | `Random.secure()`. | Possible on every platform, the web included. |
| Quit hook | `AppLifecycleListener.onExitRequested` on desktop; `AppLifecycleState.detached`. | Possible on desktop: `game_exited` and up to 1.5 seconds for the last batch before the app exits. Mobile apps are not told when they are killed; see the background rule. |
| Background hook | `AppLifecycleState.paused` and `hidden`, `resumed`. | Possible: on iOS and Android the queue is saved, a flush starts and a marker is written; back after 30 minutes is `game_exited` at the time it left plus a new session, and a marker found at a cold start sends that `game_exited` under its own session's origin. |
| Device fields | `Platform.operatingSystemVersion` is a free-form string, not the OS version alone; the device model needs a platform plugin. | Degraded: none are sent unless the game passes `device:` (for example from a device info plugin). The platform name is sent. |
| Error capture | `FlutterError.onError`, `PlatformDispatcher.instance.onError`. | Possible: both chain to the handler that was there (the platform dispatcher returns the previous handler's answer, or false so the engine still reports the error). The SDK's own frames are never captured. No log hook, so no trail. No pending crash records: a Dart error does not end the process. |
| Keeping the queue out of backups | iOS needs a resource value on the file; there is no Dart API for it. | Degraded: the queue in Application Support may be included in an iOS device backup. |
| JSON that escapes correctly | `dart:convert`. | Possible. Event size is measured as the server measures it (the vectors). |
| Identify (salted account hash) | `package:crypto` `Hmac(sha256, utf8.encode(salt))` over `utf8.encode(accountId)`; UTF-8 byte length from `utf8.encode`; the hash saved through the same storage as the device id. | Possible; the identify vectors (version 2) are in the core tests. `accountId` is a `String`, so the contract's `not_text` and whole number cases cannot occur: the compiler refuses them. |
| Campaign links | `Uri.base` is the page address on the web; Android, iOS and desktop apps get the address they were opened with from their own deep link handling. | Possible: the web reads `rs_link` once at init through the platform layer; other platforms pass it to `setCampaignLink`. |
| Packaging | A git dependency on the public repository at a tag. `ravensight` depends on `ravensight_core` by a relative path, which pub resolves inside the same git checkout. | Possible. Nothing is published to a package registry: both pubspecs say `publish_to: none`. |

## Contract items degraded

1. No device model or OS version unless the game passes them.
2. Web bodies are never gzip compressed.
3. No log trail, and no pending crash records.
4. On iOS the saved queue is not excluded from device backups.
5. On the web, `Retry-After` needs the API to expose the header to scripts.
6. A mobile app killed in the foreground sends no `game_exited`.

This SDK has no playtest mode, so the identify and campaign link rules for
a playtest run (memory only, nothing sent) have nothing to act on.

## Before release

1. Run `dart test` in `packages/ravensight_core` and `flutter test` at the
   root, and fix what the first compile finds.
2. Run the example on Android, iOS, macOS, Windows and the web against a
   staging key: a session, a batch, a 429 `Retry-After`, offline then
   relaunch with the origin, opt-out, and the background rule.
3. Tag the release on the public repository (the install snippet pins
   `ref: v0.2.0`). Nothing is published to a package registry.
