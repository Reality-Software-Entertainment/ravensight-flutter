/// Ravensight player analytics for Flutter games: sessions, events,
/// retention, levels, purchases, errors, ads and attribution, remote config
/// and experiments.
///
/// ```dart
/// await Ravensight.init(ingestKey: 'gt_live_...', gameVersion: '1.2.0');
/// Ravensight.track('level_start', {'level': 'forest_1'});
/// ```
library;

import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:ravensight_core/ravensight_core.dart';

import 'src/platform/platform.dart' as platform;

export 'package:ravensight_core/ravensight_core.dart' show RsListener, scrubText, microsFromDecimalString, microsFromRevenue, adFormatFrom, adFormats, adResults, sdkVersion;

/// The player's consent model.
enum RavensightConsent {
  /// On until the player opts out (the default).
  optOut,

  /// Nothing is sent, and no device id is made, until the player opts in.
  optIn,
}

/// The Ravensight SDK. Every method is static and safe to call before
/// [init] or without a key: it then does nothing.
class Ravensight {
  Ravensight._();

  static RavensightCore? _core;
  static Timer? _timer;
  static AppLifecycleListener? _lifecycle;
  static bool _debug = false;
  static bool _starting = false;
  static FlutterExceptionHandler? _previousFlutterError;
  static ErrorCallback? _previousPlatformError;
  static bool _hooksInstalled = false;

  /// How long a quit waits for the last batch.
  static const Duration quitTimeout = Duration(milliseconds: 1500);

  /// Starts the SDK. Call once, after `WidgetsFlutterBinding.ensureInitialized()`
  /// or from `main` before `runApp`. Completes with true when collecting.
  ///
  /// Without an [ingestKey] the SDK is inert: no files, no network. Pass
  /// [optional] to silence the one warning that prints.
  static Future<bool> init({
    required String? ingestKey,
    String gameVersion = '1.0.0',
    String? apiUrl,
    RavensightConsent consent = RavensightConsent.optOut,
    bool captureErrors = true,
    String? distribution,
    Map<String, String> device = const {},
    int maxQueueSize = maxPersistedEvents,
    Duration flushInterval = const Duration(seconds: 2),
    Duration sessionTimeout = const Duration(minutes: 30),
    bool debug = false,
    bool optional = false,
  }) async {
    if (_core != null || _starting) return isEnabled;
    final key = (ingestKey ?? '').trim();
    _debug = debug;
    if (key.isEmpty) {
      if (!optional) debugPrint('Ravensight: no ingestKey, analytics are off (pass optional: true to silence this)');
      return false;
    }
    _starting = true;
    try {
      WidgetsFlutterBinding.ensureInitialized();
      final storage = await platform.openStorage();
      final random = Random.secure();
      final stopwatch = Stopwatch()..start();
      final core = RavensightCore(
        CoreConfig(
          ingestKey: key,
          apiUrl: apiUrl,
          gameVersion: gameVersion,
          platform: platform.platformName(),
          osName: platform.osName(),
          consent: consent == RavensightConsent.optIn ? 'opt_in' : 'opt_out',
          maxQueueSize: maxQueueSize,
          flushIntervalSeconds: flushInterval.inMilliseconds / 1000,
          captureErrors: captureErrors,
          distribution: distribution,
          device: device,
          mobile: platform.isMobile(),
          sessionTimeoutSeconds: sessionTimeout.inSeconds,
        ),
        CoreDeps(
          transport: platform.httpTransport(),
          storage: storage,
          wallMs: () => DateTime.now().millisecondsSinceEpoch,
          monotonicSeconds: () => stopwatch.elapsedMicroseconds / 1e6,
          random: random.nextDouble,
          randomHex: (bytes) => List.generate(bytes, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join(),
          gzip: platform.gzipEncoder(),
          log: _log,
        ),
      );
      _core = core;
      core.start();
      _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => core.tick());
      _lifecycle = AppLifecycleListener(
        onStateChange: _onLifecycle,
        onExitRequested: () async {
          await _quit();
          return AppExitResponse.exit;
        },
      );
      if (captureErrors) _installErrorHooks();
      return isEnabled;
    } finally {
      _starting = false;
    }
  }

  static void _log(String level, String message) {
    if (level == 'info' && !_debug) return;
    debugPrint(message.startsWith('Ravensight') ? message : 'Ravensight: $message');
  }

