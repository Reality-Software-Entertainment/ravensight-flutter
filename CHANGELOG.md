# Changelog

## 0.2.0 - 2026-11-19

Identify needs a Ravensight server with `POST /identify` and `identify.salt`
on the session answer; until then identify sends nothing.

### Added

- `Ravensight.identify(accountId)`, `Ravensight.resetIdentity()` and
  `Ravensight.isIdentified` for games with their own login. Only a salted
  hash of the id (`accountHash`, HMAC-SHA256 keyed with the game's salt from
  the session answer) is sent, with the session token, once per session; the
  raw id is never sent or saved and is held in memory only until the salt is
  known. The hash is saved beside the device id (`ravensight_identity` in
  the browser's storage). An id that is empty, over 256 bytes of UTF-8 or
  contains `@` is refused: `false` and one warning with the reason, never a
  throw. A different account first resets the identity, which also switches
  to a fresh device id; `resetDeviceId()` alone keeps it. A failed or
  refused request is tried again at the next session, never in a loop, and
  two `no_session` answers in a row stop it until `resetIdentity()`.
  Without a key or before an opt-in yes nothing is saved or sent, and
  opting out deletes the saved hash.
- `Ravensight.setCampaignLink(linkId)` passes a Ravensight campaign link on
  from an app's own deep link handling. A link id (24 hex characters, sent
  lowercased) goes as `campaignLink` on the next session the SDK opens, and
  is cleared only when that session answers with a token. Returns `true`,
  or `false` and one warning naming `invalid_link`. Memory only, with the
  same consent and key rules as everything else. On the web the SDK reads
  `rs_link` from the page address once, at `init`.

### Changed

- The README marks the SDK as a preview (not yet verified inside a Flutter
  app; tested with `dart test` and `flutter test` in CI) and installs it as
  a git dependency on the public repository at tag `v0.2.0`; nothing is
  published to a package registry. CI runs nightly on weekdays and on
  demand instead of on every push, and a pre-push hook in `.githooks` runs
  the tests first.
- `resetDeviceId()` ignores a session answer still in flight for the old
  id, and before the opt-in yes it forgets the old id without making a new
  one.

## 0.1.0 - 2026-11-06

### Added

- First release, version 0.1.0: `ravensight` for Flutter and its pure Dart
  core, `ravensight_core`.
- Delivery contract: queue format 2 with origins, saved atomically per key,
  500 events and 89 days; `rs_event_id` on every event; the response table,
  backoff from 10 seconds doubling to 300 with jitter, `Retry-After` exact;
  gzip at 1,024 bytes on native platforms; HMAC-SHA256 signatures.
- Error capture through `FlutterError.onError` and
  `PlatformDispatcher.onError`, chained, scrubbed (scrub vectors version 6)
  and capped; the shared error queue rules.
- Typed events, ads with micros, attribution once per install, remote config
  with exposure tags, feedback.
- The mobile background rule and a desktop quit hook.
