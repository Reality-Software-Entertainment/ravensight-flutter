# Ravensight for Flutter

Player analytics for Flutter games: sessions, events, retention, levels,
purchases, errors, ads and attribution, remote config and experiments,
sent to [Ravensight](https://ravensight.io). Android, iOS, macOS, Windows,
Linux and the web.

Preview: not yet verified inside a Flutter app; tested with `dart test` and
`flutter test` in CI.

Version 0.2.0. It was written where no Flutter or Dart SDK was installed,
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
| `distribution` | none | A short label for where this build is distributed, such as `'direct'`. |
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
| `resetDeviceId()`, `deviceId`, `statusReason`, `deliveryStats` | Identity and state. `resetDeviceId()` keeps a signed-in account. |
| `identify(accountId)` | Link this device to your game's own account after sign-in. `true`, or `false` and one warning for a refused id. See "Identify players who sign in". |
| `resetIdentity()` | On sign-out: forget the account and switch to a fresh device id. |
| `isIdentified` | `true` while an account is set by `identify()`. |
| `setCampaignLink(linkId)` | Send a Ravensight campaign link id with the next session. `true`, or `false` and one warning naming `invalid_link`. On the web the SDK reads it from the page address itself. See "Campaign links". |
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

## Identify players who sign in

If your game has its own login, call `identify()` once the player signs in
and `resetIdentity()` when they sign out. One person on two devices, or
before and after signing in, then counts as one player.

```dart
Ravensight.identify(account.analyticsId); // after your own sign-in: a random id stored with the account
Ravensight.resetIdentity();               // on sign-out
```

- **What is sent:** a salted hash of the id (`accountHash`, 64 hex
  characters, keyed with your game's own salt from the session answer) and
  the session token, once per session. The raw account id, an email or a
  name is never sent and never saved; until the first session answer the id
  is held in memory only.
- **Pass a random, high-entropy id**, such as a random UUID or a random
  analytics id you make once for each account and store with it, never a
  sequential database key, an email, a name or a handle. Your game's salt
  reaches every copy of the game, so anyone could hash 1, 2, 3 and onward
  and match a guessable id; a random one cannot be guessed. The hash is
  still a pseudonymous identifier for the player: declare it in your game's
  privacy notice.
- **A refused id changes nothing.** An id that is empty, over 256 bytes of
  UTF-8 or contains `@` is refused: `identify()` returns `false` and prints
  one warning with the reason (`empty`, `too_long` or `looks_like_email`).
  It never throws. The id is used exactly as given, never trimmed or
  lower-cased. `accountId` is a `String`, so a number goes as its digits.
- **One event per identified session** on your usage balance. The same
  account again in the same session sends nothing; a refused or failed
  request is tried once more at the next session, never in a loop. Two
  `no_session` answers in a row stop it until `resetIdentity()`.
- **A different account** on the same device first does `resetIdentity()`,
  which deletes the saved hash and switches to a fresh device id (as
  `resetDeviceId()` does), so the next player is not linked to the last
  one. `resetDeviceId()` alone keeps the identity.
- The hash is saved beside the device id (`identity` in the SDK's folder,
  `ravensight_identity` in the browser's storage). It never enters the
  event queue and never delays an event. Without a key, before `init`, or
  before an opt-in yes it is held in memory only; `setTrackingEnabled(false)`
  deletes it.
- **Needs a Ravensight server that offers identify.** A session answer
  without the game's salt, or a 404, leaves identify off until the next
  launch, and nothing is sent.

## Campaign links

A Ravensight campaign link adds `rs_link=<link id>` to the address it
redirects to (web destinations only).

- **Web: nothing to call.** The SDK reads `rs_link` from the page address
  once, at `init`, and sends it as `campaignLink` with the first session it
  opens. The address is left as it is.
- **Android, iOS and desktop: pass it on yourself**, from your own deep link
  handling, with the `rs_link` value of the address your app was opened
  with. Call `setCampaignLink()` before `init` if you can; a later call goes
  with the next session the SDK opens.

```dart
// In your own deep link handler, with the address the app was opened by:
final link = Uri.parse(openedAddress).queryParameters['rs_link'];
if (link != null) Ravensight.setCampaignLink(link);
```

`setCampaignLink(linkId)` returns `true` when the value is a link id (24 hex
characters, in any case), which then replaces a link still waiting. For
anything else it returns `false`, prints one warning naming `invalid_link`,
and nothing changes. The id goes lowercased, as `campaignLink`, on the
session:

- **Sent once.** Only a session answer with a token clears it, so a failed
  attempt keeps it for the next one. Later sessions carry none.
- **Same consent as everything else.** With `RavensightConsent.optIn` it
  goes with the first session after the player's yes. An opted out player,
  or a game without a key, sends nothing.
- **Nothing is stored.** The id is one your studio made, not personal data.
- The server keeps it only when it names a link of the same game. The
  player and the session are then counted on the Campaign links page, by
  link, and those players open in Player insights.

This SDK has no playtest mode, so the playtest rules for identify and
campaign links (memory only, nothing sent) have nothing to act on.

## Privacy

What is sent:

- A random device id made on first launch and kept on the device. It is not
  derived from hardware or an account.
- On each session: that id, your game version, the platform (`android`,
  `ios`, `macos`, `windows`, `linux`, `web`), the SDK name and version, your
  `distribution` label if set, and the `device` fields only if you pass them.
- The events your code tracks, with their time and an `rs_event_id`.
- Automatic error captures, scrubbed first.
- **A salted hash of your own account id**, only when your game calls
  `identify()`, once per session (see "Identify players who sign in").
- **A campaign link id**, once, on the first session after it is read from
  the page address or set with `setCampaignLink()` (see "Campaign links").
- No advertising identifier, no names, no emails: there is no field for
  them, and `identify()` refuses any value containing `@`.

Saved on the device: the device id, unsent events, the player's choice, a
background marker on mobile, the remote config cache, whether attribution
was sent, and the salted account hash while a player is identified.

The player's choice: `setTrackingEnabled(false)` stops sending, drops the
queue, deletes the account hash and is saved. `RavensightConsent.optIn`
sends nothing until the player says yes. `resetDeviceId()` starts over with
a new id; `resetIdentity()` also forgets the signed-in account.

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
