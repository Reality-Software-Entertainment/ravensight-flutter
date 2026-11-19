// The pure pieces of the wire contract: limits, the queue file name, event
// ids, event size as the server measures it, request signatures, micros and
// the typed event helpers. No Flutter, no I/O.
//
// Contracts: DELIVERY_CONTRACT.md, ADS_ATTRIBUTION_CONTRACT.md,
// docs/errors/CONTRACT.md and docs/identify/CONTRACT.md on the Ravensight
// platform.

import 'dart:convert';

import 'package:crypto/crypto.dart';

const String sdkVersion = '0.2.0';
const String sdkName = 'flutter';
const String defaultApiUrl = 'https://api.ravensight.io';

const int maxBatchSize = 50;
const int maxEventBytes = 8192;
const int maxPersistedEvents = 500;
const int queueFormatVersion = 2;
const int queueMaxAgeMs = 89 * 86400 * 1000;
const int gzipMinBytes = 1024;
const int defaultRetrySeconds = 10;
const int maxBackoffSeconds = 300;
const double jitterMinFactor = 0.5;
const int deviceFieldMaxChars = 128;
const int maxNameChars = 200;

/// Error text caps, counted one byte a character in the size rule.
const Map<String, int> typedTextCaps = {'rs_message': 200, 'rs_stack': 2000, 'rs_trail': 1500};

/// 400 answers about one event that carry no index: halve until it is alone.
const Set<String> perEvent400 = {
  'event_too_large',
  'event_name_too_long',
  'missing_event',
  'invalid_event_data',
  'invalid_event_id',
};

/// The API origin: whitespace trimmed, trailing slashes and a trailing
/// /api/v1 taken off. Empty means https://api.ravensight.io.
String normalizeApiUrl(String? url) {
  var base = (url ?? '').trim().replaceAll(RegExp(r'/+$'), '');
  base = base.replaceAll(RegExp(r'/api/v1$'), '').replaceAll(RegExp(r'/+$'), '');
  return base.isEmpty ? defaultApiUrl : base;
}

/// 64-bit FNV-1a of the key's UTF-8 bytes as 16 lowercase hex characters,
/// worked in two 32-bit halves so it is exact on the web too.
String fnv1a64(String text) {
  var hi = 0xcbf29ce4;
  var lo = 0x84222325;
  for (final byte in utf8.encode(text)) {
    lo ^= byte;
    // (hi:lo) * 0x100000001b3 mod 2^64, as 16-bit limbs.
    final l0 = lo & 0xffff, l1 = lo >>> 16, h0 = hi & 0xffff, h1 = hi >>> 16;
    var p0 = l0 * 0x1b3;
    var p1 = l1 * 0x1b3 + (p0 >>> 16);
    var p2 = h0 * 0x1b3 + (p1 >>> 16) + l0 * 0x100;
    var p3 = h1 * 0x1b3 + (p2 >>> 16) + l1 * 0x100;
    lo = ((p1 & 0xffff) << 16 | (p0 & 0xffff)) & 0xffffffff;
    hi = ((p3 & 0xffff) << 16 | (p2 & 0xffff)) & 0xffffffff;
  }
  return hi.toRadixString(16).padLeft(8, '0') + lo.toRadixString(16).padLeft(8, '0');
}

/// This key's queue file name.
String queueFileName(String ingestKey) => 'queue-${fnv1a64(ingestKey)}.json';

/// `rs_event_id`: the first 16 characters of the device id, the start time
/// in hex, a per-launch random nonce and a counter. At most 64 characters
/// of [A-Za-z0-9_-].
String eventId(String deviceId, int startSeconds, String nonce, int counter) {
  final head = deviceId.length > 16 ? deviceId.substring(0, 16) : deviceId;
  final id = '$head-${startSeconds.toRadixString(16)}-$nonce-$counter';
  final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
  return safe.length > 64 ? safe.substring(0, 64) : safe;
}

/// One event's data size as the server measures it: the UTF-8 bytes of its
/// JSON, except that an error event's message, stack and trail, each within
/// its cap, count one byte a character.
int eventDataBytes(Map<String, Object?> data) {
  var bytes = utf8.encode(jsonEncode(data)).length;
  if (data['rs_kind'] == 'error') {
    typedTextCaps.forEach((key, cap) {
      final value = data[key];
      if (value is String && value.length <= cap) {
        bytes -= utf8.encode(jsonEncode(value)).length - value.length;
      }
    });
  }
  return bytes;
}

/// Lowercase hex HMAC-SHA256 of "v1:<t>:<body>" keyed with the secret's
/// UTF-8 bytes (DELIVERY_CONTRACT section 7.3).
String signBody(String secret, int timestamp, String body) {
  final mac = Hmac(sha256, utf8.encode(secret));
  return mac.convert(utf8.encode('v1:$timestamp:$body')).toString();
}

