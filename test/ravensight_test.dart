// The Flutter facade without a key: inert, every call a safe no-op. The
// state machine itself is tested in packages/ravensight_core.
import 'package:flutter_test/flutter_test.dart';
import 'package:ravensight/ravensight.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(Ravensight.reset);

  test('no key: inert, nothing collected, every call safe', () async {
    expect(await Ravensight.init(ingestKey: null, optional: true), isFalse);
    expect(await Ravensight.init(ingestKey: '   ', optional: true), isFalse);
    expect(Ravensight.isEnabled, isFalse);
    expect(Ravensight.track('x', {'a': 1}), isFalse);
    expect(Ravensight.levelStart('forest_1'), isFalse);
    expect(Ravensight.trackError('boom'), isFalse);
    expect(Ravensight.setAttribution(source: 'organic'), isFalse);
    expect(Ravensight.getConfig('speed', 3), 3);
    expect(await Ravensight.fetchConfig(), 'default');
    expect(Ravensight.deviceId, isNull);
    expect(Ravensight.resetDeviceId(), isNull);
    expect(Ravensight.statusReason, 'disabled');
    expect(await Ravensight.submitFeedback('hi'), 'disabled');
    Ravensight.setTrackingEnabled(false);
    await Ravensight.flush();
    await Ravensight.quit();
  });

  test('no key: identify and a campaign link are held in memory only', () async {
    expect(await Ravensight.init(ingestKey: null, optional: true), isFalse);
    expect(Ravensight.isIdentified, isFalse);
    expect(Ravensight.identify('3f2a9c1e-7b4d-4e8a-9c3f-1a2b3c4d5e6f'), isTrue);
    expect(Ravensight.isIdentified, isTrue);
    Ravensight.resetIdentity();
    expect(Ravensight.isIdentified, isFalse);
    expect(Ravensight.deviceId, isNull);
    expect(Ravensight.setCampaignLink('64B0000000000000000000A1'), isTrue);
  });

  test('identify refuses an empty, too long or email-like id and changes nothing', () {
    expect(Ravensight.identify(''), isFalse);
    expect(Ravensight.identify('player@example.com'), isFalse);
    expect(Ravensight.identify('@handle'), isFalse);
    expect(Ravensight.identify('a' * 257), isFalse);
    expect(Ravensight.identify('é' * 129), isFalse);
    expect(Ravensight.isIdentified, isFalse);
    expect(Ravensight.identify('a' * 256), isTrue, reason: 'exactly 256 bytes is accepted');
    expect(Ravensight.identify('  spaced  '), isTrue, reason: 'never trimmed');
  });

  test('a campaign link is exactly 24 hex characters', () {
    expect(Ravensight.setCampaignLink('64b0000000000000000000a1'), isTrue);
    expect(Ravensight.setCampaignLink(' 64b0000000000000000000a1'), isFalse);
    expect(Ravensight.setCampaignLink('64b0000000000000000000a'), isFalse);
    expect(Ravensight.setCampaignLink('not a link'), isFalse);
  });

  test('the helpers are exported', () {
    expect(microsFromRevenue(0.0015), '1500');
    expect(microsFromDecimalString('1.23456789'), '1234568');
    expect(adFormatFrom('INTER'), 'interstitial');
    expect(sdkVersion, '0.2.0');
  });

  test('an ad the server would flag is refused locally', () {
    expect(Ravensight.trackAd('my_network', 'rewarded', 'clicked', revenueMicros: '1', currency: 'USD'), isFalse);
    expect(Ravensight.trackAdRevenue('my_network', 'rewarded', 'end', '1500', ''), isFalse);
  });
}
