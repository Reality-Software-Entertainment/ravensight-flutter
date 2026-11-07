// The platform layer: dart:io on Android, iOS, macOS, Windows and Linux;
// the browser on the web.
export 'io.dart' if (dart.library.js_interop) 'web.dart';