  static void _onLifecycle(AppLifecycleState state) {
    final core = _core;
    if (core == null) return;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        if (core.config.mobile) {
          core.enterBackground();
        } else {
          core.saveQueue();
          core.flush();
        }
      case AppLifecycleState.resumed:
        core.enterForeground();
      case AppLifecycleState.detached:
        unawaited(_quit());
      case AppLifecycleState.inactive:
        break;
    }
  }

  static Future<void> _quit() async {
    final core = _core;
    if (core == null) return;
    try {
      await core.quit().timeout(quitTimeout);
    } catch (_) {
      // Out of time: the queue is saved and goes on the next launch.
      core.saveQueue(stopping: true);
    }
  }

  /// Records `game_exited`, sends the last events (up to 1.5 seconds) and
  /// saves the rest. Desktop window closes call this for you; call it
  /// yourself before your own exit path.
  static Future<void> quit() => _quit();

  // ------------------------------------------------------------- errors

  /// Automatic capture: Flutter framework errors and uncaught errors from
  /// the platform dispatcher. Both chain to the handler that was there, so
  /// the app behaves exactly as before.
  static void _installErrorHooks() {
    if (_hooksInstalled) return;
    _hooksInstalled = true;
    _previousFlutterError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      _captureThrown(details.exception, details.stack);
      final previous = _previousFlutterError;
      if (previous != null) {
        previous(details);
      } else {
        FlutterError.presentError(details);
      }
    };
    _previousPlatformError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      _captureThrown(error, stack);
      final previous = _previousPlatformError;
      return previous != null ? previous(error, stack) : false;
    };
  }

  static void _captureThrown(Object error, StackTrace? stack) {
    final core = _core;
    if (core == null) return;
    try {
      final stackText = stack?.toString();
      // Never the SDK's own errors.
      if (stackText != null && stackText.contains('package:ravensight/')) return;
      core.captureError(ErrorInfo(
        message: error.toString(),
        stack: stackText,
        source: 'uncaught',
        severity: 'error',
        errorType: error.runtimeType.toString(),
      ));
    } catch (_) {
      // Capture never throws into the app.
    }
  }

  // ------------------------------------------------------------- events

  /// Queues an event. `data` is a flat map of JSON values. Returns false
  /// when tracking is off or the event is over 8 KB as JSON.
  static bool track(String name, [Map<String, Object?>? data]) => _core?.track(name, data) ?? false;

  /// A level started, completed, or the player died: an event with the
  /// reserved `rs_kind` the Levels view reads without setup.
  static bool levelStart(String level, [Map<String, Object?>? data]) => track('level_start', {...?data, 'rs_kind': 'level_start', 'level': level});
  static bool levelComplete(String level, [Map<String, Object?>? data]) => track('level_complete', {...?data, 'rs_kind': 'level_complete', 'level': level});
  static bool death(String level, [Map<String, Object?>? data]) => track('death', {...?data, 'rs_kind': 'death', 'level': level});

  /// A real-money purchase. [amountMinor] is whole minor units: 499 is 4.99.
  static bool trackPurchase({required int amountMinor, required String currency, required String itemType, required String itemId, String? cart, String? transactionId, String event = 'purchase'}) =>
      track(event, {
        'rs_kind': 'purchase',
        'rs_amount': amountMinor,
        'rs_currency': currency.toUpperCase(),
        'rs_item_type': itemType,
        'rs_item_id': itemId,
        if (cart != null) 'rs_cart': cart,
        if (transactionId != null) 'rs_transaction_id': transactionId,
      });

  /// A virtual resource gained (`source`) or spent (`sink`).
  static bool trackResource({required String flow, required String resource, required num amount, String? itemType, String? itemId}) => track('resource_$flow', {
        'rs_kind': 'resource',
        'rs_flow': flow,
        'rs_resource': resource,
        'rs_amount': amount,
        if (itemType != null) 'rs_item_type': itemType,
        if (itemId != null) 'rs_item_id': itemId,
      });

  /// Progression: `start`, `complete` or `fail`, up to three levels deep.
  static bool trackProgression({required String status, required String p1, String? p2, String? p3, num? score}) => track('progression_$status', {
        'rs_kind': 'progression',
        'rs_status': status,
        'rs_p1': p1,
        if (p2 != null) 'rs_p2': p2,
        if (p3 != null) 'rs_p3': p3,
        if (score != null) 'rs_score': score,
      });

  /// An error the game reports itself. Severity: debug, info, warning,
  /// error or critical. Sent as written; the server scrubs it.
  static bool trackError(String message, {String severity = 'error', String? stack, String? errorType}) =>
      _core?.trackError(severity, message, stack: stack, errorType: errorType) ?? false;

  /// One ad step. Revenue only with result `shown`, always with a currency.
  /// Returns false, sending nothing, for a value the server would flag.
  static bool trackAd(String network, String format, String result, {String? placement, String? revenueMicros, String? currency}) {
    final built = adEvent(network, format, result, placement: placement, revenueMicros: revenueMicros, currency: currency);
    if (built.data == null) {
      _log('warn', 'ad event not sent: ${built.reason}');
      return false;
    }
    return track('rs_ad', built.data);
  }

  /// A paid impression. Convert a mediation callback's double with
  /// [microsFromRevenue], never by multiplying it.
  static bool trackAdRevenue(String network, String format, String? placement, String revenueMicros, String currency) =>
      trackAd(network, format, 'shown', placement: placement, revenueMicros: revenueMicros, currency: currency);

  /// Where this install came from. Sent once per install.
  static bool setAttribution({required String source, String? network, String? campaign, String? adset, String? creative, int? touchTime}) {
    final result = _core?.setAttribution(source: source, network: network, campaign: campaign, adset: adset, creative: creative, touchTime: touchTime);
    if (result != null && !result.sent && result.reason != 'already_sent') _log('warn', 'attribution not sent: ${result.reason}');
    return result?.sent ?? false;
  }

  /// Sends now. Never cuts a server's Retry-After short.
  static Future<void> flush() => _core?.flush() ?? Future<void>.value();

  // --------------------------------------------------------------- config

  /// Fetches this device's remote config: completes with network, cache or
  /// default.
  static Future<String> fetchConfig() => _core?.fetchConfig() ?? Future<String>.value('default');

  /// A config value, or [fallback] when missing or of another type. Reading
  /// it is what counts as seeing a running experiment.
  static T getConfig<T>(String key, T fallback) => _core?.getConfig<T>(key, fallback) ?? fallback;

  // -------------------------------------------------------------- privacy

  /// The player's choice, saved at once. False stops sending and drops the
  /// queue; with [RavensightConsent.optIn], true is the player's yes.
  static void setTrackingEnabled(bool enabled) => _core?.setTrackingEnabled(enabled);

  /// True only while collecting.
  static bool get isEnabled => _core?.isTrackingEnabled ?? false;

  /// A fresh random device id; the queue and the session are dropped.
  static String? resetDeviceId() => _core?.resetDeviceId();

  /// This install's random device id, or null before consent or without a key.
  static String? get deviceId {
    final id = _core?.deviceId;
    return id == null || id.isEmpty ? null : id;
  }

  /// Why nothing is being sent (disabled, invalid_key, tracking_disabled,
  /// offline, rate_limited, session_failed), or null when ready.
  static String? get statusReason => _core == null ? 'disabled' : _core!.statusReason;

  /// Events let go of since launch.
  static Map<String, int> get deliveryStats => Map.of(_core?.deliveryStats ?? const {});

  /// Player feedback. Completes with null when sent, else the reason.
  static Future<String?> submitFeedback(String message, {String? category, int? rating}) =>
      _core?.submitFeedback(message, category: category, rating: rating) ?? Future<String?>.value('disabled');

  /// Subscribe to the SDK's events: session_ready, session_failed,
  /// status_changed, tracking_disabled, events_flushed, flush_failed,
  /// event_tracked, config_ready, feedback_submitted, feedback_failed.
  static void Function() on(RsListener listener) => _core?.on(listener) ?? () {};

  /// For tests: stops everything so [init] can run again.
  @visibleForTesting
  static void reset() {
    _timer?.cancel();
    _lifecycle?.dispose();
    if (_hooksInstalled) {
      FlutterError.onError = _previousFlutterError;
      PlatformDispatcher.instance.onError = _previousPlatformError;
    }
    _hooksInstalled = false;
    _timer = null;
    _lifecycle = null;
    _core = null;
  }
}
