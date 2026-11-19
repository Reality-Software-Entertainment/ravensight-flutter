// Campaign links in the core: setCampaignLink(id), and campaignLink on the
// next POST /api/v1/session the core opens for its player, cleared only by
// a 201 with a token. Memory only, under the same key and consent rules as
// everything else. This SDK has no playtest mode, so the playtest rule has
// nothing to act on here.
import 'dart:convert';

import 'package:ravensight_core/ravensight_core.dart';
import 'package:test/test.dart';

import 'support/fake_server.dart';

const link = '64b0000000000000000000a1';
const link2 = '64b0000000000000000000b2';

void main() {
  test('a link id in upper case is sent lowercased on the first session, once', () async {
    final server = FakeServer();
    final core = server.create();
    expect(core.setCampaignLink(link.toUpperCase()), isTrue);
    expect(core.campaignLink, link);
    core.start();
    await settle();
    expect(server.links, [link], reason: 'campaignLink on the first POST /session');
    expect(core.sessionToken, 'S1');
    await server.nextSession();
    expect(server.links, [link, '-'], reason: 'the next session carries none');
    expect(server.nothingSavedHolds(link), isTrue, reason: 'the link is never saved');
    expect(core.setCampaignLink(link2), isTrue);
    await server.nextSession();
    await server.nextSession();
    expect(server.links, [link, '-', link2, '-'], reason: 'a later call goes with the next session only');

    final fresh = FakeServer();
    fresh.launch();
    await settle();
    expect(fresh.links, ['-'], reason: 'a new core starts with no link');
  });

  test('anything but a link id is refused, changes nothing and keeps a link already set', () async {
    final bad = <String>[
      '',
      'abc',
      link.substring(0, 23),
      '${link}0',
      'g' * 24,
      ' $link',
      '$link ',
      '$link\n',
      '\n$link',
      '${link.substring(0, 22)}-1',
      '${link.substring(0, 23)}\u0000',
      '٠' * 24,
    ];
    for (final value in bad) {
      final server = FakeServer();
      final core = server.create();
      expect(core.setCampaignLink(value), isFalse, reason: jsonEncode(value));
      expect(core.campaignLink, isNull, reason: jsonEncode(value));
      core.start();
      await settle();
      expect(server.links, ['-'], reason: jsonEncode(value));
    }
    final keeper = FakeServer();
    final kept = keeper.create();
    expect(kept.setCampaignLink(link), isTrue);
    expect(kept.setCampaignLink('zz'), isFalse);
    expect(kept.setCampaignLink(''), isFalse);
    kept.start();
    await settle();
    expect(keeper.links, [link], reason: 'a refused call keeps the earlier link');
  });

  test('campaignLinkId accepts 24 hex characters in any case and lowercases them', () {
    expect(campaignLinkId(link), link);
    expect(campaignLinkId('ABCDEF0123456789ABCDEF01'), 'abcdef0123456789abcdef01');
    expect(campaignLinkId('abcdeg0123456789abcdef01'), isNull);
    expect(campaignLinkId(''), isNull);
  });

  test('a failed, offline, rate-limited or token-less session answer keeps the link for the next attempt', () async {
    final server = FakeServer();
    server.sessionAnswers.addAll([
      RsResponse(500, '{"error":"internal_error"}'),
      RsResponse(0),
      RsResponse(429, '{"error":"rate_limited"}', {'retry-after': '5'}),
      RsResponse(201, '{"expiresIn":3600}'),
    ]);
    final core = server.create();
    core.setCampaignLink(link);
    core.start();
    await settle();
    await server.tick(100);
    expect(server.links, List.filled(5, link), reason: 'every attempt carried it');
    expect(core.sessionToken, 'S1');
    expect(core.campaignLink, isNull);
    await server.nextSession();
    expect(server.links, [...List.filled(5, link), '-'], reason: 'cleared once a session answered 201 with a token');
  });

  test('a link set while a session is opening goes with the next one', () async {
    final server = FakeServer();
    server.hold.add('/api/v1/session');
    final core = server.create();
    core.setCampaignLink(link);
    core.start();
    await settle();
    expect(server.links, [link]);
    expect(core.setCampaignLink(link2), isTrue);
    server.hold.clear();
    server.release();
    await settle();
    expect(core.sessionToken, 'S1');
    expect(core.campaignLink, link2, reason: 'an answer clears only the link its request carried');
    await server.nextSession();
    await server.nextSession();
    expect(server.links, [link, link2, '-']);
  });

  test('a 201 the core ignores (a device reset while it was in flight) still clears the link it carried', () async {
    final server = FakeServer();
    server.hold.add('/api/v1/session');
    final core = server.create();
    core.setCampaignLink(link);
    core.start();
    await settle();
    core.resetDeviceId();
    await settle();
    expect(server.held, hasLength(2), reason: 'the reset opens a session for the new id');
    server.release(RsResponse(201, jsonEncode({'token': 'old', 'expiresIn': 3600})));
    await settle();
    expect(core.sessionToken, isEmpty, reason: 'the stale answer is ignored');
    expect(core.campaignLink, isNull, reason: 'but the link it carried is spent');
    server.hold.clear();
    server.release();
    await settle();
    expect(core.sessionToken, 'S1');
    await server.nextSession();
    expect(server.links, [link, link, '-']);
  });

  test('opt_in: nothing before the yes, then the link goes with the first session; an opted out player sends nothing', () async {
    final server = FakeServer();
    final core = server.create(consent: 'opt_in');
    expect(core.setCampaignLink(link), isTrue);
    core.start();
    core.track('before');
    await core.flush();
    await server.tick(10);
    expect(server.requests, isEmpty, reason: 'no request before the yes');
    core.setTrackingEnabled(true);
    await settle();
    expect(server.links, [link], reason: 'with the first session after the yes');

    final out = FakeServer();
    out.storage.write(optOutFile, '1');
    final opted = out.create();
    expect(opted.setCampaignLink(link), isTrue);
    opted.start();
    opted.track('x');
    await opted.flush();
    await out.tick(10);
    expect(out.requests, isEmpty, reason: 'an opted out player sends nothing');
  });

  test('without a key nothing is sent and nothing is saved', () async {
    final server = FakeServer();
    final core = server.create(ingestKey: '');
    expect(core.setCampaignLink(link), isTrue);
    core.start();
    core.track('x');
    await server.tick(5);
    expect(server.requests, isEmpty);
    expect(server.storage.files, isEmpty);
  });
}
