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
    expect(Ravensight.statusReason, 'disabled');
    expect(await Ravensight.submitFeedback('hi'), 'disabled');
    Ravensight.setTrackingEnabled(false);
    await Ravensight.flush();
    await Ravensight.quit();
  });

  test('the helpers are exported', () {
    expect(microsFromRevenue(0.0015), '1500');
    expect(microsFromDecimalString('1.23456789'), '1234568');
    expect(adFormatFrom('INTER'), 'interstitial');
    expect(sdkVersion, '0.1.0');
  });

  test('an ad the server would flag is refused locally', () {
    expect(Ravensight.trackAd('admob', 'rewarded', 'clicked', revenueMicros: '1', currency: 'USD'), isFalse);
    expect(Ravensight.trackAdRevenue('admob', 'rewarded', 'end', '1500', ''), isFalse);
  });
}
