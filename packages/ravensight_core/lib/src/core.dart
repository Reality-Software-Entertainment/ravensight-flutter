// The SDK's state machine, with no Flutter in it. Everything the outside
// world provides is injected (transport, storage, clocks, random, gzip), so
// sessions, batching, backoff, the kill switch, opt-out, the saved queue,
// signing, exposure and the mobile background rule run under `dart test`
// with a fake clock and a fake network. lib/ravensight.dart wires it to
// Flutter.
//
// The design follows the other Ravensight SDKs, rule for rule (the Lua
// cores of ravensight-love and ravensight-defold are the closest):
//
//   * a random per-install device id, 32 hex characters, a dash and the OS
//   * GET /api/v1/settings at start; the kill switch wins when off
//   * game_started queued at the real start, once; game_exited on quit
//   * POST /api/v1/session, then POST /api/v1/track/batch with at most 50
//     events, every flushInterval seconds or as soon as 50 wait
//   * the delivery contract: a saved queue (format 2, origins, 500 events,
//     89 days), rs_event_id on every event, the response table, backoff
//     from 10 s doubling to 300 s with jitter, Retry-After exact, gzip at
//     1,024 bytes, HMAC signatures when the session gives a secret
//   * the error queue rules: gameplay before captures, a capture never
//     evicts gameplay, no trail on disk
//   * identify: only a salted hash of the game's own account id, sent once
//     per session as POST /api/v1/identify and saved beside the device id,
//     never queued (docs/identify/CONTRACT.md)
//   * a campaign link id, sent once as campaignLink on the next session
//     the core opens, memory only

import 'dart:async';
import 'dart:convert';

import 'errors.dart';
import 'wire.dart';

/// One HTTP request. [body] is the bytes to send (already compressed when
/// a Content-Encoding header says so).
class RsRequest {
  RsRequest(this.method, this.url, this.headers, [this.body]);
  final String method;
  final String url;
  final Map<String, String> headers;
  final List<int>? body;
}

/// One HTTP answer. [status] is 0 for a network failure or a timeout;
/// header names are lower-case.
class RsResponse {
  RsResponse(this.status, [this.body = '', Map<String, String>? headers]) : headers = headers ?? const {};
  final int status;
  final String body;
  final Map<String, String> headers;
}

typedef RsTransport = Future<RsResponse> Function(RsRequest request);

/// Small named files. A write replaces the whole file atomically.
abstract class RsStorage {
  String? read(String name);
  void write(String name, String text);
  void remove(String name);
}

class MemoryStorage implements RsStorage {
  final Map<String, String> files = {};
  @override
  String? read(String name) => files[name];
  @override
  void write(String name, String text) => files[name] = text;
  @override
  void remove(String name) => files.remove(name);
}

/// The SDK's own events, for `Ravensight.on`.
typedef RsListener = void Function(String name, Object? value);

class QueuedEvent {
  QueuedEvent(this.event, this.data, this.timestamp, this.origin);
  final String event;
  final Map<String, Object?> data;
  final int timestamp;
  Map<String, Object?>? origin;
}

class CoreConfig {
  CoreConfig({
    required this.ingestKey,
    this.apiUrl,
    this.gameVersion = '1.0.0',
    this.platform = 'unknown',
    this.osName = 'unknown',
    this.consent = 'opt_out',
    this.maxQueueSize = maxPersistedEvents,
    this.flushIntervalSeconds = 2,
    this.captureErrors = true,
    this.distribution,
    this.device = const {},
    this.mobile = false,
    this.sessionTimeoutSeconds = 1800,
  });
  final String ingestKey;
  final String? apiUrl;
  final String gameVersion;
  final String platform;
  final String osName;
  final String consent;
  final int maxQueueSize;
  final double flushIntervalSeconds;
  final bool captureErrors;
  final String? distribution;
  final Map<String, String> device;
  final bool mobile;
  final int sessionTimeoutSeconds;
}

class CoreDeps {
  CoreDeps({
    required this.transport,
    required this.storage,
    required this.wallMs,
    required this.monotonicSeconds,
    required this.random,
    required this.randomHex,
    this.gzip,
    this.log,
  });
  final RsTransport transport;
  final RsStorage storage;
  final int Function() wallMs;
  final double Function() monotonicSeconds;
  final double Function() random;
  final String Function(int bytes) randomHex;
  final List<int> Function(List<int> bytes)? gzip;
  final void Function(String level, String message)? log;
}

const String deviceIdFile = 'device_id';
const String optOutFile = 'optout';
const String optInFile = 'optin';
const String attributionFile = 'attribution';
const String backgroundFile = 'background.json';
const String configFile = 'config.json';

/// identify: `{"salt", "accountHash"}` as JSON, beside the device id
/// (`ravensight_identity` in the browser's storage). Never the account id.
const String identityFile = 'identity';

final RegExp _deviceIdPattern = RegExp(r'^[0-9a-f]{32}-[a-z0-9]+$');
final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');
final RegExp _experimentKey = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
final RegExp _variantName = RegExp(r'^[a-z][a-z0-9_-]{0,39}$');
final RegExp _etag = RegExp(r'^"[a-f0-9]{64}"$');

class RavensightCore {
  RavensightCore(this.config, this.deps)
      : apiUrl = normalizeApiUrl(config.apiUrl),
        _errorLimiter = ErrorLimiter(deps.monotonicSeconds) {
    device = {};
    config.device.forEach((key, value) {
      if (const ['model', 'osVersion', 'gpu'].contains(key)) {
        final cleaned = deviceField(value);
        if (cleaned != null) device[key] = cleaned;
      }
    });
  }

  final CoreConfig config;
  final CoreDeps deps;
  final String apiUrl;
  late final Map<String, String> device;

  String deviceId = '';
  String sessionToken = '';
  int _sessionExpiresAtMs = 0;
  bool _sessionPending = false;
  int _sessionGeneration = 0;
  bool _settingsPending = false;
  bool trackingEnabled = true;
  bool _serverTrackingEnabled = true;
  bool _playerOptedOut = false;
  bool keyRefused = false;
  bool _started = false;
  bool _identityLoaded = false;
  bool _queueLoaded = false;
  bool _gameStartedQueued = false;
  bool _gameExitedQueued = false;
  final List<QueuedEvent> pending = [];
  double? _firstQueuedAt;
  bool _flushInProgress = false;
  int _inflightSize = 0;
  int _queueGeneration = 0;
  int _splitBatchSize = 0;
  int _backoff = defaultRetrySeconds;
  double? _retryAt;
  bool _sendPlain = false;
  int _reauthAttempts = 0;
  bool _queueDirty = false;
  int _startSeconds = 0;
  String? _eventNonce;
  int _eventCounter = 0;
  bool _warnedTooLarge = false;
  Map<String, Object?>? _sessionOrigin;
  String? _signingSecret;
  int _clockOffsetSeconds = 0;
  String? statusReason;
  final Map<String, int> deliveryStats = {'dropped_overflow': 0, 'dropped_too_old': 0, 'dropped_refused': 0};
  final Map<String, String> _exposed = {};
  Map<String, Object?>? _configDocument;
  String? _configScope;
  bool _configPending = false;
  int _configGeneration = 0;
  Map<String, bool>? errorCapture;
  final ErrorLimiter _errorLimiter;
  final List<(String, Map<String, Object?>)> _bootErrors = [];
  int? _backgroundedAtMs;
  bool quitting = false;
  final List<RsListener> _listeners = [];
  Completer<void>? _flushDone;

