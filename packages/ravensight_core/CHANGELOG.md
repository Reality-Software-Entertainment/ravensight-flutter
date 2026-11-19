# Changelog

## 0.2.0 - 2026-11-19

Identify needs a Ravensight server with `POST /identify` and `identify.salt`
on the session answer; until then identify sends nothing.

### Added

- `RavensightCore.identify(accountId)` (null when accepted, else `empty`,
  `too_long` or `looks_like_email`), `resetIdentity()` and `isIdentified`,
  with the pure helpers `identifyRefusal` and `identifyAccountHash`
  (HMAC-SHA256 from `package:crypto`). The hash and its salt are saved as
  `identity` beside the device id and sent once per session as
  `POST /api/v1/identify`, never through the event queue. Tested against
  the identify vectors, version 2.
- `RavensightCore.setCampaignLink(linkId)`, `campaignLink` and the pure
  `campaignLinkId`: the link goes lowercased as `campaignLink` on the next
  session request and is cleared only by a session answer with a token.

### Changed

- Nightly and on-demand CI, the pre-push hook and the preview README, as in
  the `ravensight` package.
- `resetDeviceId()` ignores a session answer still in flight for the old
  id, and before the opt-in yes it forgets the old id without making a new
  one. Without a key it does nothing.

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
