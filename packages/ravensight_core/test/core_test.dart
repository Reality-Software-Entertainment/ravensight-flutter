// The pure core under `dart test`: the shared vectors, the wire helpers,
// and the state machine against a fake network and a fake clock.
import 'dart:convert';
import 'dart:io';

import 'package:ravensight_core/ravensight_core.dart';
import 'package:test/test.dart';

const origin = {'session': 'ses_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'build': '1.0.0', 'platform': 'android', 'stamp': 'o1.a.b'};
const configDoc = {
  'values': {'jump': 7, 'title': 'Hi'},
  'experiments': [
    {'key': 'jump_test', 'variant': 'high'}
  ],
  'etag': '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"',
};

Map<String, dynamic> fixture(String name) => jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map<String, dynamic>;

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A fake server: answers by path, records every request.
class World {
  World({MemoryStorage? storage, this.consent = 'opt_out', this.gzip = false, this.mobile = false}) : storage = storage ?? MemoryStorage();

  final MemoryStorage storage;
  final String consent;
  final bool gzip;
  final bool mobile;
  final List<RsRequest> requests = [];
  int wallMs = 1800000000000;
  double clock = 0;
  bool offline = false;
  Map<String, Object?> sessionAnswer = {'token': 'tok', 'expiresIn': 3600, 'origin': origin};
  RsResponse Function(RsRequest request)? batchReply;
  RsResponse Function(RsRequest request)? configReply;
  late RavensightCore core;
  int _hex = 0;

  RavensightCore start() {
    core = RavensightCore(
      CoreConfig(ingestKey: 'gt_pub_test', apiUrl: 'https://api.test', gameVersion: '1.2.0', platform: 'android', osName: 'android', consent: consent, mobile: mobile, device: const {'model': ' Pixel 7 ', 'osVersion': '14'}),
      CoreDeps(
        transport: (r) async {
          requests.add(r);
          if (offline) return RsResponse(0);
          final path = Uri.parse(r.url).path;
          if (path.endsWith('/settings')) return RsResponse(200, '{"trackingEnabled":true}');
          if (path.endsWith('/session')) return RsResponse(201, jsonEncode(sessionAnswer));
          if (path.endsWith('/ingest/config')) return configReply?.call(r) ?? RsResponse(404, '{}');
          if (path.endsWith('/track/batch')) return batchReply?.call(r) ?? RsResponse(202, '{}');
          if (path.endsWith('/feedback')) return RsResponse(201, '{"ok":true}');
          return RsResponse(404, '{}');
        },
        storage: storage,
        wallMs: () => wallMs,
        monotonicSeconds: () => clock,
        random: () => 1.0,
        randomHex: (n) {
          _hex += 1;
          return _hex.toRadixString(16).padLeft(2, '0').substring(0, 2) * n;
        },
        gzip: gzip ? (bytes) => [0x1f, 0x8b, ...bytes] : null,
      ),
    );
    core.start();
    return core;
  }

  Future<void> tick(double seconds) async {
    final end = clock + seconds;
    while (clock < end) {
      clock = (clock + 0.5) > end ? end : clock + 0.5;
      wallMs += 500;
      core.tick();
      await settle();
    }
  }

  static String bodyOf(RsRequest r) {
    final bytes = r.body ?? const [];
    final plain = r.headers['Content-Encoding'] == 'gzip' ? bytes.sublist(2) : bytes;
    return utf8.decode(plain);
  }

  List<Map<String, dynamic>> get events => [
        for (final r in requests.where((r) => r.url.endsWith('/track/batch')))
          for (final e in (jsonDecode(bodyOf(r))['events'] as List)) e as Map<String, dynamic>,
      ];

  List<String> get names => events.map((e) => e['event'] as String).toList();
  List<RsRequest> get batches => requests.where((r) => r.url.endsWith('/track/batch')).toList();
}

void main() {
  group('shared vectors', () {
    final delivery = fixture('delivery-vectors.json');
    final signing = delivery['signing'] as Map<String, dynamic>;

    test('header signatures', () {
      for (final v in signing['header'] as List) {
        final c = v as Map<String, dynamic>;
        expect('v1:${c['timestamp']}:${c['body']}', c['canonical'], reason: c['name'] as String);
        expect('v1=${signBody(signing['secret'] as String, c['timestamp'] as int, c['body'] as String)}', c['header'], reason: c['name'] as String);
      }
    });

    test('beacon envelopes', () {
      for (final v in signing['beacon'] as List) {
        final c = v as Map<String, dynamic>;
        final built = signedBeaconBody('SESSION_TOKEN', signing['secret'] as String, c['t'] as int, c['inner'] as String);
        expect(jsonDecode(jsonEncode(built)), c['envelope'], reason: c['name'] as String);
      }
    });

    test('the 8 KB event size rule', () {
      for (final v in (delivery['anyKeyEventSize'] as Map<String, dynamic>)['cases'] as List) {
        final c = v as Map<String, dynamic>;
        final data = <String, Object?>{};
        (c['data'] as Map<String, dynamic>).forEach((k, value) {
          data[k] = value is Map ? (value['repeat'] as String) * (value['count'] as int) : value;
        });
        final tooLarge = eventDataBytes(data) > maxEventBytes;
        expect(tooLarge ? 'event_too_large' : null, c['expect'], reason: c['name'] as String);
      }
    });

    test('scrub vectors (version 6) and idempotence', () {
      final scrub = fixture('scrub-vectors.json');
      expect(scrub['version'], 6);
      for (final v in scrub['cases'] as List) {
        final c = v as Map<String, dynamic>;
        expect(scrubText(c['in'] as String), c['out'], reason: c['name'] as String);
        expect(scrubText(c['out'] as String), c['out'], reason: '${c['name']} twice');
      }
    });
  });

  group('wire helpers', () {
    test('queue file names: 64-bit FNV-1a, as every SDK computes it', () {
      expect(fnv1a64(''), 'cbf29ce484222325');
      expect(fnv1a64('gt_live_k'), 'b6489fdf95b4814b');
      expect(fnv1a64('gt_pub_abcdefghijklmnop'), '1c82d7d9499aecbf');
      expect(fnv1a64('ünïcödé key'), 'bf687d8f3038134d');
      expect(queueFileName('gt_live_k'), 'queue-b6489fdf95b4814b.json');
    });

    test('apiUrl forms', () {
      expect(normalizeApiUrl(null), 'https://api.ravensight.io');
      expect(normalizeApiUrl(' https://api.ravensight.io/api/v1/ '), 'https://api.ravensight.io');
      expect(normalizeApiUrl('https://x.test///'), 'https://x.test');
    });

    test('micros on the digits, never a float multiply', () {
      expect(microsFromDecimalString('0.0015'), '1500');
      expect(microsFromDecimalString('1.23456789'), '1234568');
      expect(microsFromDecimalString('1e-3'), '1000');
      expect(microsFromDecimalString('0.9999995'), '1000000');
      expect(microsFromDecimalString('-1'), isNull);
      expect(microsFromDecimalString('abc'), isNull);
      expect(microsFromRevenue(0.0015), '1500');
      expect(microsFromRevenue(1.23456789), '1234568');
      expect(microsFromRevenue(-0.5), isNull);
      expect(microsFromRevenue(double.nan), isNull);
    });

    test('ads: exactly the contract keys, revenue only on shown and only with a currency', () {
      final ad = adEvent('admob', 'rewarded', 'shown', placement: 'level_end', revenueMicros: '1500', currency: 'USD');
      expect(ad.data, {
        'rs_kind': 'ad',
        'rs_ad_network': 'admob',
        'rs_ad_format': 'rewarded',
        'rs_ad_placement': 'level_end',
        'rs_ad_result': 'shown',
        'rs_revenue_micros': '1500',
        'rs_currency': 'USD',
      });
      expect(adEvent('admob', 'rewarded', 'shown', revenueMicros: '1500').data, isNull);
      expect(adEvent('admob', 'rewarded', 'clicked', revenueMicros: '1', currency: 'USD').data, isNull);
      expect(adEvent('admob', 'video', 'shown').data, isNull);
      expect(adFormatFrom('REWARDED_INTER'), 'rewarded');
      expect(adFormatFrom('MREC'), 'banner');
      expect(adFormatFrom('weird'), 'other');
    });

    test('attribution omits empty fields', () {
      final a = attributionEvent(source: 'utm', network: '', campaign: 'spring', touchTime: 5);
      expect(a.data, {'rs_kind': 'attribution', 'rs_attr_source': 'utm', 'rs_campaign': 'spring', 'rs_touch_time': 5});
      expect(attributionEvent(source: '').data, isNull);
    });

    test('event ids: at most 64 characters of [A-Za-z0-9_-]', () {
      final id = eventId('0123456789abcdef0123456789abcdef-android', 1800000000, 'abababab', 12);
      expect(id, '0123456789abcdef-6b49d200-abababab-12');
      expect(RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id), isTrue);
    });
  });

  group('the state machine', () {
    test('start: settings, a session with the device fields, game_started first', () async {
      final w = World();
      w.start();
      await settle();
      expect(w.requests.first.url, 'https://api.test/api/v1/settings');
      final session = jsonDecode(utf8.decode(w.requests[1].body!)) as Map<String, dynamic>;
      expect(session['platform'], 'android');
      expect(session['sdk'], 'flutter/0.1.0');
      expect(session['device'], {'model': 'Pixel 7', 'osVersion': '14'});
      expect(RegExp(r'^[0-9a-f]{32}-android$').hasMatch(session['deviceId'] as String), isTrue);
      expect(w.names, ['game_started']);
      expect(w.events.first['data']['rs_event_id'], isNotNull);
    });

    test('batches wait for the interval, then go together; 50 go at once', () async {
      final w = World();
      w.start();
      await settle();
      w.core.track('a');
      w.core.track('b');
      await w.tick(1);
      expect(w.batches.length, 1);
      await w.tick(2);
      expect(w.names, ['game_started', 'a', 'b']);
      for (var i = 0; i < 50; i++) {
        w.core.track('e$i');
      }
      await settle();
      expect(w.batches.length, 3, reason: 'a full batch flushes at once');
    });

    test('signed when the session gives a secret; gzip at 1,024 bytes; signature over the plain body', () async {
      final w = World(gzip: true);
      w.sessionAnswer = {
        'token': 'tok',
        'expiresIn': 3600,
        'origin': origin,
        'signing': {'algorithm': 'HMAC-SHA256', 'version': 1, 'secret': 's' * 43, 'serverTime': (w.wallMs ~/ 1000) + 100},
      };
      w.start();
      await settle();
      w.core.track('big', {'text': 'x' * 2000});
      await w.flushAndSettle();
      final batch = w.batches.last;
      expect(batch.headers['Content-Encoding'], 'gzip');
      final t = int.parse(batch.headers['X-Ravensight-Timestamp']!);
      expect(t, (w.wallMs ~/ 1000) + 100, reason: 'the device clock corrected by the server time');
      expect(batch.headers['X-Ravensight-Signature'], 'v1=${signBody('s' * 43, t, World.bodyOf(batch))}');
      expect(w.batches.first.headers['Content-Encoding'], isNull, reason: 'small bodies go plain');
    });

    test('offline: the queue is saved as format 2 with its origin; the next launch sends it once, same ids', () async {
      final w = World();
      w.start();
      await settle();
      w.offline = true;
      w.core.track('pickup', {'item': 'key'});
      await w.flushAndSettle();
      w.core.saveQueue();
      final text = w.storage.read(queueFileName('gt_pub_test'))!;
      final doc = jsonDecode(text) as Map<String, dynamic>;
      expect(doc['version'], 2);
      final group = (doc['groups'] as List).first as Map<String, dynamic>;
      expect(group['origin'], origin);
      final savedId = ((group['events'] as List).first as Map)['data']['rs_event_id'];

      final w2 = World(storage: w.storage);
      w2.sessionAnswer = {'token': 't2', 'expiresIn': 3600, 'origin': {...origin, 'session': 'ses_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'}};
      w2.start();
      await settle();
      await w2.flushAndSettle();
      final pickup = w2.events.firstWhere((e) => e['event'] == 'pickup');
      expect(pickup['origin'], origin, reason: 'the old origin, verbatim');
      expect(pickup['data']['rs_event_id'], savedId);
      expect(w2.events.where((e) => e['event'] == 'game_started').last['origin'], isNull);
    });

    test('an indexed 400 drops one event; batch_too_large halves; 415 resends plain once', () async {
      final w = World(gzip: true);
      var answers = <RsResponse>[];
      w.batchReply = (r) => answers.isEmpty ? RsResponse(202, '{}') : answers.removeAt(0);
      w.start();
      await settle();
      answers = [RsResponse(400, '{"error":"invalid_event_data","index":1}')];
      w.core.track('a');
      w.core.track('b');
      await w.flushAndSettle();
      expect(w.core.deliveryStats['dropped_refused'], 1);
      expect(w.core.pending, isEmpty);

      answers = [RsResponse(400, '{"error":"batch_too_large"}')];
      for (var i = 0; i < 4; i++) {
        w.core.track('h$i');
      }
      final before = w.batches.length;
      await w.flushAndSettle();
      final sizes = [for (final r in w.batches.skip(before)) (jsonDecode(World.bodyOf(r))['events'] as List).length];
      expect(sizes, [4, 2, 2]);

      answers = [RsResponse(415, '{"error":"unsupported_encoding"}')];
      w.core.track('big', {'text': 'y' * 2000});
      final mark = w.batches.length;
      await w.flushAndSettle();
      final tries = w.batches.skip(mark).toList();
      expect(tries.length, 2);
      expect(tries[0].headers['Content-Encoding'], 'gzip');
      expect(tries[1].headers['Content-Encoding'], isNull);
    });

    test('429 waits exactly Retry-After, and an explicit flush never cuts it short', () async {
      final w = World();
      var limited = true;
      w.batchReply = (r) => limited ? RsResponse(429, '{"error":"rate_limited"}', {'retry-after': '7'}) : RsResponse(202, '{}');
      w.start();
      await settle();
      expect(w.core.retryInSeconds, 7);
      limited = false;
      await w.core.flush();
      expect(w.batches.length, 1, reason: 'flush during Retry-After sends nothing');
      await w.tick(6.5);
      expect(w.batches.length, 1);
      await w.tick(1);
      expect(w.batches.length, 2);
      expect(w.core.pending, isEmpty);
    });

    test('5xx backs off from 10 s, doubling, and a flush cuts a backoff short', () async {
      final w = World();
      w.batchReply = (r) => RsResponse(503, '{}');
      w.start();
      await settle();
      expect(w.core.retryInSeconds, 10);
      await w.tick(10);
      expect(w.core.retryInSeconds, closeTo(20, 0.6));
      w.batchReply = null;
      await w.flushAndSettle();
      expect(w.core.pending, isEmpty);
    });

    test('401 opens a new session once and resends the same ids', () async {
      final w = World();
      var refused = 1;
      w.batchReply = (r) => refused-- > 0 ? RsResponse(401, '{"error":"signature_invalid"}') : RsResponse(202, '{}');
      w.start();
      await settle();
      final sessions = w.requests.where((r) => r.url.endsWith('/session')).length;
      expect(sessions, 2);
      final ids = [for (final r in w.batches) (jsonDecode(World.bodyOf(r))['events'] as List).first['data']['rs_event_id']];
      expect(ids.length, 2);
      expect(ids[0], ids[1]);
    });

    test('403 tracking_disabled clears the queue and stops; another 403 keeps it for the next launch', () async {
      final w = World();
      w.batchReply = (r) => RsResponse(403, '{"error":"tracking_disabled"}');
      w.start();
      await settle();
      expect(w.core.statusReason, 'tracking_disabled');
      expect(w.core.pending, isEmpty);
      expect(w.core.track('x'), isFalse);

      final w2 = World();
      w2.batchReply = (r) => RsResponse(403, '{"error":"key_paused"}');
      w2.start();
      await settle();
      expect(w2.core.statusReason, 'invalid_key');
      expect(w2.storage.read(queueFileName('gt_pub_test')), isNotNull, reason: 'kept on disk');
    });

    test('exposure: no tag before a read; the first read tags later events once; a stopped experiment is dropped', () async {
      final w = World();
      var doc = Map<String, Object?>.from(configDoc);
      w.configReply = (r) => RsResponse(200, jsonEncode(doc));
      w.start();
      await settle();
      w.core.track('before');
      expect(w.core.getConfig('jump', 1), 7);
      w.core.track('after');
      w.core.getConfig('title', 'x');
      await w.flushAndSettle();
      final byName = {for (final e in w.events) e['event']: e['data'] as Map};
      expect(byName['before']!.containsKey('rs_exp_jump_test'), isFalse);
      expect(byName['after']!['rs_exp_jump_test'], 'high');
      expect(w.names.where((n) => n == 'rs_exposure').length, 1);
      final exposure = byName['rs_exposure']!;
      expect(exposure.keys.toSet(), {'rs_exp_jump_test', 'rs_event_id'});
      expect(w.core.getConfig('title', 5), 5, reason: 'another type is the fallback');

      doc = {...configDoc, 'experiments': <Object?>[]};
      await w.core.fetchConfig();
      w.core.track('stopped');
      await w.flushAndSettle();
      expect((w.events.last['data'] as Map).containsKey('rs_exp_jump_test'), isFalse);
    });

    test('a game value for a tag wins when well formed', () async {
      final w = World();
      w.configReply = (r) => RsResponse(200, jsonEncode(configDoc));
      w.start();
      await settle();
      w.core.getConfig('jump', 0);
      w.core.track('mine', {'rs_exp_jump_test': 'low'});
      w.core.track('bad', {'rs_exp_jump_test': 'Not Valid'});
      await w.flushAndSettle();
      final byName = {for (final e in w.events) e['event']: e['data'] as Map};
      expect(byName['mine']!['rs_exp_jump_test'], 'low');
      expect(byName['bad']!['rs_exp_jump_test'], 'high');
    });

    test('error queue rules: gameplay first, a capture evicts only the oldest capture, no trail on disk', () async {
      final core = RavensightCore(
        CoreConfig(ingestKey: 'gt_pub_x', maxQueueSize: 3),
        CoreDeps(transport: (r) async => RsResponse(0), storage: MemoryStorage(), wallMs: () => 1, monotonicSeconds: () => 0, random: () => 0.5, randomHex: (n) => 'cd' * n),
      )..start();
      core.pending.clear();
      Map<String, Object?> capture(String m) => buildErrorData(ErrorInfo(message: m, source: 'uncaught'), scrub: true);
      core.track('a');
      core.track('error', capture('one'));
      core.track('b');
      expect(core.pending.map((e) => e.event).toList(), ['a', 'b', 'error']);
      core.track('error2', capture('two'));
      expect(core.pending.map((e) => e.event).toList(), ['a', 'b', 'error2'], reason: 'the oldest capture goes');
      core.track('c');
      expect(core.pending.map((e) => e.event).toList(), ['a', 'b', 'c'], reason: 'gameplay pushes a capture out');
      core.track('error3', capture('three'));
      expect(core.pending.map((e) => e.event).toList(), ['a', 'b', 'c'], reason: 'a capture never pushes gameplay out');
      core.track('manual', buildErrorData(ErrorInfo(message: 'mine'), scrub: false));
      expect(core.pending.map((e) => e.event).toList(), ['b', 'c', 'manual'], reason: 'a manual error is gameplay');

      core.track('trail', {'rs_kind': 'error', 'rs_severity': 'error', 'rs_message': 'x', 'rs_trail': '+1 info hello'});
      expect(core.pending.last.data['rs_trail'], '+1 info hello', reason: 'kept in memory');
      core.saveQueue();
      expect(core.deps.storage.read(queueFileName('gt_pub_x'))!.contains('rs_trail'), isFalse);
    });

    test('automatic capture: held until the session says capture is on, scrubbed, three per error', () async {
      final w = World();
      w.sessionAnswer = {'token': 'tok', 'expiresIn': 3600, 'origin': origin, 'errorCapture': {'enabled': true, 'trail': false}};
      final core = w.start();
      for (var i = 0; i < 5; i++) {
        core.captureError(ErrorInfo(message: 'failed for jo@example.com at /Users/jo ann/game', source: 'uncaught', errorType: 'StateError'));
      }
      await settle();
      await w.flushAndSettle();
      final errors = w.events.where((e) => e['event'] == 'error').toList();
      expect(errors.length, 3, reason: 'three for one dedupe key');
      expect(errors.first['data']['rs_message'], 'failed for [email] at ~/game');
      expect(errors.first['data']['rs_source'], 'uncaught');

      final off = World();
      off.sessionAnswer = {'token': 'tok', 'expiresIn': 3600, 'origin': origin, 'errorCapture': {'enabled': false, 'trail': false}};
      off.start();
      off.core.captureError(ErrorInfo(message: 'held then dropped', source: 'uncaught'));
      await settle();
      await off.flushAndSettle();
      expect(off.names.contains('error'), isFalse);
    });

    test('capture is allowed only with consent and while the game switch is on', () async {
      final waiting = World(consent: 'opt_in');
      waiting.start();
      await settle();
      expect(waiting.core.captureAllowed, isFalse, reason: 'before the yes');
      expect(waiting.core.captureError(ErrorInfo(message: 'x', source: 'uncaught')), isFalse);
      waiting.core.setTrackingEnabled(true);
      expect(waiting.core.captureAllowed, isTrue);

      final off = World();
      off.sessionAnswer = {'token': 'tok', 'expiresIn': 3600, 'origin': origin, 'errorCapture': {'enabled': false, 'trail': false}};
      final seen = <String>[];
      off.start().on((name, _) => seen.add(name));
      expect(off.core.captureAllowed, isTrue, reason: 'held until the answer');
      await settle();
      expect(off.core.captureAllowed, isFalse);
      expect(seen, contains('error_capture'));
    });

    test('a huge error is cut before the dedupe key is built, and still capped at three', () async {
      final w = World();
      w.sessionAnswer = {'token': 'tok', 'expiresIn': 3600, 'origin': origin, 'errorCapture': {'enabled': true, 'trail': false}};
      w.start();
      await settle();
      final huge = 'x1 ' * 400000;
      for (var i = 0; i < 5; i++) {
        w.core.captureError(ErrorInfo(message: huge, stack: 'frame\n' * 50000, source: 'uncaught'));
      }
      await w.flushAndSettle();
      final errors = w.events.where((e) => e['event'] == 'error').toList();
      expect(errors.length, 3);
      expect((errors.first['data']['rs_message'] as String).length, lessThanOrEqualTo(200));
      expect((errors.first['data']['rs_stack'] as String).length, lessThanOrEqualTo(2000));
    });

    test('opt-out is saved, drops the queue, and the next launch sends nothing at all', () async {
      final w = World();
      w.start();
      await settle();
      w.core.track('x');
      w.core.setTrackingEnabled(false);
      expect(w.storage.read(queueFileName('gt_pub_test')), isNull);
      final w2 = World(storage: w.storage);
      w2.start();
      await settle();
      expect(w2.requests, isEmpty);
      expect(w2.core.statusReason, 'disabled');
    });

    test('opt_in: no device id and nothing sent until the yes', () async {
      final w = World(consent: 'opt_in');
      w.start();
      await settle();
      expect(w.requests, isEmpty);
      expect(w.core.deviceId, isEmpty);
      w.core.setTrackingEnabled(true);
      await settle();
      expect(w.core.deviceId, isNotEmpty);
      expect(w.names, ['game_started']);
    });

    test('attribution is sent once per install, across launches; a reset allows it again', () async {
      final w = World();
      w.start();
      await settle();
      expect(w.core.setAttribution(source: 'organic').sent, isTrue);
      expect(w.core.setAttribution(source: 'organic').reason, 'already_sent');
      final w2 = World(storage: w.storage);
      w2.start();
      await settle();
      expect(w2.core.setAttribution(source: 'organic').reason, 'already_sent');
      final before = w2.core.deviceId;
      expect(w2.core.resetDeviceId(), isNot(before));
      expect(w2.core.setAttribution(source: 'organic').sent, isTrue);
    });

    test('mobile: back after 30 minutes is game_exited at the time it left, then a new session', () async {
      final w = World(mobile: true);
      w.start();
      await settle();
      final left = w.wallMs;
      w.core.enterBackground();
      expect(w.storage.read('background.json'), isNotNull);
      w.wallMs += 31 * 60 * 1000;
      w.sessionAnswer = {'token': 't2', 'expiresIn': 3600, 'origin': {...origin, 'session': 'ses_dddddddddddddddddddddddddddddddd'}};
      w.core.enterForeground();
      await settle();
      await w.flushAndSettle();
      final exited = w.events.firstWhere((e) => e['event'] == 'game_exited');
      expect(exited['timestamp'], left);
      expect(exited['origin'], origin, reason: 'under the session it belongs to');
      expect(w.names.where((n) => n == 'game_started').length, 2);
      expect(w.storage.read('background.json'), isNull);

      final short = World(mobile: true);
      short.start();
      await settle();
      short.core.enterBackground();
      short.wallMs += 60 * 1000;
      short.core.enterForeground();
      await short.flushAndSettle();
      expect(short.names.contains('game_exited'), isFalse);
    });

    test('a run killed in the background reports its exit on the next launch', () async {
      final w = World(mobile: true);
      w.start();
      await settle();
      final left = w.wallMs;
      w.core.enterBackground();
      final w2 = World(storage: w.storage, mobile: true);
      w2.sessionAnswer = {'token': 't2', 'expiresIn': 3600, 'origin': {...origin, 'session': 'ses_cccccccccccccccccccccccccccccccc'}};
      w2.start();
      await settle();
      await w2.flushAndSettle();
      final exited = w2.events.firstWhere((e) => e['event'] == 'game_exited');
      expect(exited['timestamp'], left);
      expect(exited['origin'], origin);
    });

    test('quit records game_exited once and sends it', () async {
      final w = World();
      w.start();
      await settle();
      await w.core.quit();
      await w.core.quit();
      expect(w.names.where((n) => n == 'game_exited').length, 1);
    });

    test('feedback goes with the session token; a bad category never leaves', () async {
      final w = World();
      w.start();
      await settle();
      expect(await w.core.submitFeedback('fun', category: 'praise', rating: 5), isNull);
      expect(await w.core.submitFeedback('x', category: 'nope'), 'invalid_category');
      final sent = w.requests.firstWhere((r) => r.url.endsWith('/feedback'));
      expect(sent.headers['X-Session-Token'], 'tok');
    });

    test('an event over 8 KB is dropped, not queued', () async {
      final w = World();
      w.start();
      await settle();
      expect(w.core.track('huge', {'text': 'z' * 9000}), isFalse);
    });
  });
}

extension on World {
  Future<void> flushAndSettle() async {
    await core.flush();
    await settle();
    await core.flush();
    await settle();
  }
}