  // identify: the saved {salt, accountHash}, or null; a valid account id
  // waiting for the salt or the player's yes (memory only); the salt from
  // this launch's session answers. The generation is bumped whenever the
  // identity is replaced or forgotten, so a late answer changes nothing.
  ({String salt, String accountHash})? _account;
  String? _heldAccountId;
  String? _identifySalt;
  // An answer without a salt (an older server): off until the next launch.
  bool _identifySaltMissing = false;
  // A 404 or invalid_account_hash: not tried again this launch.
  bool _identifyStopped = false;
  // Two no_session answers in a row: stopped until resetIdentity.
  bool _identifyNoSessionStopped = false;
  bool _identifyNoSessionRetried = false;
  String? _identifySentOn;
  int _identifyGeneration = 0;

  // The campaign link waiting for the next session this core opens
  // (24 lowercase hex characters), or null. Memory only.
  String? _campaignLink;

  // ------------------------------------------------------------- events

  void Function() on(RsListener listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void _emit(String name, [Object? value]) {
    for (final listener in List<RsListener>.of(_listeners)) {
      try {
        listener(name, value);
      } catch (_) {
        // A listener's failure is the game's, never the SDK's.
      }
    }
  }

  void _log(String level, String message) => deps.log?.call(level, message);

  void _setReason(String? reason) {
    if (statusReason == reason) return;
    statusReason = reason;
    _emit('status_changed', reason);
  }

  int _nowSeconds() => deps.wallMs() ~/ 1000;

  // ------------------------------------------------------------ lifecycle

  bool get _optedOutSaved => config.consent == 'opt_in' ? deps.storage.read(optInFile) == null : deps.storage.read(optOutFile) != null;

  /// Loads the identity, the player's choice and the saved queue, then
  /// checks the kill switch. Call once.
  void start() {
    if (_started) return;
    _started = true;
    _startSeconds = _nowSeconds();
    if (config.ingestKey.isEmpty) {
      trackingEnabled = false;
      _setReason('disabled');
      return;
    }
    _playerOptedOut = _optedOutSaved;
    trackingEnabled = !_playerOptedOut;
    if (_playerOptedOut) {
      deps.storage.remove(backgroundFile);
      _log('info', config.consent == 'opt_in' ? 'waiting for the player to opt in' : 'tracking disabled by player opt-out');
      _setReason('disabled');
      _emit('tracking_disabled', 'player');
      return;
    }
    _loadIdentity();
    _replayBackgroundMarker();
    _checkServerSettings();
    _queueGameStarted();
  }

  void _queueGameStarted() {
    if (_gameStartedQueued || !trackingEnabled) return;
    _gameStartedQueued = true;
    track('game_started');
  }

  void _loadIdentity() {
    if (_identityLoaded) return;
    _identityLoaded = true;
    final saved = deps.storage.read(deviceIdFile)?.trim();
    if (saved != null && _deviceIdPattern.hasMatch(saved)) {
      deviceId = saved;
    } else {
      deviceId = _newDeviceId();
      deps.storage.write(deviceIdFile, deviceId);
    }
    // The account an earlier launch saved, unless an id is already held
    // (it replaces the saved one once hashed).
    if (_account == null && _heldAccountId == null) _account = _readSavedAccount();
    _loadSavedQueue();
  }

  String _newDeviceId() => '${deps.randomHex(16)}-${config.osName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '')}';

  /// Timers: the retry wait, the batching interval, the end-of-frame save.
  /// Call often (the Flutter binding calls it twice a second).
  void tick() {
    final t = deps.monotonicSeconds();
    final retryAt = _retryAt;
    if (retryAt != null && t >= retryAt) {
      _retryAt = null;
      if (trackingEnabled) {
        if (!isSessionValid) {
          _startSession();
        } else {
          _flushPending();
        }
      }
    }
    final first = _firstQueuedAt;
    if (_retryAt == null && first != null && t - first >= config.flushIntervalSeconds) {
      if (isSessionValid) {
        _flushPending();
      } else if (trackingEnabled && !_sessionPending && !_settingsPending && !keyRefused) {
        // The session expired while events waited.
        _startSession();
      }
    }
    if (_queueDirty) saveQueue();
  }

  // ------------------------------------------------------------- settings

  bool _settingsRequested = false;

  void _checkServerSettings() {
    if (keyRefused || _settingsRequested) return;
    _settingsRequested = true;
    _settingsPending = true;
    _send(RsRequest('GET', '$apiUrl/api/v1/settings', {'X-API-Key': config.ingestKey})).then((res) {
      _settingsPending = false;
      if (keyRefused) return;
      final body = _decode(res.body);
      if (res.status == 200) {
        if (body is Map && body['trackingEnabled'] is bool) _serverTrackingEnabled = body['trackingEnabled'] == true;
        if (body is Map) _adoptErrorCapture(body['errorCapture']);
      } else if (res.status == 403 && _errorOf(body) == 'tracking_disabled') {
        _serverTrackingEnabled = false;
      } else if (res.status == 401 || res.status == 403) {
        _onKeyRefused(res.status);
        return;
      } else {
        _log('warn', 'could not fetch settings (HTTP ${res.status}); assuming tracking enabled');
      }
      _afterSettingsChecked();
    });
  }

  void _afterSettingsChecked() {
    if (keyRefused) return;
    trackingEnabled = _serverTrackingEnabled && !_playerOptedOut;
    if (!_serverTrackingEnabled) {
      _log('info', 'tracking disabled by the server kill switch');
      _clearQueue();
      _setReason('tracking_disabled');
      _emit('tracking_disabled', 'server');
    } else if (trackingEnabled && pending.isNotEmpty && !isSessionValid && !_sessionPending) {
      _startSession();
    }
  }

  // -------------------------------------------------------------- session

  bool get isSessionValid => sessionToken.isNotEmpty && deps.wallMs() < _sessionExpiresAtMs;

  void _startSession() {
    if (!trackingEnabled || _sessionPending || keyRefused) return;
    _sessionPending = true;
    final generation = ++_sessionGeneration;
    final body = <String, Object?>{
      'deviceId': deviceId,
      'gameVersion': config.gameVersion,
      'platform': config.platform,
      'sdk': '$sdkName/$sdkVersion',
    };
    final distribution = config.distribution;
    if (distribution != null && distribution.isNotEmpty) body['distribution'] = distribution;
    if (device.isNotEmpty) body['device'] = device;
    // The player's own session only (this SDK has no playtest mode and no
    // join token), until one answers with a token.
    final campaignLink = _campaignLink;
    if (campaignLink != null) body['campaignLink'] = campaignLink;
    _send(RsRequest('POST', '$apiUrl/api/v1/session', {'Content-Type': 'application/json', 'X-API-Key': config.ingestKey}, utf8.encode(jsonEncode(body))))
        .then((res) => _onSessionResponse(res, generation, campaignLink));
  }

  void _onSessionResponse(RsResponse res, int generation, String? campaignLink) {
    // The campaign link this request carried opened a session, so it is
    // never sent again, even when the answer is otherwise ignored below. A
    // link set while the request was in flight waits for the next session.
    if (campaignLink != null && campaignLink == _campaignLink && res.status == 201) {
      final opened = _decode(res.body);
      if (opened is Map && opened['token'] != null) _campaignLink = null;
    }
    if (generation != _sessionGeneration) return;
    _sessionPending = false;
    final body = _decode(res.body);
    final error = _errorOf(body);
    final retry = retryAfterSeconds(res.headers['retry-after']);
    if (res.status == 201 && body is Map && body['token'] != null) {
      sessionToken = body['token'].toString();
      final expiresIn = body['expiresIn'];
      _sessionExpiresAtMs = deps.wallMs() + (expiresIn is num && expiresIn > 0 ? expiresIn.toInt() : 86400) * 1000;
      _adoptSessionExtras(body);
      _adoptErrorCapture(body['errorCapture']);
      _readIdentifySalt(body);
      _backoff = defaultRetrySeconds;
      _setReason(null);
      _emit('session_ready');
      _flushPending();
      // Never awaited: identify does not hold back the session or an event.
      _sendIdentify();
      fetchConfig();
    } else if (res.status == 201) {
      _setReason('session_failed');
      _emit('session_failed', 'malformed_response');
      _scheduleRetry();
    } else if (res.status == 429 || (res.status == 503 && retry >= 0)) {
      _setReason('rate_limited');
      _emit('session_failed', error.isEmpty ? 'rate_limited' : error);
      _scheduleRetry(retry);
    } else if (res.status == 403 && error == 'tracking_disabled') {
      _emit('session_failed', 'tracking_disabled');
      _onServerTrackingDisabled();
      return;
    } else if (res.status == 401 || res.status == 403) {
      _emit('session_failed', error.isEmpty ? 'http_${res.status}' : error);
      _onKeyRefused(res.status);
      return;
    } else {
      _setReason(res.status == 0 ? 'offline' : 'session_failed');
      _emit('session_failed', error.isNotEmpty ? error : (res.status == 0 ? 'network_error' : 'http_${res.status}'));
      _scheduleRetry();
    }
    _completeFlush();
  }

  /// The session's origin (stored verbatim) and signing secret (memory only).
  /// Events queued before the answer was known adopt its origin.
  void _adoptSessionExtras(Map body) {
    final origin = body['origin'];
    _sessionOrigin = origin is Map ? Map<String, Object?>.from(origin) : null;
    _signingSecret = null;
    final signing = body['signing'];
    if (signing is Map && signing['algorithm'] == 'HMAC-SHA256' && signing['version'] == 1 && signing['secret'] is String) {
      _signingSecret = signing['secret'] as String;
      final serverTime = signing['serverTime'];
      _clockOffsetSeconds = serverTime is num ? serverTime.toInt() - _nowSeconds() : 0;
    }
    if (_sessionOrigin != null) {
      var adopted = false;
      for (final e in pending) {
        if (e.origin == null) {
          e.origin = _sessionOrigin;
          adopted = true;
        }
      }
      if (adopted) _queueDirty = true;
    }
  }

  void _scheduleRetry([int explicitSeconds = -1]) {
    double wait;
    _retryFromServer = explicitSeconds > 0;
    if (explicitSeconds > 0) {
      // Retry-After: exactly, never spread.
      wait = explicitSeconds.toDouble();
    } else {
      final factor = jitterMinFactor + (1 - jitterMinFactor) * deps.random();
      wait = (_backoff < maxBackoffSeconds ? _backoff : maxBackoffSeconds) * factor;
      _backoff = _backoff * 2 > maxBackoffSeconds ? maxBackoffSeconds : _backoff * 2;
    }
    _retryAt = deps.monotonicSeconds() + (wait < 0.5 ? 0.5 : wait);
  }

  /// Seconds until the next retry, or 0.
  double get retryInSeconds {
    final at = _retryAt;
    if (at == null) return 0;
    final left = at - deps.monotonicSeconds();
    return left > 0 ? left : 0;
  }

  bool _retryFromServer = false;

  // --------------------------------------------------------------- events

  /// Queues an event. Returns false when tracking is off or the event is
  /// too large (dropped, warned once).
  bool track(String name, [Map<String, Object?>? data, int? timestampMs, Map<String, Object?>? origin]) {
    if (!trackingEnabled) return false;
    if (name.isEmpty || name.length > maxNameChars) {
      _log('warn', 'event not sent: a name is 1 to $maxNameChars characters');
      return false;
    }
    final queued = _enqueue(name, data ?? const {}, timestampMs, origin);
    if (queued == null) return false;
    _emit('event_tracked', name);
    if (_retryAt != null) return true;
    if (isSessionValid) {
      if (pending.length >= maxBatchSize) _flushPending();
    } else if (!_sessionPending && !_settingsPending) {
      _startSession();
    }
    return true;
  }

  String _nextEventId() {
    _eventNonce ??= deps.randomHex(4);
    _eventCounter += 1;
    return eventId(deviceId, _startSeconds, _eventNonce!, _eventCounter);
  }

  int get _queueCap => config.maxQueueSize < 1 ? 1 : (config.maxQueueSize > maxPersistedEvents ? maxPersistedEvents : config.maxQueueSize);

  int? _firstQueuedError() {
    final floor = _flushInProgress ? _inflightSize : 0;
    for (var i = floor; i < pending.length; i++) {
      if (isAutomaticError(pending[i].data)) return i;
    }
    return null;
  }

  Map<String, Object?>? _enqueue(String name, Map<String, Object?> data, int? timestampMs, Map<String, Object?>? origin) {
    final eventData = Map<String, Object?>.of(data);
    _applyExposureTags(eventData);
    eventData['rs_event_id'] = _nextEventId();
    final int size;
    try {
      size = eventDataBytes(eventData);
    } catch (_) {
      _log('warn', 'event "$name" not sent: its data is not JSON');
      return null;
    }
    if (size > maxEventBytes) {
      if (!_warnedTooLarge) {
        _warnedTooLarge = true;
        _log('warn', 'dropped event "$name": larger than $maxEventBytes bytes as JSON (further drops are not logged)');
      }
      _emit('flush_failed', 'event_too_large');
      return null;
    }
    // The error queue rules: a full queue lets go of the oldest automatic
    // capture first; a capture never pushes out gameplay.
    final automatic = isAutomaticError(eventData);
    while (pending.length >= _queueCap) {
      final oldestError = _firstQueuedError();
      deliveryStats['dropped_overflow'] = deliveryStats['dropped_overflow']! + 1;
      if (automatic && oldestError == null) return null;
      pending.removeAt(oldestError ?? 0);
    }
    var position = pending.length;
    if (!automatic) position = _firstQueuedError() ?? position;
    pending.insert(position, QueuedEvent(name, eventData, timestampMs ?? deps.wallMs(), origin ?? _sessionOrigin));
    _firstQueuedAt ??= deps.monotonicSeconds();
    _queueDirty = true;
    return eventData;
  }

  // ------------------------------------------------------------- flushing

  /// Sends now. Cuts a backoff wait short, never a server's Retry-After.
  Future<void> flush() {
    if (_retryAt != null && !_retryFromServer) _retryAt = null;
    if (_retryAt == null && trackingEnabled && !keyRefused) {
      if (isSessionValid) {
        _flushPending();
      } else if (!_sessionPending && pending.isNotEmpty) {
        _flushDone ??= Completer<void>();
        _startSession();
      }
    }
    if (_sessionPending && pending.isNotEmpty) _flushDone ??= Completer<void>();
    final done = _flushDone;
    return done == null ? Future<void>.value() : done.future;
  }

  void _completeFlush() {
    final done = _flushDone;
    if (done != null && !_flushInProgress && !_sessionPending) {
      _flushDone = null;
      if (!done.isCompleted) done.complete();
    }
  }

  Map<String, Object?> _wireEvent(QueuedEvent e) {
    final out = <String, Object?>{'event': e.event, 'data': e.data, 'timestamp': e.timestamp};
    final origin = e.origin;
    if (origin != null && origin['session'] != _sessionOrigin?['session']) out['origin'] = origin;
    return out;
  }

  void _flushPending() {
    if (!trackingEnabled || keyRefused) return;
    if (_flushInProgress || pending.isEmpty || !isSessionValid) return;
    _flushInProgress = true;
    _flushDone ??= Completer<void>();
    _firstQueuedAt = null;
    var size = pending.length < maxBatchSize ? pending.length : maxBatchSize;
    if (_splitBatchSize > 0 && _splitBatchSize < size) size = _splitBatchSize;
    _inflightSize = size;
    final generation = _queueGeneration;
    final body = jsonEncode({'events': [for (var i = 0; i < size; i++) _wireEvent(pending[i])]});
    final headers = <String, String>{'Content-Type': 'application/json', 'X-Session-Token': sessionToken};
    final secret = _signingSecret;
    if (secret != null) {
      final t = _nowSeconds() + _clockOffsetSeconds;
      headers['X-Ravensight-Timestamp'] = '$t';
      headers['X-Ravensight-Signature'] = 'v1=${signBody(secret, t, body)}';
    }
    List<int> bytes = utf8.encode(body);
    final gzip = deps.gzip;
    if (!_sendPlain && gzip != null && bytes.length >= gzipMinBytes) {
      try {
        bytes = gzip(bytes);
        headers['Content-Encoding'] = 'gzip';
      } catch (_) {
        // Sent plain.
      }
    }
    _send(RsRequest('POST', '$apiUrl/api/v1/track/batch', headers, bytes)).then((res) => _onBatchResponse(res, size, generation));
  }

  void _dropFront(int count) {
    pending.removeRange(0, count < pending.length ? count : pending.length);
    saveQueue();
  }

  void _countRefused(int count, String reason) {
    deliveryStats['dropped_refused'] = deliveryStats['dropped_refused']! + count;
    _log('warn', 'dropped $count event(s) the server refused ($reason)');
    _emit('flush_failed', reason);
  }

  void _onBatchResponse(RsResponse res, int size, int generation) {
    if (generation != _queueGeneration) {
      _completeFlush();
      return;
    }
    _flushInProgress = false;
    _inflightSize = 0;
    final status = res.status;
    final parsed = _decode(res.body);
    final error = _errorOf(parsed);
    if (status != 413 && status != 415) _sendPlain = false;

    if (status >= 200 && status < 300) {
      _dropFront(size);
      _backoff = defaultRetrySeconds;
      _splitBatchSize = 0;
      _reauthAttempts = 0;
      _setReason(null);
      _emit('events_flushed', size);
      if (pending.isNotEmpty) _flushPending();
    } else if (status == 401) {
      sessionToken = '';
      _sessionExpiresAtMs = 0;
      _signingSecret = null;
      _reauthAttempts += 1;
      if (_reauthAttempts <= 1) {
        _log('warn', 'session refused (${error.isEmpty ? 'http_401' : error}), opening a new one');
        _startSession();
      } else {
        _emit('flush_failed', error.isEmpty ? 'http_401' : error);
        _scheduleRetry();
      }
    } else if (status == 403 && error == 'tracking_disabled') {
      _onServerTrackingDisabled();
    } else if (status == 403) {
      _onKeyRefused(status);
    } else if (status == 429 || (status == 503 && retryAfterSeconds(res.headers['retry-after']) >= 0)) {
      _setReason('rate_limited');
      _emit('flush_failed', error.isEmpty ? 'rate_limited' : error);
      _scheduleRetry(retryAfterSeconds(res.headers['retry-after']));
    } else if (status == 400 || status == 413 || status == 415) {
      _onBatchRefused(status, error, parsed, size);
      if (pending.isNotEmpty) _flushPending();
    } else {
      _setReason(status == 0 ? 'offline' : 'session_failed');
      _emit('flush_failed', error.isNotEmpty ? error : (status == 0 ? 'network_error' : 'http_$status'));
      _scheduleRetry();
    }
    _completeFlush();
  }

  void _onBatchRefused(int status, String error, Object? parsed, int size) {
    final reason = error.isNotEmpty ? error : 'http_$status';
    final index = parsed is Map ? parsed['index'] : null;
    if (status == 400 && index is int && index >= 0 && index < size) {
      pending.removeAt(index);
      saveQueue();
      _splitBatchSize = 0;
      _countRefused(1, reason);
      return;
    }
    if (status == 415 || (status == 413 && size <= 1)) {
      if (!_sendPlain) {
        _sendPlain = true;
        return;
      }
      _sendPlain = false;
      _dropFront(size);
      _countRefused(size, reason);
      return;
    }
    final halves = status == 413 || error == 'batch_too_large' || (status == 400 && perEvent400.contains(error));
    if (halves && size > 1) {
      _splitBatchSize = size ~/ 2 < 1 ? 1 : size ~/ 2;
      return;
    }
    _dropFront(size);
    _countRefused(size, reason);
  }

  // ------------------------------------------------------- refusals, kill

  void _onKeyRefused(int status) {
    if (keyRefused) return;
    keyRefused = true;
    _retryAt = null;
    _log('warn', 'Ravensight: ingest key refused (invalid_key), sending stopped for this run. Check your gt_live_ key.');
    saveQueue(stopping: true);
    _setReason('invalid_key');
    _completeFlush();
  }

  void _onServerTrackingDisabled() {
    _serverTrackingEnabled = false;
    trackingEnabled = false;
    _clearQueue();
    _setReason('tracking_disabled');
    _emit('tracking_disabled', 'server');
    _completeFlush();
  }

  void _clearQueue() {
    pending.clear();
    _queueGeneration += 1;
    _flushInProgress = false;
    _inflightSize = 0;
    _firstQueuedAt = null;
    _bootErrors.clear();
    deps.storage.remove(queueFileName(config.ingestKey));
  }

  // ---------------------------------------------------------- saved queue

  void _loadSavedQueue() {
    if (_queueLoaded) return;
    _queueLoaded = true;
    final text = deps.storage.read(queueFileName(config.ingestKey));
    final loaded = <QueuedEvent>[];
    var tooOld = 0;
    final cutoff = deps.wallMs() - queueMaxAgeMs;
    final doc = text == null ? null : _decode(text);
    if (doc is Map && (doc['version'] == 1 || doc['version'] == 2) && doc['groups'] is List) {
      for (final group in doc['groups'] as List) {
        if (group is! Map || group['events'] is! List) continue;
        final origin = doc['version'] == 2 && group['origin'] is Map ? Map<String, Object?>.from(group['origin'] as Map) : null;
        for (final e in group['events'] as List) {
          if (e is! Map || e['event'] is! String || (e['event'] as String).isEmpty || e['timestamp'] is! num) continue;
          final raw = (e['timestamp'] as num).toInt();
          final ms = raw >= 1000000000000 ? raw : raw * 1000;
          if (ms < cutoff) {
            tooOld += 1;
            continue;
          }
          final data = e['data'] is Map ? Map<String, Object?>.from(e['data'] as Map) : <String, Object?>{};
          loaded.add(QueuedEvent(e['event'] as String, data, raw, origin));
        }
      }
    }
    deliveryStats['dropped_too_old'] = deliveryStats['dropped_too_old']! + tooOld;
    pending.insertAll(0, loaded);
    while (pending.length > _queueCap) {
      pending.removeAt(_firstQueuedError() ?? 0);
      deliveryStats['dropped_overflow'] = deliveryStats['dropped_overflow']! + 1;
    }
    if (pending.isNotEmpty) _firstQueuedAt ??= deps.monotonicSeconds();
    saveQueue();
  }

  /// Writes the queue as format version 2, one group per run of events from
  /// one session, with that session's origin exactly as received. An empty
  /// queue removes the file. Never a trail on disk.
  void saveQueue({bool stopping = false}) {
    _queueDirty = false;
    if (!_queueLoaded || !(stopping || trackingEnabled)) return;
    final name = queueFileName(config.ingestKey);
    if (pending.isEmpty) {
      deps.storage.remove(name);
      return;
    }
    final groups = <Map<String, Object?>>[];
    Object? last = const Object();
    for (final e in pending) {
      final session = e.origin?['session'];
      if (groups.isEmpty || session != last) {
        groups.add({if (e.origin != null) 'origin': e.origin, 'events': <Object?>[]});
        last = session;
      }
      final data = e.data.containsKey('rs_trail') ? (Map<String, Object?>.of(e.data)..remove('rs_trail')) : e.data;
      (groups.last['events'] as List).add({'event': e.event, 'timestamp': e.timestamp, 'data': data});
    }
    try {
      deps.storage.write(name, jsonEncode({'version': queueFormatVersion, 'groups': groups}));
    } catch (err) {
      _log('warn', 'could not save the queue: $err');
    }
  }

  // ---------------------------------------------------- config, exposure

  String get _scope => jsonEncode([apiUrl, config.ingestKey, deviceId, config.platform, config.gameVersion]);

  bool _validConfig(Object? doc) {
    if (doc is! Map) return false;
    final values = doc['values'];
    final experiments = doc['experiments'];
    final etag = doc['etag'];
    if (values is! Map || experiments is! List || etag is! String || !_etag.hasMatch(etag)) return false;
    if (values.length > 50) return false;
    for (final key in values.keys) {
      if (key is! String || !_experimentKey.hasMatch(key)) return false;
    }
    if (experiments.length > 10) return false;
    final seen = <String>{};
    for (final row in experiments) {
      if (row is! Map) return false;
      final key = row['key'];
      final variant = row['variant'];
      if (key is! String || !_experimentKey.hasMatch(key) || variant is! String || !_variantName.hasMatch(variant) || !seen.add(key)) return false;
    }
    return true;
  }

  Map<String, Object?>? _cachedConfig() {
    if (!trackingEnabled || keyRefused || deviceId.isEmpty) return null;
    final scope = _scope;
    if (_configScope == scope) return _configDocument;
    _configScope = scope;
    _configDocument = null;
    final text = deps.storage.read(configFile);
    final cached = text == null || text.length > 435000 ? null : _decode(text);
    if (cached is Map && cached['scope'] == scope && _validConfig(cached['document'])) {
      _configDocument = Map<String, Object?>.from(cached['document'] as Map);
    }
    return _configDocument;
  }

  /// Fetches this device's remote config. Completes with its source:
  /// network, cache or default.
  Future<String> fetchConfig() async {
    if (!trackingEnabled || keyRefused || deviceId.isEmpty || _configPending || quitting) {
      return _cachedConfig() == null ? 'default' : 'cache';
    }
    final cached = _cachedConfig();
    final scope = _scope;
    final generation = ++_configGeneration;
    _configPending = true;
    final headers = <String, String>{'X-API-Key': config.ingestKey};
    if (cached != null) headers['If-None-Match'] = cached['etag'] as String;
    final query = Uri(queryParameters: {'deviceId': deviceId, 'platform': config.platform, 'gameVersion': config.gameVersion}).query;
    final res = await _send(RsRequest('GET', '$apiUrl/api/v1/ingest/config?$query', headers));
    if (generation != _configGeneration) return 'default';
    _configPending = false;
    if (!trackingEnabled || keyRefused || scope != _scope) return 'default';
    var source = _cachedConfig() == null ? 'default' : 'cache';
    if (res.status == 200 && res.body.length <= 430000) {
      final doc = _decode(res.body);
      if (_validConfig(doc)) {
        _configDocument = Map<String, Object?>.from(doc as Map);
        _configScope = scope;
        source = 'network';
        try {
          deps.storage.write(configFile, jsonEncode({'scope': scope, 'document': doc}));
        } catch (_) {
          // The cache is optional.
        }
      }
    }
    _emit('config_ready', source);
    return source;
  }

  /// A typed config read: the fallback on a missing key or another type.
  /// The read is the exposure (EXPOSURE_CONTRACT.md).
  T getConfig<T>(String key, T fallback) {
    final doc = _cachedConfig();
    _noteExposure(doc);
    final values = doc?['values'];
    if (values is! Map || !values.containsKey(key)) return fallback;
    final value = values[key];
    if (value is T) return value;
    if (fallback is double && value is int) return value.toDouble() as T;
    return fallback;
  }

  void _noteExposure(Map<String, Object?>? doc) {
    if (doc == null || !trackingEnabled) return;
    var newly = false;
    for (final row in (doc['experiments'] as List? ?? const [])) {
      final r = row as Map;
      final key = r['key'] as String;
      if (!_exposed.containsKey(key)) {
        _exposed[key] = r['variant'] as String;
        newly = true;
      }
    }
    if (newly) track('rs_exposure');
  }

  void _applyExposureTags(Map<String, Object?> data) {
    if (_exposed.isEmpty) return;
    final doc = _configDocument;
    for (final row in (doc?['experiments'] as List? ?? const [])) {
      final r = row as Map;
      final key = r['key'] as String;
      if (!_exposed.containsKey(key)) continue;
      final tag = 'rs_exp_$key';
      final current = data[tag];
      if (!(current is String && _variantName.hasMatch(current))) data[tag] = r['variant'];
    }
  }

  // --------------------------------------------------------------- errors

  void _adoptErrorCapture(Object? value) {
    if (value is! Map) return;
    errorCapture = {'enabled': value['enabled'] != false, 'trail': value['trail'] == true};
    _emit('error_capture', errorCapture!['enabled']);
    final held = List.of(_bootErrors);
    _bootErrors.clear();
    if (errorCapture!['enabled'] != true) return;
    for (final (name, data) in held) {
      track(name, data);
    }
  }

  /// An error the game reports itself, sent as written (the server scrubs it).
  bool trackError(String severity, String message, {String? stack, String? errorType, String name = 'error', Map<String, Object?>? props}) {
    final data = buildErrorData(ErrorInfo(message: message, severity: severity, stack: stack, errorType: errorType, props: props), scrub: false);
    return track(name, data);
  }

  /// True while automatic capture may run: a key, the player's consent, the
  /// SDK's own switch, and the game's errorCapture switch not off. The
  /// Flutter binding installs its hooks only while this holds.
  bool get captureAllowed => config.captureErrors && config.ingestKey.isNotEmpty && trackingEnabled && !keyRefused && errorCapture?['enabled'] != false;

  /// An automatic capture: never without a key, consent or the game's
  /// capture switch; caps first; at most 5 held before the session answer.
  bool captureError(ErrorInfo info) {
    if (!config.captureErrors || !trackingEnabled || config.ingestKey.isEmpty) return false;
    final capture = errorCapture;
    if (capture != null && capture['enabled'] != true) return false;
    if (!_errorLimiter.allow(info)) return false;
    final data = buildErrorData(info, scrub: true);
    if (capture == null) {
      if (_bootErrors.length >= bootHold) return false;
      _bootErrors.add(('error', data));
      return true;
    }
    return track('error', data);
  }

  // ---------------------------------------------------------- attribution

  /// Where this install came from, sent once per install.
  ({bool sent, String? reason}) setAttribution({required String source, String? network, String? campaign, String? adset, String? creative, int? touchTime}) {
    if (!trackingEnabled) return (sent: false, reason: 'tracking_disabled');
    if (deps.storage.read(attributionFile) != null) return (sent: false, reason: 'already_sent');
    final built = attributionEvent(source: source, network: network, campaign: campaign, adset: adset, creative: creative, touchTime: touchTime);
    if (built.data == null) return (sent: false, reason: built.reason);
    if (!track('rs_attribution', built.data)) return (sent: false, reason: 'not_queued');
    deps.storage.write(attributionFile, '1');
    return (sent: true, reason: null);
  }

  // -------------------------------------------------------------- privacy

  /// The player's choice, saved at once. Off drops the queue and the
  /// pending error captures, forgets the signed-in account (identify) and
  /// sends nothing more.
  void setTrackingEnabled(bool enabled) {
    // Opting out, or withdrawing consent, forgets the signed-in account.
    if (!enabled) _forgetIdentity();
    if (config.consent == 'opt_in') {
      if (enabled) {
        deps.storage.write(optInFile, '1');
      } else {
        deps.storage.remove(optInFile);
      }
    } else {
      if (enabled) {
        deps.storage.remove(optOutFile);
      } else {
        deps.storage.write(optOutFile, '1');
      }
    }
    _playerOptedOut = !enabled;
    if (!enabled) {
      _clearQueue();
      deps.storage.remove(backgroundFile);
      sessionToken = '';
      _sessionExpiresAtMs = 0;
      _signingSecret = null;
      trackingEnabled = false;
      _setReason('disabled');
      _emit('tracking_disabled', 'player');
      return;
    }
    if (config.ingestKey.isEmpty || keyRefused) return;
    trackingEnabled = _serverTrackingEnabled;
    if (!_started) return;
    _loadIdentity();
    // An account id held before the yes is hashed once the salt is known.
    _hashHeldAccount();
    _setReason(null);
    if (!_settingsRequested) _checkServerSettings();
    _queueGameStarted();
    if (!_settingsPending && !isSessionValid) _startSession();
  }

  bool get isTrackingEnabled => trackingEnabled && !keyRefused;

  /// A fresh random device id. The queue, the session, the attribution
  /// flag and any held captures are dropped; a session answer still in
  /// flight belongs to the old id and is ignored. Before the opt-in yes,
  /// or after an opt-out, the old id is forgotten and none is made until
  /// the player says yes (the result is then empty). The signed-in account
  /// (identify) is kept. Without a key it does nothing.
  String resetDeviceId() {
    if (config.ingestKey.isEmpty) return deviceId;
    _clearQueue();
    deps.storage.remove(attributionFile);
    deps.storage.remove(backgroundFile);
    deps.storage.remove(configFile);
    sessionToken = '';
    _sessionExpiresAtMs = 0;
    _signingSecret = null;
    _sessionOrigin = null;
    _sessionGeneration += 1;
    _sessionPending = false;
    _exposed.clear();
    _configDocument = null;
    _configScope = null;
    // A flush waiting on the dropped queue or session is done.
    _completeFlush();
    if (_playerOptedOut) {
      deps.storage.remove(deviceIdFile);
      deviceId = '';
      _identityLoaded = false;
      return deviceId;
    }
    deviceId = _newDeviceId();
    deps.storage.write(deviceIdFile, deviceId);
    _gameStartedQueued = false;
    _queueGameStarted();
    return deviceId;
  }

  // ------------------------------------------------------- campaign links

  /// The campaign link waiting for the next session, or null.
  String? get campaignLink => _campaignLink;

  /// Holds a campaign link for the next session this core opens. True when
  /// [linkId] is a link id (24 hex characters, in any case), which then
  /// replaces any link waiting; false, with nothing changed, otherwise.
  /// Memory only, and cleared only when a session that carried it answers
  /// 201 with a token.
  bool setCampaignLink(String linkId) {
    final id = campaignLinkId(linkId);
    if (id == null) return false;
    _campaignLink = id;
    return true;
  }

  // ------------------------------------------------------------- identify

  /// True while an account is stored or held by [identify]. The account id
  /// itself is never readable.
  bool get isIdentified => _account != null || _heldAccountId != null;

  /// Whether identify may hash and save now: a key, the player's consent,
  /// and the device id loaded.
  bool get _identityAllowed => _started && config.ingestKey.isNotEmpty && !_playerOptedOut && _identityLoaded;

  /// Links this device to the game's own account. Returns null when
  /// [accountId] is accepted, else why it is refused (`empty`, `too_long`
  /// or `looks_like_email`); a refusal changes nothing. Only a salted hash
  /// of the id is ever sent or saved; the id itself is held in memory until
  /// the salt is known. A different account first does [resetIdentity].
  String? identify(String accountId) {
    final refusal = identifyRefusal(accountId);
    if (refusal != null) return refusal;
    // A different account than the one stored or held: a sign-out first.
    if (!_isSameAccount(accountId)) resetIdentity();
    if (_identifySaltMissing) {
      _log('info', 'identify is not offered by this server; nothing is sent this launch');
      return null;
    }
    final salt = _identifySalt;
    if (salt == null || !_identityAllowed) {
      // No salt this launch yet, or not allowed to save: held in memory
      // only, and hashed under whichever salt the session answer brings.
      _heldAccountId = accountId;
      return null;
    }
    if (_account == null) {
      _account = (salt: salt, accountHash: identifyAccountHash(salt, accountId));
      _writeAccount();
    }
    _heldAccountId = null;
    if (isSessionValid) {
      _sendIdentify();
    } else if (trackingEnabled && !keyRefused && !_sessionPending && !_settingsPending && _retryAt == null) {
      // No session open: open one for the waiting identity.
      _startSession();
    }
    return null;
  }

  /// For sign-out: forgets the stored or held account and switches to a
  /// fresh device id as [resetDeviceId] does, so the next session is not
  /// linked to the last player. Sends nothing. With no account stored or
  /// held it does nothing and keeps the device id.
  void resetIdentity() {
    // An identity an earlier launch saved counts too, even before the
    // opt-in yes, when it was never loaded.
    final onDisk = config.ingestKey.isNotEmpty && deps.storage.read(identityFile) != null;
    if (_account == null && _heldAccountId == null && !onDisk) return;
    _forgetIdentity();
    _identifyNoSessionStopped = false;
    resetDeviceId();
  }

  /// True when [accountId] is the account already stored or held, or when
  /// there is none.
  bool _isSameAccount(String accountId) {
    final held = _heldAccountId;
    if (held != null) return held == accountId;
    final account = _account;
    if (account != null) return identifyAccountHash(account.salt, accountId) == account.accountHash;
    return true;
  }

  void _forgetIdentity() {
    _identifyGeneration += 1;
    _identifySentOn = null;
    _identifyNoSessionRetried = false;
    _heldAccountId = null;
    _account = null;
    // Also one saved by an earlier launch and never loaded (before the
    // opt-in yes). Never a file while inert.
    if (config.ingestKey.isNotEmpty) deps.storage.remove(identityFile);
  }

  /// The saved identity when it is well formed, else null. Never writes.
  ({String salt, String accountHash})? _readSavedAccount() {
    final text = deps.storage.read(identityFile);
    final doc = text == null ? null : _decode(text);
    if (doc is! Map) return null;
    final salt = doc['salt'];
    final accountHash = doc['accountHash'];
    if (salt is String && accountHash is String && _hex64.hasMatch(salt) && _hex64.hasMatch(accountHash)) {
      return (salt: salt, accountHash: accountHash);
    }
    return null;
  }

  void _writeAccount() {
    final account = _account;
    if (account == null || !_identityAllowed) return;
    try {
      deps.storage.write(identityFile, jsonEncode({'salt': account.salt, 'accountHash': account.accountHash}));
    } catch (err) {
      // It still holds for this launch.
      _log('warn', 'could not save the identity: $err');
    }
  }

  /// Hashes a held account id once the salt is known and saving is allowed.
  void _hashHeldAccount() {
    final held = _heldAccountId;
    final salt = _identifySalt;
    if (held == null || salt == null || !_identityAllowed) return;
    _account = (salt: salt, accountHash: identifyAccountHash(salt, held));
    _heldAccountId = null;
    _writeAccount();
  }

  /// Reads identify.salt from a session answer. The first answer decides
  /// whether this server offers identify this launch; a salt other than the
  /// saved one (another game's key) deletes the saved identity unsent.
  void _readIdentifySalt(Map body) {
    if (_identifySaltMissing) return;
    final offer = body['identify'];
    final salt = offer is Map ? offer['salt'] : null;
    if (salt is! String || !_hex64.hasMatch(salt)) {
      if (_identifySalt == null) {
        _identifySaltMissing = true;
        _heldAccountId = null;
        _identifyGeneration += 1;
      }
      return;
    }
    _identifySalt = salt;
    final account = _account;
    if (account != null && account.salt != salt) {
      final held = _heldAccountId;
      _forgetIdentity();
      _heldAccountId = held;
    }
    _hashHeldAccount();
  }

  /// Sends the identity on the open session, once per session. Never
  /// queued, never awaited by a caller.
  void _sendIdentify() {
    final account = _account;
    final salt = _identifySalt;
    if (account == null || salt == null || account.salt != salt) return;
    if (_identifyStopped || _identifyNoSessionStopped || !trackingEnabled || keyRefused || !isSessionValid) return;
    final token = sessionToken;
    if (_identifySentOn == token) return;
    _identifySentOn = token;
    final generation = _identifyGeneration;
    final body = utf8.encode(jsonEncode({'accountHash': account.accountHash}));
    _send(RsRequest('POST', '$apiUrl/api/v1/identify', {'Content-Type': 'application/json', 'X-API-Key': config.ingestKey, 'X-Session-Token': token}, body))
        .then((res) => _onIdentifyResponse(res, generation));
  }

  void _onIdentifyResponse(RsResponse res, int generation) {
    final error = _errorOf(_decode(res.body));
    // The server does not offer identify, or calls the hash malformed (a
    // bug): retrying this launch cannot help, whatever identity is current.
    if (res.status == 404) {
      _identifyStopped = true;
      _log('info', 'identify is not offered by this server; not tried again this launch');
      return;
    }
    if (res.status == 400 && error == 'invalid_account_hash') {
      _identifyStopped = true;
      _log('warn', 'identify was refused as invalid_account_hash; not tried again this launch');
      return;
    }
    // A late answer for an identity since replaced or forgotten.
    if (generation != _identifyGeneration) return;
    if (res.status == 400 && error == 'no_session') {
      // Again once, when the next session opens; a second no_session in a
      // row stops identify until resetIdentity.
      if (_identifyNoSessionRetried) _identifyNoSessionStopped = true;
      _identifyNoSessionRetried = true;
      return;
    }
    // 200, or 409 (session_taken, synthetic_session), 429 (identify_limited,
    // rate_limited, needs_funds), 5xx, a timeout or offline: the identity is
    // kept, this session is not tried again, and the next session tries once
    // more.
    _identifyNoSessionRetried = false;
  }

  // ------------------------------------------------------------- feedback

  static const Set<String> feedbackCategories = {'bug', 'suggestion', 'complaint', 'praise', 'playtest', 'other'};

  /// Player feedback. Completes with null on success, else the reason.
  Future<String?> submitFeedback(String message, {String? category, int? rating}) async {
    if (message.trim().isEmpty) return 'empty_message';
    if (category != null && !feedbackCategories.contains(category)) return 'invalid_category';
    if (rating != null && (rating < 1 || rating > 5)) return 'invalid_rating';
    if (!trackingEnabled || keyRefused) return 'tracking_disabled';
    if (!isSessionValid) return 'no_session';
    final body = <String, Object?>{'message': message, if (category != null) 'category': category, if (rating != null) 'rating': rating};
    final res = await _send(RsRequest('POST', '$apiUrl/api/v1/feedback', {'Content-Type': 'application/json', 'X-Session-Token': sessionToken}, utf8.encode(jsonEncode(body))));
    if (res.status == 201 || res.status == 200) {
      _emit('feedback_submitted');
      return null;
    }
    final reason = _errorOf(_decode(res.body));
    _emit('feedback_failed', reason.isEmpty ? 'http_${res.status}' : reason);
    return reason.isEmpty ? 'http_${res.status}' : reason;
  }

  // ---------------------------------------------- background and quitting

  /// The app went to the background (iOS, Android): no event, a flush, the
  /// queue saved, and a marker so a kill in the background still reports
  /// its exit on the next launch.
  void enterBackground() {
    if (!config.mobile || !trackingEnabled || quitting) return;
    _backgroundedAtMs = deps.wallMs();
    saveQueue();
    deps.storage.write(backgroundFile, jsonEncode({'backgroundedAt': _backgroundedAtMs, if (_sessionOrigin != null) 'origin': _sessionOrigin}));
    flush();
  }

  /// The app came back. After sessionTimeout seconds away, game_exited is
  /// queued at the time it left, under the old session, and a new session
  /// starts with game_started. Sooner, nothing is queued.
  void enterForeground() {
    final left = _backgroundedAtMs;
    _backgroundedAtMs = null;
    deps.storage.remove(backgroundFile);
    if (!config.mobile || !trackingEnabled || left == null) return;
    if (deps.wallMs() - left < config.sessionTimeoutSeconds * 1000) return;
    track('game_exited', const {}, left, _sessionOrigin);
    // The next session's events take its own origin when it answers.
    _sessionOrigin = null;
    sessionToken = '';
    _sessionExpiresAtMs = 0;
    _signingSecret = null;
    _exposed.clear();
    _errorLimiter.resetSession();
    _gameStartedQueued = false;
    _queueGameStarted();
  }

  /// A marker left by a run killed in the background: its game_exited is
  /// queued once, at the time it left, under its own session's origin.
  void _replayBackgroundMarker() {
    final text = deps.storage.read(backgroundFile);
    if (text == null) return;
    deps.storage.remove(backgroundFile);
    final marker = _decode(text);
    if (marker is! Map || marker['backgroundedAt'] is! int) return;
    final origin = marker['origin'] is Map ? Map<String, Object?>.from(marker['origin'] as Map) : null;
    _enqueue('game_exited', const {}, marker['backgroundedAt'] as int, origin);
  }

  /// Records game_exited, sends what it can and saves the rest.
  Future<void> quit() async {
    if (quitting) return;
    quitting = true;
    deps.storage.remove(backgroundFile);
    if (trackingEnabled && !_gameExitedQueued) {
      _gameExitedQueued = true;
      _enqueue('game_exited', const {}, null, null);
    }
    saveQueue(stopping: true);
    if (trackingEnabled && pending.isNotEmpty && (isSessionValid || _sessionPending)) {
      await flush();
    }
    saveQueue(stopping: true);
  }

  // -------------------------------------------------------------- helpers

  Future<RsResponse> _send(RsRequest request) async {
    try {
      return await deps.transport(request);
    } catch (_) {
      return RsResponse(0);
    }
  }

  static Object? _decode(String text) {
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  static String _errorOf(Object? body) => body is Map && body['error'] != null ? body['error'].toString() : '';
}