/// The beacon envelope of section 7.4, for completeness and the vectors.
Map<String, Object?> signedBeaconBody(String sessionToken, String secret, int timestamp, String body) => {
      'sessionToken': sessionToken,
      'signed': {'v': 1, 't': timestamp, 'body': body, 'sig': signBody(secret, timestamp, body)},
    };

// --- identify and campaign links --------------------------------------------

/// The longest account id identify accepts, in bytes of UTF-8.
const int identifyMaxBytes = 256;

/// Why identify refuses [accountId], or null when it is accepted: `empty`,
/// `too_long` (over 256 bytes of UTF-8, counted in bytes, not characters)
/// or `looks_like_email` (any `@`). The id is used exactly as given, never
/// trimmed, lower-cased or normalised (docs/identify/CONTRACT.md).
String? identifyRefusal(String accountId) {
  if (accountId.isEmpty) return 'empty';
  if (utf8.encode(accountId).length > identifyMaxBytes) return 'too_long';
  if (accountId.contains('@')) return 'looks_like_email';
  return null;
}

/// `accountHash`: lowercase hex HMAC-SHA256 keyed with the UTF-8 bytes of
/// the salt exactly as the session answer gives it (64 hex characters, not
/// decoded), over the UTF-8 bytes of the account id.
String identifyAccountHash(String salt, String accountId) => Hmac(sha256, utf8.encode(salt)).convert(utf8.encode(accountId)).toString();

final RegExp _campaignLinkPattern = RegExp(r'^[0-9a-fA-F]{24}$');

/// A campaign link id lowercased, as the session sends it, or null when
/// [value] is not exactly 24 hex characters (any case, never trimmed).
String? campaignLinkId(String value) => _campaignLinkPattern.hasMatch(value) ? value.toLowerCase() : null;

/// `Retry-After` in whole seconds, or -1 when absent or not delta seconds.
int retryAfterSeconds(String? value) {
  if (value == null) return -1;
  final match = RegExp(r'^\s*(\d+)\s*$').firstMatch(value);
  return match == null ? -1 : int.parse(match.group(1)!);
}

/// A string cut to at most [limit] UTF-16 units, never inside a surrogate pair.
String cutText(String value, int limit) {
  if (value.length <= limit) return value;
  var end = limit;
  final unit = value.codeUnitAt(end - 1);
  if (unit >= 0xd800 && unit <= 0xdbff) end -= 1;
  return value.substring(0, end);
}

/// A device field as the contract allows it: printable, trimmed, at most
/// 128 characters, or null.
String? deviceField(String? value) {
  if (value == null) return null;
  final cleaned = cutText(value.replaceAll(RegExp(r'[\u0000-\u001f\u007f-\u009f]'), '').trim(), deviceFieldMaxChars).trim();
  return cleaned.isEmpty ? null : cleaned;
}

// --- micros ------------------------------------------------------------------

/// Revenue text in major units as whole micros, worked on the digits so no
/// float is ever multiplied: "0.0015" is "1500", half up past six decimals,
/// an exponent allowed. Null when it is not a non-negative decimal or does
/// not fit 18 digits.
String? microsFromDecimalString(String text) {
  final raw = text.trim();
  final match = RegExp(r'^\+?(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$').firstMatch(raw);
  if (match == null) return null;
  var intPart = match.group(1) ?? '';
  var frac = match.group(2) ?? '';
  if (intPart.isEmpty && frac.isEmpty) return null;
  final exp = match.group(3) == null ? 0 : int.parse(match.group(3)!);
  if (exp.abs() > 400) return null;
  if (exp > 0) {
    final moved = (frac.length >= exp ? frac.substring(0, exp) : frac).padRight(exp, '0');
    intPart += moved;
    frac = frac.length >= exp ? frac.substring(exp) : '';
  } else if (exp < 0) {
    final shift = -exp;
    final padded = intPart.padLeft(shift, '0');
    frac = padded.substring(padded.length - shift) + frac;
    intPart = padded.substring(0, padded.length - shift);
  }
  final six = (frac.length >= 6 ? frac.substring(0, 6) : frac).padRight(6, '0');
  final roundUp = frac.length > 6 && frac.codeUnitAt(6) >= 53;
  var digits = ((intPart.isEmpty ? '0' : intPart) + six).replaceFirst(RegExp(r'^0+(?=\d)'), '');
  if (roundUp) {
    final chars = digits.split('');
    var i = chars.length - 1;
    while (i >= 0) {
      if (chars[i] == '9') {
        chars[i] = '0';
        i -= 1;
      } else {
        chars[i] = String.fromCharCode(chars[i].codeUnitAt(0) + 1);
        break;
      }
    }
    digits = (i < 0 ? '1' : '') + chars.join();
  }
  digits = digits.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  return digits.length <= 18 ? digits : null;
}

