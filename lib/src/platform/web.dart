// The web: the browser's localStorage and fetch (through package:http).
// No gzip: the browser compresses nothing a page sends.

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import 'package:ravensight_core/ravensight_core.dart';

const Duration requestTimeout = Duration(seconds: 15);

String platformName() => 'web';
String osName() => 'web';
bool isMobile() => false;
List<int> Function(List<int>)? gzipEncoder() => null;

/// One localStorage entry per file, named `ravensight_<file>`.
class LocalStorage implements RsStorage {
  String _key(String name) => 'ravensight_$name';

  @override
  String? read(String name) {
    try {
      return web.window.localStorage.getItem(_key(name));
    } catch (_) {
      return null;
    }
  }

  @override
  void write(String name, String text) => web.window.localStorage.setItem(_key(name), text);

  @override
  void remove(String name) {
    try {
      web.window.localStorage.removeItem(_key(name));
    } catch (_) {
      // Storage unavailable.
    }
  }
}

Future<RsStorage> openStorage() async => LocalStorage();

RsTransport httpTransport() {
  final client = http.Client();
  return (RsRequest r) async {
    try {
      final request = http.Request(r.method, Uri.parse(r.url))..headers.addAll(r.headers);
      final body = r.body;
      if (body != null) request.bodyBytes = body;
      final streamed = await client.send(request).timeout(requestTimeout);
      final response = await http.Response.fromStream(streamed).timeout(requestTimeout);
      final headers = <String, String>{};
      response.headers.forEach((name, value) => headers[name.toLowerCase()] = value);
      return RsResponse(response.statusCode, response.body, headers);
    } catch (_) {
      return RsResponse(0);
    }
  };
}
