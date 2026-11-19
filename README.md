# Ravensight for Flutter

Player analytics for Flutter games: sessions, events, retention, levels,
purchases, errors, ads and attribution, remote config and experiments,
sent to [Ravensight](https://ravensight.io). Android, iOS, macOS, Windows,
Linux and the web.

Preview: not yet verified inside a Flutter app; tested with `dart test` and
`flutter test` in CI.

Version 0.1.0. It was written where no Flutter or Dart SDK was installed,
so CI is where it is compiled and tested. See
[docs/FEASIBILITY.md](docs/FEASIBILITY.md).

## Install

Nothing is published to a package registry. Add the public repository as
a git dependency, pinned to its tag:

```yaml
dependencies:
  ravensight:
    git:
      url: https://github.com/Reality-Software-Entertainment/ravensight-flutter
      ref: v0.2.0
```

The SDK's pure Dart core, `packages/ravensight_core`, comes from the same
repository and tag. `ravensight` depends on it by a relative path, and pub
resolves a relative path inside a git dependency from that same checkout,
so there is nothing else to add. From a local clone, use
`path: ../ravensight-flutter` in place of `git:`.

## Use

```dart
import 'package:flutter/widgets.dart';
import 'package:ravensight/ravensight.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Ravensight.init(ingestKey: 'gt_live_...', gameVersion: '1.2.0');
  runApp(const MyGame());
}

// anywhere
Ravensight.levelStart('forest_1');
Ravensight.track('boss_defeated', {'boss': 'troll', 'time_s': 93});
```

Without an `ingestKey` the SDK is inert: no files, no network, every call a
no-op. Pass `optional: true` to silence the one warning that prints.

The key is publishable: it ships inside your build.

## Options

| Option | Default | What it does |
|---|---|---|
| `ingestKey` | required | Your game's key. Empty means inert. |
| `gameVersion` | `'1.0.0'` | Sent on every session. |
| `apiUrl` | `https://api.ravensight.io` | With or without `/api/v1`. |
| `consent` | `RavensightConsent.optOut` | `optIn` sends nothing, and makes no device id, until `setTrackingEnabled(true)`. |
| `captureErrors` | `true` | Automatic error capture (see "Errors"). |
| `distribution` | none | A short store label, such as `'google_play'`. |
| `device` | none | `{'model': ..., 'osVersion': ..., 'gpu': ...}` if you want them on the session; nothing is probed. |
| `maxQueueSize` | `500` | Unsent events kept, oldest dropped first. |
| `flushInterval` | 2 seconds | How long an event waits to be batched. |
| `sessionTimeout` | 30 minutes | Time in the background (iOS, Android) after which a return is a new session. |
| `debug` | `false` | Print informational lines. |

## Functions

| Function | What it does |
|---|---|
| `track(name, data)` | Queue an event. `data` is a flat map. |
| `levelStart`, `levelComplete`, `death` | Events with the reserved `rs_kind` the Levels view reads. |
| `trackPurchase`, `trackResource`, `trackProgression` | Typed events. Purchase amounts are whole minor units (499 is 4.99). |
| `trackError(message, severity:, stack:, errorType:)` | An error the game reports. |
| `trackAd`, `trackAdRevenue` | Ads; revenue in micros. |
| `microsFromRevenue(double)`, `microsFromDecimalString(text)` | Revenue in micros without a float multiply. |
| `setAttribution(source:, ...)` | Where this install came from, once per install. |
| `fetchConfig()`, `getConfig(key, fallback)` | Remote config. A read is what counts as seeing an experiment. |
| `submitFeedback(message, category:, rating:)` | Player feedback. |
| `flush()` | Send now. Never cuts a server's `Retry-After` short. |
| `quit()` | `game_exited`, then up to 1.5 seconds for the last batch. Desktop window closes call it for you. |
| `setTrackingEnabled(on)`, `isEnabled` | The player's choice, saved at once. |
| `resetDeviceId()`, `deviceId`, `statusReason`, `deliveryStats` | Identity and state. |
| `on(listener)` | The SDK's events; returns an unsubscribe function. |

## Delivery

Unsent events are saved in a file per key under the app's support folder
(the browser's storage on the web), with the session each one belongs to,
and sent on the next launch under that session. Every event carries an
`rs_event_id`, so a resend is never counted twice. Bodies of 1 KB or more
go gzip compressed (not on the web), and a session that gives a signing
secret has every batch signed.

On iOS and Android, going to the background saves and flushes; back after
30 minutes, `game_exited` is recorded at the time the player left and a new
session starts.

## Errors

With `captureErrors` on (the default), Flutter framework errors and uncaught
errors are captured, after the handlers your app already has, which still
run exactly as before. Captures are scrubbed on the device first (emails,
tokens, keys, addresses, home folders, URL queries), capped at 30 a
session, 3 for one error and 6 a minute, and sent only while the game's
error capture switch is on. There is no log trail.

## Privacy

What is sent:

- A random device id made on first launch and kept on the device. It is not
  derived from hardware or an account.
- On each session: that id, your game version, the platform (`android`,
  `ios`, `macos`, `windows`, `linux`, `web`), the SDK name and version, your
  `distribution` label if set, and the `device` fields only if you pass them.
- The events your code tracks, with their time and an `rs_event_id`.
- Automatic error captures, scrubbed first.

Saved on the device: the device id, unsent events, the player's choice, a
background marker on mobile, the remote config cache and whether
attribution was sent.

The player's choice: `setTrackingEnabled(false)` stops sending, drops the
queue and is saved. `RavensightConsent.optIn` sends nothing until the player
says yes. `resetDeviceId()` starts over with a new id.

## Running the tests

```
cd packages/ravensight_core && dart pub get && dart analyze && dart test
cd ../.. && flutter pub get && flutter analyze && flutter test
```

Install the local checks once per clone: `git config core.hooksPath .githooks`. The pre-push hook then runs this repository's tests before every push, with a time limit, and refuses the push if they fail. CI runs nightly and on demand, not on pushes or pull requests, so this hook is where a change is checked first.

The hook needs the Dart SDK for the core tests, and runs the package tests
too when Flutter is on PATH. `sh .githooks/test-pre-push.sh` tests the
hook's refuse paths.

## License

MIT. See [LICENSE](LICENSE).
