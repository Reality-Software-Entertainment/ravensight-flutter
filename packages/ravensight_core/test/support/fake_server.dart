// A fake Ravensight server, network and clock for the identify and campaign
// link tests, in the shape of the World in core_test.dart: it answers by
// path and records every request. Sessions answer the tokens S1, S2, ... in
// order and carry identify.salt while [FakeServer.salt] is set. A relaunch
// is a new core over the same storage, so files and session numbers carry
// over from one launch to the next.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ravensight_core/ravensight_core.dart';

Map<String, dynamic> fixture(String name) => jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map<String, dynamic>;

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class FakeServer {
  FakeServer({this.salt});

  /// The salt every session answer carries, or null for an older server.
  String? salt;
  final MemoryStorage storage = MemoryStorage();
  final List<RsRequest> requests = [];
  int sessions = 0;
  int wallMs = 1800000000000;
  double clock = 0;
  int _hex = 0;

  /// Answers for the next session requests, in order; after them, a 201
  /// with the next token.
  final List<RsResponse> sessionAnswers = [];

  /// Answers for the next identify requests, in order; after them, a 200.
  final List<RsResponse> identifyAnswers = [];

  /// Requests whose path ends with one of these wait in [held] until
  /// [release] answers them.
  final Set<String> hold = {};
  final List<(RsRequest, Completer<RsResponse>)> held = [];

  late RavensightCore core;

  /// A new core over this server's storage, not started yet.
  RavensightCore create({String consent = 'opt_out', String ingestKey = 'gt_pub_test'}) {
    core = RavensightCore(
      CoreConfig(ingestKey: ingestKey, apiUrl: 'https://api.test', gameVersion: '1.2.0', platform: 'android', osName: 'android', consent: consent),
      CoreDeps(
        transport: _transport,
        storage: storage,
        wallMs: () => wallMs,
        monotonicSeconds: () => clock,
        random: () => 1.0,
        randomHex: (bytes) {
          _hex += 1;
          return _hex.toRadixString(16).padLeft(bytes * 2, '0');
        },
      ),
    );
    return core;
  }

  /// A launch: a new core over the same storage, started.
  RavensightCore launch({String consent = 'opt_out', String ingestKey = 'gt_pub_test'}) => create(consent: consent, ingestKey: ingestKey)..start();

  Future<RsResponse> _transport(RsRequest request) {
    requests.add(request);
    final path = Uri.parse(request.url).path;
    if (hold.any(path.endsWith)) {
      final completer = Completer<RsResponse>();
      held.add((request, completer));
      return completer.future;
    }
    return Future<RsResponse>.value(answerFor(request));
  }

  /// The answer this server gives [request] now.
  RsResponse answerFor(RsRequest request) {
    final path = Uri.parse(request.url).path;
    if (path.endsWith('/settings')) return RsResponse(200, '{"trackingEnabled":true}');
    if (path.endsWith('/session')) {
      if (sessionAnswers.isNotEmpty) return sessionAnswers.removeAt(0);
      sessions += 1;
      final offered = salt;
      return RsResponse(201, jsonEncode({'token': 'S$sessions', 'expiresIn': 3600, if (offered != null) 'identify': {'salt': offered}}));
    }
    if (path.endsWith('/identify')) {
      if (identifyAnswers.isNotEmpty) return identifyAnswers.removeAt(0);
      return RsResponse(200, '{"playerId":"px_test","linked":true,"verified":false,"repeat":false}');
    }
    if (path.endsWith('/track/batch')) return RsResponse(202, '{}');
    return RsResponse(404, '{}');
  }

  /// Answers the oldest held request: with [answer], or as the server
  /// would answer it now.
  void release([RsResponse? answer]) {
    final (request, completer) = held.removeAt(0);
    completer.complete(answer ?? answerFor(request));
  }

  /// Moves both clocks on in half-second steps, ticking the core.
  Future<void> tick(double seconds) async {
    final end = clock + seconds;
    while (clock < end) {
      clock = clock + 0.5 > end ? end : clock + 0.5;
      wallMs += 500;
      core.tick();
      await settle();
    }
  }

  /// The open session expires; the next event opens a new one.
  Future<void> nextSession() async {
    wallMs += 3601 * 1000;
    core.track('tick');
    await settle();
  }

  List<RsRequest> get identifyRequests => requests.where((request) => request.url.endsWith('/api/v1/identify')).toList();

  int get sendCount => identifyRequests.length;

  /// The identify requests from [from] on, written as the vectors write
  /// them: the session token and the account hash.
  List<Map<String, String>> sends([int from = 0]) => [
        for (final request in identifyRequests.skip(from))
          {
            'session': request.headers['X-Session-Token'] ?? '',
            'accountHash': (jsonDecode(utf8.decode(request.body ?? const <int>[])) as Map)['accountHash'] as String,
          },
      ];

  /// The saved identity, decoded, or null.
  Map<String, dynamic>? get stored {
    final text = storage.read(identityFile);
    return text == null ? null : jsonDecode(text) as Map<String, dynamic>;
  }

  /// The campaignLink of every session request so far, '-' for none.
  List<String> get links => [
        for (final request in requests.where((sent) => sent.url.endsWith('/api/v1/session')))
          ((jsonDecode(utf8.decode(request.body ?? const <int>[])) as Map)['campaignLink'] as String?) ?? '-',
      ];

  /// True when no saved file holds [text], in any case.
  bool nothingSavedHolds(String text) => storage.files.values.every((content) => !content.toLowerCase().contains(text.toLowerCase()));
}
