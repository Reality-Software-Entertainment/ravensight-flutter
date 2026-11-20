// A one-screen example: start Ravensight, track a level, read a remote
// config value, report an ad's revenue and give the player an analytics
// switch.
import 'package:material_ui/material_ui.dart';
import 'package:ravensight/ravensight.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Ravensight.init(
    ingestKey: const String.fromEnvironment('RAVENSIGHT_KEY'),
    gameVersion: '1.0.0',
    debug: true,
    optional: true,
  );
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: GameScreen());
}

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  int _jump = 5;
  bool _analytics = Ravensight.isEnabled;

  @override
  void initState() {
    super.initState();
    Ravensight.levelStart('forest_1');
    Ravensight.fetchConfig().then((_) {
      // Reading the value is what counts as seeing an experiment.
      if (mounted) setState(() => _jump = Ravensight.getConfig('jump_height', 5));
    });
  }

  void _win() => Ravensight.levelComplete('forest_1', {'time_s': 42});

  void _rewardedAdPaid(double revenue) {
    // A mediation callback's double, as micros, without a float multiply.
    final micros = microsFromRevenue(revenue);
    if (micros != null) Ravensight.trackAdRevenue('my_network', 'rewarded', 'level_end', micros, 'USD');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Ravensight example')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Jump height from remote config: $_jump'),
            const SizedBox(height: 16),
            FilledButton(onPressed: _win, child: const Text('Complete level')),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: () => _rewardedAdPaid(0.0015), child: const Text('Rewarded ad paid')),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => Ravensight.trackError('Shop failed to load', severity: 'warning'),
              child: const Text('Report an error'),
            ),
            SwitchListTile(
              title: const Text('Share analytics'),
              value: _analytics,
              onChanged: (on) {
                Ravensight.setTrackingEnabled(on);
                setState(() => _analytics = on);
              },
            ),
          ],
        ),
      );
}
