// identify(accountId) and resetIdentity() against the binding vectors
// (test/fixtures/identify-vectors.json, a byte-identical copy of the
// platform's docs/identify/identify-vectors.json, version 2), on a fake
// server whose sessions answer S1, S2, ... with the game's salt.
//
// accountId is a String in Dart, so the vectors' not_text cases (null and a
// fraction) cannot be passed at all: the compiler refuses them. The whole
// number case is checked as the decimal digits a game passes instead.
import 'dart:convert';

import 'package:ravensight_core/ravensight_core.dart';
import 'package:test/test.dart';

import 'support/fake_server.dart';

final Map<String, dynamic> vectors = fixture('identify-vectors.json');
final String salt = vectors['salt'] as String;
final List<Map<String, dynamic>> accept = [for (final c in vectors['accept'] as List) c as Map<String, dynamic>];
final List<Map<String, dynamic>> refuse = [for (final c in vectors['refuse'] as List) c as Map<String, dynamic>];
final List<Map<String, dynamic>> sequence = [for (final c in vectors['sequence'] as List) c as Map<String, dynamic>];

String step(int i) => sequence[i]['step'] as String;
Map<String, dynamic> expected(int i) => sequence[i]['expect'] as Map<String, dynamic>;

void main() {
  test('the vectors are version 2, and every accept case hashes to its wire and player id', () {
    expect(vectors['version'], 2);
    var longerThanBlock = false;
    for (final c in accept) {
      final note = c['note'] as String;
      final id = c['accountId'] is String ? c['accountId'] as String : c['same_as'] as String;
      if (c['accountId'] is! String) {
        // The whole number case: a Dart game passes its decimal digits.
        expect(c['integer'], isTrue, reason: note);
        expect(c['accountId'].toString(), id, reason: note);
      }
      final wire = identifyAccountHash(salt, id);
      expect(wire, c['wire'], reason: note);
      expect('px_${wire.substring(0, 32)}', c['playerId'], reason: note);
      expect(identifyRefusal(id), isNull, reason: note);
      if (utf8.encode(id).length > 64) longerThanBlock = true;
    }
    expect(longerThanBlock, isTrue, reason: 'a vector longer than the 64-byte HMAC block');
  });

  test('every accept case is sent as its wire, once, and stored with the salt', () async {
    for (final c in accept.where((v) => v['accountId'] is String)) {
      final note = c['note'] as String;
      final server = FakeServer(salt: salt);
      final core = server.launch();
      await settle();
      expect(core.identify(c['accountId'] as String), isNull, reason: note);
      await settle();
      expect(server.sends(), [
        {'session': 'S1', 'accountHash': c['wire']}
      ], reason: note);
      expect(server.stored, {'salt': salt, 'accountHash': c['wire']}, reason: note);
      expect(core.isIdentified, isTrue, reason: note);
    }
  });

  test('salts_differ: one account under two salts gives the two wires', () {
    final d = vectors['salts_differ'] as Map<String, dynamic>;
    final id = d['accountId'] as String;
    expect(identifyAccountHash(d['salt_a'] as String, id), d['wire_a']);
    expect(identifyAccountHash(d['salt_b'] as String, id), d['wire_b']);
    expect(d['wire_a'], isNot(d['wire_b']));
  });

  test('every refuse case Dart can express is refused: nothing sent or stored, the device id kept', () async {
    final notExpressible = refuse.where((v) => v['accountId'] is! String).toList();
    expect(notExpressible, isNotEmpty);
    expect(notExpressible.every((v) => v['reason'] == 'not_text'), isTrue, reason: 'only not_text cannot be passed as a String');
    for (final c in refuse.where((v) => v['accountId'] is String)) {
      final note = c['note'] as String;
      final id = c['accountId'] as String;
      expect(identifyRefusal(id), c['reason'], reason: note);
      for (final beforeSession in [true, false]) {
        final server = FakeServer(salt: salt);
        final core = server.launch();
        if (!beforeSession) await settle();
        final device = core.deviceId;
        expect(core.identify(id), c['reason'], reason: note);
        await settle();
        expect(server.sendCount, 0, reason: note);
        expect(server.stored, isNull, reason: note);
        expect(core.deviceId, device, reason: note);
        expect(core.isIdentified, isFalse, reason: note);
      }
    }
  });

  test('a refusal while identified keeps the identity and the device id, and sends nothing', () async {
    final server = FakeServer(salt: salt);
    final core = server.launch();
    await settle();
    core.identify('u1');
    await settle();
    final before = server.storage.read(identityFile);
    final device = core.deviceId;
    for (final c in refuse.where((v) => v['accountId'] is String)) {
      expect(core.identify(c['accountId'] as String), c['reason'], reason: c['note'] as String);
    }
    await settle();
    expect(server.sendCount, 1);
    expect(server.storage.read(identityFile), before);
    expect(core.deviceId, device);
  });

  test('the contract sequence holds: salt present, salt changed, salt missing', () async {
    final server = FakeServer(salt: salt);

    // 0: a key and consent; identify("u1") before any session opens.
    var core = server.launch();
    expect(core.identify('u1'), isNull, reason: step(0));
    expect(server.sends(), expected(0)['sends'], reason: step(0));
    expect(server.stored, expected(0)['stored'], reason: step(0));
    expect(core.isIdentified, expected(0)['held_in_memory'], reason: step(0));
    expect(server.nothingSavedHolds('u1'), isTrue, reason: 'the raw id is in no file');

    // 1: session S1 opens; its answer carries the salt.
    await settle();
    expect(server.sends(), expected(1)['sends'], reason: step(1));
    expect(server.stored, expected(1)['stored'], reason: step(1));

    // 2: identify("u1") again in S1.
    var from = server.sendCount;
    var device = core.deviceId;
    expect(core.identify('u1'), isNull, reason: step(2));
    await settle();
    expect(server.sends(from), expected(2)['sends'], reason: step(2));
    expect(core.deviceId != device, expected(2)['device_changed'], reason: step(2));

    // 3: relaunch; S2 opens with the same salt, with no call.
    core = server.launch();
    expect(core.isIdentified, isTrue, reason: 'read back at start');
    from = server.sendCount;
    await settle();
    expect(server.sends(from), expected(3)['sends'], reason: step(3));

    // 4: an email is refused.
    from = server.sendCount;
    device = core.deviceId;
    expect(core.identify('player@example.com'), expected(4)['refused'], reason: step(4));
    await settle();
    expect(server.sends(from), expected(4)['sends'], reason: step(4));
    expect(server.stored, expected(4)['stored'], reason: step(4));
    expect(core.deviceId != device, expected(4)['device_changed'], reason: step(4));

    // 5: another account: a fresh device id and session S3.
    from = server.sendCount;
    device = core.deviceId;
    expect(core.identify('u2'), isNull, reason: step(5));
    await settle();
    expect(server.sends(from), expected(5)['sends'], reason: step(5));
    expect(server.stored, expected(5)['stored'], reason: step(5));
    expect(core.deviceId != device, expected(5)['device_changed'], reason: step(5));
    expect(core.sessionToken, expected(5)['new_session'], reason: step(5));
    expect(server.storage.read(deviceIdFile), core.deviceId, reason: 'the new device id is saved');

    // 6: resetIdentity(): a fresh device id and session S4, nothing sent.
    from = server.sendCount;
    device = core.deviceId;
    core.resetIdentity();
    await settle();
    expect(server.sends(from), expected(6)['sends'], reason: step(6));
    expect(server.stored, expected(6)['stored'], reason: step(6));
    expect(core.deviceId != device, expected(6)['device_changed'], reason: step(6));
    expect(core.sessionToken, expected(6)['new_session'], reason: step(6));
    expect(core.isIdentified, isFalse, reason: step(6));

    // 7: resetIdentity() again with nothing stored.
    from = server.sendCount;
    device = core.deviceId;
    core.resetIdentity();
    await settle();
    expect(server.sends(from), expected(7)['sends'], reason: step(7));
    expect(server.stored, expected(7)['stored'], reason: step(7));
    expect(core.deviceId != device, expected(7)['device_changed'], reason: step(7));

    // 8: identify("u3"), answered 429 needs_funds: kept, never in a loop.
    from = server.sendCount;
    server.identifyAnswers.add(RsResponse(429, '{"error":"quota_exceeded","reason":"needs_funds"}'));
    expect(core.identify('u3'), isNull, reason: step(8));
    await settle();
    expect(server.sends(from), expected(8)['sends'], reason: step(8));
    expect(server.stored, expected(8)['stored'], reason: step(8));
    core.identify('u3');
    await settle();
    expect(server.sendCount, from + 1, reason: 'never in a loop');

    // 9: relaunch; S5 answers a different salt: deleted, never sent.
    server.salt = (vectors['salts_differ'] as Map<String, dynamic>)['salt_b'] as String;
    core = server.launch();
    from = server.sendCount;
    await settle();
    expect(core.sessionToken, 'S5');
    expect(server.sends(from), expected(9)['sends'], reason: step(9));
    expect(server.stored, expected(9)['stored'], reason: step(9));
    expect(core.isIdentified, isFalse, reason: step(9));

    // 10: relaunch; identify("u4"); the session answer has no salt.
    server.salt = null;
    core = server.launch();
    from = server.sendCount;
    expect(core.identify('u4'), isNull, reason: step(10));
    await settle();
    expect(server.sends(from), expected(10)['sends'], reason: step(10));
    expect(server.stored, expected(10)['stored'], reason: step(10));
    expect(core.isIdentified, isFalse, reason: 'the held id is dropped');
    expect(core.identify('u4'), isNull, reason: 'still a valid id');
    await settle();
    expect(server.sendCount, from, reason: 'unavailable for the rest of the launch');
    expect(core.isIdentified, isFalse);

    // 11: the player opts out.
    core.setTrackingEnabled(false);
    await settle();
    expect(server.sends(from), expected(11)['sends'], reason: step(11));
    expect(server.stored, expected(11)['stored'], reason: step(11));
  });

  test('needs_funds, identify_limited, rate limits, 409s, 5xx and offline are tried again at the next session only', () async {
    final answers = <RsResponse>[
      RsResponse(429, '{"error":"quota_exceeded","reason":"needs_funds"}'),
      RsResponse(429, '{"error":"identify_limited"}', {'retry-after': '3600'}),
      RsResponse(429, '{"error":"rate_limited"}'),
      RsResponse(409, '{"error":"session_taken"}'),
      RsResponse(409, '{"error":"synthetic_session"}'),
      RsResponse(503, ''),
      RsResponse(500, '{"error":"internal"}'),
      RsResponse(0),
    ];
    for (final answer in answers) {
      final label = 'HTTP ${answer.status} ${answer.body}';
      final server = FakeServer(salt: salt);
      final core = server.launch();
      await settle();
      server.identifyAnswers.add(answer);
      core.identify('u1');
      await settle();
      core.identify('u1');
      await settle();
      expect(server.sendCount, 1, reason: 'no retry in the session: $label');
      expect(server.stored, isNotNull, reason: 'kept: $label');
      await server.nextSession();
      expect(core.sessionToken, 'S2', reason: label);
      expect(server.sendCount, 2, reason: 'again at the next session: $label');
      expect(server.sends()[1]['session'], 'S2', reason: label);
    }
  });

  test('a 404 or invalid_account_hash is not tried again this launch; the next launch tries again', () async {
    for (final answer in [RsResponse(404, '{"error":"not_found"}'), RsResponse(400, '{"error":"invalid_account_hash"}')]) {
      final label = answer.body;
      final server = FakeServer(salt: salt);
      final core = server.launch();
      await settle();
      server.identifyAnswers.add(answer);
      core.identify('u1');
      await settle();
      await server.nextSession();
      core.resetDeviceId();
      await settle();
      expect(server.sendCount, 1, reason: 'not tried again: $label');
      expect(server.stored, isNotNull, reason: 'kept: $label');
      server.launch();
      await settle();
      expect(server.sendCount, 2, reason: 'the next launch tries again: $label');
    }
  });

  test('400 no_session: again at the next session, once; a second in a row stops it until resetIdentity', () async {
    const noSession = '{"error":"no_session"}';
    final server = FakeServer(salt: salt);
    final core = server.launch();
    await settle();
    server.identifyAnswers.add(RsResponse(400, noSession));
    core.identify('u1');
    await settle();
    expect(server.sendCount, 1);
    server.identifyAnswers.add(RsResponse(400, noSession));
    await server.nextSession();
    expect(server.sendCount, 2, reason: 'again, once');
    await server.nextSession();
    expect(server.sendCount, 2, reason: 'a second no_session in a row stops it');
    core.identify('u1');
    await settle();
    expect(server.sendCount, 2, reason: 'the same account again does not restart it');
    core.resetIdentity();
    await settle();
    core.identify('u1');
    await settle();
    expect(server.sendCount, 3, reason: 'resetIdentity clears the stop');
    expect(server.sends()[2]['session'], core.sessionToken);
  });

  test('any other answer between two no_session answers clears the count', () async {
    const noSession = '{"error":"no_session"}';
    final server = FakeServer(salt: salt);
    final core = server.launch();
    await settle();
    server.identifyAnswers.addAll([RsResponse(400, noSession), RsResponse(500, '{}'), RsResponse(400, noSession)]);
    core.identify('u1');
    await settle();
    await server.nextSession();
    await server.nextSession();
    await server.nextSession();
    expect(server.sendCount, 4, reason: 'one request a session, never stopped');
  });

  test('resetDeviceId alone keeps the identity, and the next session identifies again', () async {
    final server = FakeServer(salt: salt);
    final core = server.launch();
    await settle();
    core.identify('u1');
    await settle();
    final saved = server.storage.read(identityFile);
    final device = core.deviceId;
    core.resetDeviceId();
    expect(server.storage.read(identityFile), saved);
    expect(core.isIdentified, isTrue);
    await settle();
    expect(core.deviceId, isNot(device));
    expect(server.sendCount, 2);
    expect(server.sends()[1]['session'], core.sessionToken);
  });

  test('with no session open, identify opens one for the waiting identity', () async {
    final server = FakeServer(salt: salt);
    final core = server.launch();
    await settle();
    server.wallMs += 3601 * 1000;
    core.identify('u1');
    await settle();
    expect(server.sends(), [
      {'session': 'S2', 'accountHash': expected(1)['stored']['accountHash']}
    ]);
  });

  test('the request: POST /api/v1/identify with the key, the session token and exactly { accountHash }', () async {
    final server = FakeServer(salt: salt);
    final core = server.launch();
    await settle();
    core.identify('12345');
    await settle();
    final request = server.identifyRequests.single;
    expect(request.method, 'POST');
    expect(request.url, 'https://api.test/api/v1/identify');
    expect(request.headers['X-API-Key'], 'gt_pub_test');
    expect(request.headers['X-Session-Token'], core.sessionToken);
    final body = utf8.decode(request.body!);
    expect(body, '{"accountHash":"${accept.first['wire']}"}');
    expect(body.contains(core.deviceId), isFalse);
    expect(body.contains('12345'), isFalse);
  });

  test('identify never enters the queue or the saved queue, and never holds back an event', () async {
    final server = FakeServer(salt: salt);
    final core = server.launch();
    await settle();
    server.hold.add('/api/v1/identify');
    core.identify('u1');
    expect(core.pending, isEmpty);
    core.track('a');
    await core.flush();
    await settle();
    expect(server.held, hasLength(1), reason: 'identify is still unanswered');
    final batches = server.requests.where((request) => request.url.endsWith('/api/v1/track/batch')).toList();
    expect(utf8.decode(batches.last.body!).contains('"event":"a"'), isTrue, reason: 'the event went out meanwhile');
    core.track('b');
    core.saveQueue();
    final hash = server.stored!['accountHash'] as String;
    for (final entry in server.storage.files.entries) {
      if (entry.key != identityFile) expect(entry.value.contains(hash), isFalse, reason: entry.key);
    }
  });

  test('opt_in: held in memory before the yes, then hashed, stored and sent; withdrawing deletes it', () async {
    final storedU1 = expected(1)['stored'];
    final server = FakeServer(salt: salt);
    final core = server.launch(consent: 'opt_in');
    expect(core.identify('u1'), isNull);
    expect(core.isIdentified, isTrue);
    await settle();
    expect(server.requests, isEmpty, reason: 'nothing before the yes');
    expect(server.stored, isNull);
    core.setTrackingEnabled(true);
    await settle();
    expect(server.sendCount, 1, reason: 'sent after the yes');
    expect(server.stored, storedU1);
    core.setTrackingEnabled(false);
    expect(server.stored, isNull, reason: 'withdrawing deletes it');
    expect(core.isIdentified, isFalse);
    // A saved identity is never read before the yes.
    server.storage.write(identityFile, jsonEncode(storedU1));
    final later = server.launch(consent: 'opt_in');
    expect(later.isIdentified, isFalse);
  });

  test('the player opting out deletes a stored identity and drops a held id', () async {
    final server = FakeServer(salt: salt);
    final core = server.launch();
    await settle();
    core.identify('u1');
    await settle();
    expect(server.stored, isNotNull);
    core.setTrackingEnabled(false);
    expect(server.stored, isNull);
    expect(core.isIdentified, isFalse);

    final other = FakeServer(salt: salt);
    final held = other.launch();
    held.identify('u1');
    held.setTrackingEnabled(false);
    expect(held.isIdentified, isFalse);
    held.setTrackingEnabled(true);
    await settle();
    expect(other.sendCount, 0, reason: 'the dropped id is never sent');
  });

  test('a late 200 after resetIdentity changes nothing', () async {
    final server = FakeServer(salt: salt);
    final core = server.launch();
    await settle();
    server.hold.add('/api/v1/identify');
    core.identify('u1');
    await settle();
    expect(server.held, hasLength(1));
    core.resetIdentity();
    await settle();
    server.hold.clear();
    server.release(RsResponse(200, '{"playerId":"px_x"}'));
    await settle();
    expect(core.isIdentified, isFalse);
    expect(server.stored, isNull);
    core.identify('u1');
    await settle();
    expect(server.sendCount, 2, reason: 'the same account on the new session is sent');
    expect(server.sends()[1]['session'], core.sessionToken);
  });

  test('a malformed saved identity is ignored', () async {
    for (final bad in ['not json', '{"salt":"x","accountHash":"y"}', '[1,2]', '{"salt":"$salt"}']) {
      final server = FakeServer(salt: salt);
      server.storage.write(identityFile, bad);
      final core = server.launch();
      expect(core.isIdentified, isFalse, reason: bad);
      await settle();
      expect(server.sendCount, 0, reason: bad);
    }
  });

  test('the same account held before the salt is hashed under a new salt, never lost', () async {
    final d = vectors['salts_differ'] as Map<String, dynamic>;
    final id = d['accountId'] as String;
    final server = FakeServer(salt: d['salt_a'] as String);
    final first = server.launch();
    await settle();
    first.identify(id);
    await settle();
    expect(server.sends().single['accountHash'], d['wire_a']);
    server.salt = d['salt_b'] as String;
    final core = server.launch();
    core.identify(id);
    await settle();
    final sends = server.sends(1);
    expect(sends, hasLength(1), reason: 'not lost');
    expect(sends.single['accountHash'], d['wire_b'], reason: 'hashed under the new salt');
    expect(server.stored, {'salt': d['salt_b'], 'accountHash': d['wire_b']});
    expect(core.isIdentified, isTrue);
  });

  test('before the opt-in yes, a decline or resetIdentity removes an identity on disk', () async {
    final saved = jsonEncode(expected(1)['stored']);
    final server = FakeServer(salt: salt);
    server.storage.write(identityFile, saved);
    final declined = server.launch(consent: 'opt_in');
    declined.setTrackingEnabled(false);
    expect(server.storage.read(identityFile), isNull, reason: 'a decline deletes it');

    final other = FakeServer(salt: salt);
    final oldId = '${'0' * 32}-android';
    other.storage.write(identityFile, saved);
    other.storage.write(deviceIdFile, oldId);
    final core = other.launch(consent: 'opt_in');
    core.resetIdentity();
    expect(other.storage.read(identityFile), isNull, reason: 'a sign-out before the yes deletes it');
    expect(other.storage.read(deviceIdFile), isNull, reason: 'no device id until the yes');
    core.setTrackingEnabled(true);
    await settle();
    expect(core.deviceId, isNot(oldId), reason: 'the device id is rotated');
    expect(core.deviceId, isNotEmpty);
    expect(other.sendCount, 0, reason: 'the signed-out hash is never sent');
  });

  test('without a key: validated and held in memory only, no file and no request', () async {
    final server = FakeServer(salt: salt);
    final core = server.launch(ingestKey: '');
    expect(core.identify(''), 'empty');
    expect(core.identify('u1'), isNull);
    expect(core.isIdentified, isTrue);
    core.resetIdentity();
    expect(core.isIdentified, isFalse);
    expect(core.deviceId, isEmpty);
    await settle();
    expect(server.requests, isEmpty);
    expect(server.storage.files, isEmpty);
  });
}
