// The on-device scrub for automatic error captures: the same rules, in the
// same order, as the server (docs/errors/CONTRACT.md, "Scrub"), checked
// against the shared scrub-vectors.json (version 6).

final RegExp _urlQuery = RegExp(r'''(?<![a-z0-9+.-])([a-z][a-z0-9+.-]*://)(?:[^\s/?#@'"<>]*@)?([^\s?#'"<>]*)(?:[?#][^\s'"<>]*)?''', caseSensitive: false);
final RegExp _bearer = RegExp(r'\bBearer\s+[A-Za-z0-9\-._~+/]+=*', caseSensitive: false);
final RegExp _jwt = RegExp(r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*');
final RegExp _gtKey = RegExp(r'\bgt_[A-Za-z0-9_]+');
final RegExp _email = RegExp(r'(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');
final RegExp _homeUnix = RegExp(r'''/(?:Users|home)/[^/\\'"<>:\r\n]+''');
final RegExp _homeWindows = RegExp(r'''\b[A-Za-z]:[\\/](?:Users|Documents and Settings)[\\/][^/\\'"<>:\r\n]+''', caseSensitive: false);
final RegExp _ipv4 = RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b');
final RegExp _ipv6Full = RegExp(r'\b(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}\b', caseSensitive: false);
final RegExp _ipv6Short = RegExp(r'(?:\b[0-9a-f]{1,4}(?::[0-9a-f]{1,4}){0,6})?::(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4}){0,6}\b)?', caseSensitive: false);
final RegExp _longRun = RegExp(r'(?<![A-Za-z0-9+/=_-])[A-Za-z0-9+/=_-]{32,}');
final List<RegExp> _pathParts = [
  RegExp(r'^[a-z0-9]+$'),
  RegExp(r'^[A-Z][a-z0-9]*(?:[A-Z][a-z0-9]+)*$'),
  RegExp(r'^[A-Z0-9]{1,6}$'),
];
final RegExp _digit = RegExp(r'\d');

bool _isPathWord(String piece) =>
    piece.isEmpty || (piece.length < 32 && piece.split(RegExp(r'[_-]')).every((part) => part.isNotEmpty && _pathParts.any((p) => p.hasMatch(part))));

/// True when a long run is a file path rather than a secret.
bool isPath(String run) => run.contains('/') && run.split('/').every(_isPathWord);

/// The scrubbed text. Idempotent: scrubbing twice changes nothing more.
String scrubText(String value) {
  if (value.isEmpty) return value;
  return value
      .replaceAllMapped(_urlQuery, (m) => '${m[1]}${m[2]}')
      .replaceAll(_bearer, '[token]')
      .replaceAll(_jwt, '[token]')
      .replaceAll(_gtKey, '[token]')
      .replaceAll(_email, '[email]')
      .replaceAll(_homeWindows, '~')
      .replaceAll(_homeUnix, '~')
      .replaceAll(_ipv4, '[ip]')
      .replaceAll(_ipv6Full, '[ip]')
      .replaceAllMapped(_ipv6Short, (m) => _digit.hasMatch(m[0]!) ? '[ip]' : m[0]!)
      .replaceAllMapped(_longRun, (m) => _digit.hasMatch(m[0]!) && !isPath(m[0]!) ? '[token]' : m[0]!);
}