/// A mediation callback's revenue (a double in major units) as micros: its
/// shortest round-trip text, then rounded on the digits. 0.0015 is "1500",
/// 1.23456789 is "1234568".
String? microsFromRevenue(num value) {
  if (value.isNaN || value.isInfinite || value < 0) return null;
  return microsFromDecimalString(value.toString());
}

const List<String> adFormats = ['banner', 'interstitial', 'rewarded', 'native', 'app_open', 'other'];
const List<String> adResults = ['shown', 'clicked', 'failed', 'rewarded'];

/// A mediation SDK's ad format name mapped onto rs_ad_format.
String adFormatFrom(String? name) {
  final key = (name ?? '').trim().toUpperCase();
  if (const ['BANNER', 'MREC', 'LEADER'].contains(key)) return 'banner';
  if (const ['INTER', 'INTERSTITIAL'].contains(key)) return 'interstitial';
  if (const ['REWARDED', 'REWARDED_VIDEO', 'REWARDED_INTER'].contains(key)) return 'rewarded';
  if (key == 'NATIVE') return 'native';
  if (key == 'APP_OPEN') return 'app_open';
  return 'other';
}

bool _textIn(Object? value, int min, int max) => value is String && value.length >= min && value.length <= max;

/// The data of one `rs_ad` event, or a reason it would be flagged. Revenue
/// only on `shown`, always with a currency, as a digit string of micros.
({Map<String, Object?>? data, String? reason}) adEvent(String network, String format, String result,
    {String? placement, Object? revenueMicros, String? currency}) {
  if (!_textIn(network, 1, 64)) return (data: null, reason: 'network is 1 to 64 characters');
  if (!adFormats.contains(format)) return (data: null, reason: 'format is one of ${adFormats.join(', ')}');
  if (!adResults.contains(result)) return (data: null, reason: 'result is one of ${adResults.join(', ')}');
  final data = <String, Object?>{
    'rs_kind': 'ad',
    'rs_ad_network': network,
    'rs_ad_format': format,
    'rs_ad_result': result,
  };
  if (placement != null && placement.isNotEmpty) {
    if (!_textIn(placement, 1, 100)) return (data: null, reason: 'placement is at most 100 characters');
    data['rs_ad_placement'] = placement;
  }
  if (revenueMicros != null) {
    if (result != 'shown') return (data: null, reason: 'revenue goes on shown only');
    String? micros;
    if (revenueMicros is String && RegExp(r'^\d{1,18}$').hasMatch(revenueMicros)) micros = revenueMicros;
    if (revenueMicros is int && revenueMicros >= 0 && revenueMicros <= 9007199254740991) micros = revenueMicros.toString();
    if (micros == null) return (data: null, reason: 'revenueMicros is a digit string of whole micros');
    if (currency == null || !RegExp(r'^[A-Za-z]{3}$').hasMatch(currency)) {
      return (data: null, reason: 'a revenue needs a three-letter currency');
    }
    data['rs_revenue_micros'] = micros;
    data['rs_currency'] = currency.toUpperCase();
  } else if (currency != null && currency.isNotEmpty) {
    return (data: null, reason: 'a currency is sent only with a revenue');
  }
  return (data: data, reason: null);
}

/// The data of one `rs_attribution` event, or a reason.
({Map<String, Object?>? data, String? reason}) attributionEvent(
    {required String source, String? network, String? campaign, String? adset, String? creative, int? touchTime}) {
  if (!_textIn(source, 1, 64)) return (data: null, reason: 'source is 1 to 64 characters');
  final data = <String, Object?>{'rs_kind': 'attribution', 'rs_attr_source': source};
  final fields = <(String, String?, String, int)>[
    ('network', network, 'rs_attr_network', 100),
    ('campaign', campaign, 'rs_campaign', 200),
    ('adset', adset, 'rs_adset', 200),
    ('creative', creative, 'rs_creative', 200),
  ];
  for (final (name, value, key, max) in fields) {
    if (value == null || value.isEmpty) continue;
    if (!_textIn(value, 1, max)) return (data: null, reason: '$name is at most $max characters');
    data[key] = value;
  }
  if (touchTime != null) {
    if (touchTime < 0 || touchTime > 9007199254740991) return (data: null, reason: 'touchTime is epoch milliseconds');
    data['rs_touch_time'] = touchTime;
  }
  return (data: data, reason: null);
}
