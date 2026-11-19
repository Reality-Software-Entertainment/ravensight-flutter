// dart:io: files in the app's support folder, HttpClient, gzip.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

import 'package:ravensight_core/ravensight_core.dart';

const Duration requestTimeout = Duration(seconds: 15);

/// The session's platform: android, ios, macos, windows, linux.
String platformName() => Platform.operatingSystem;

/// The OS name in the device id.
String osName() => Platform.operatingSystem;

/// iOS and Android: the background rule applies.
bool isMobile() => Platform.isAndroid || Platform.isIOS;

/// gzip, from dart:io.
List<int> Function(List<int>)? gzipEncoder() => (bytes) => gzip.encode(bytes);

/// No page address here: an app passes the `rs_link` of the address it was
/// opened with to `Ravensight.setCampaignLink` from its own deep link
/// handling.
String? landingCampaignLink() => null;

/// Files in `<application support>/ravensight`, written through a
/// temporary file and a rename so a partial file never replaces a good one.
class FileStorage implements RsStorage {
  FileStorage(this.directory);
  final Directory directory;
  final Random _random = Random.secure();

  File _file(String name) => File('${directory.path}${Platform.pathSeparator}$name');

  @override
  String? read(String name) {
    try {
      final file = _file(name);
      if (!file.existsSync()) {
        // A write interrupted on Windows between delete and rename.
        final temp = File('${file.path}.tmp');
        return temp.existsSync() ? temp.readAsStringSync() : null;
      }
      return file.readAsStringSync();
    } catch (_) {
      return null;
    }
  }

  @override
  void write(String name, String text) {
    directory.createSync(recursive: true);
    final target = _file(name);
    final temp = File('${target.path}.${_random.nextInt(1 << 32).toRadixString(16)}.tmp');
    try {
      temp.writeAsStringSync(text, flush: true);
      try {
        temp.renameSync(target.path);
      } on FileSystemException {
        // A platform that cannot rename over a file: remove it first.
        if (target.existsSync()) target.deleteSync();
        temp.renameSync(target.path);
      }
    } catch (_) {
      try {
        if (temp.existsSync()) temp.deleteSync();
      } catch (_) {
        // Never written.
      }
      rethrow;
    }
  }

  @override
  void remove(String name) {
    try {
      final file = _file(name);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // Already gone.
    }
  }
}

/// The SDK's folder: `<application support>/ravensight`.
Future<RsStorage> openStorage() async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory('${base.path}${Platform.pathSeparator}ravensight');
  dir.createSync(recursive: true);
  // Temporary files left by a write that never finished.
  try {
    for (final entry in dir.listSync()) {
      if (entry is File && entry.path.endsWith('.tmp')) entry.deleteSync();
    }
  } catch (_) {
    // Nothing to tidy.
  }
  return FileStorage(dir);
}

/// One HttpClient for the SDK. A network failure or a timeout is status 0.
RsTransport httpTransport() {
  final client = HttpClient()..connectionTimeout = requestTimeout;
  return (RsRequest r) async {
    try {
      final request = await client.openUrl(r.method, Uri.parse(r.url)).timeout(requestTimeout);
      r.headers.forEach(request.headers.set);
      final body = r.body;
      if (body != null) {
        request.contentLength = body.length;
        request.add(body);
      }
      final response = await request.close().timeout(requestTimeout);
      final text = await response.transform(utf8.decoder).join().timeout(requestTimeout);
      final headers = <String, String>{};
      response.headers.forEach((name, values) => headers[name.toLowerCase()] = values.join(','));
      return RsResponse(response.statusCode, text, headers);
    } catch (_) {
      return RsResponse(0);
    }
  };
}
