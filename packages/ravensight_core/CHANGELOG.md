# Changelog

## Unreleased

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
