// Error events and the device limits on automatic capture
// (docs/errors/CONTRACT.md). A manual trackError is sent as the game wrote
// it, cut to the field limits, and the server scrubs it. An automatic
// capture is scrubbed here first and held to the per-session limits: 30
// captures, 3 for one dedupe key and a token bucket of 6 a minute, checked
// before any scrub or template work.
//
// There is no log trail in this SDK: Flutter gives no hook on the app's own
// log lines, so rs_trail is never sent.

import 'scrub.dart';
import 'wire.dart';

const int messageChars = 200;
const int stackChars = 2000;
const int typeChars = 100;
const int sessionCap = 30;
const int perKeyCap = 3;
const int bucketSize = 6;
const int bucketSeconds = 60;
const int bootHold = 5;

const Set<String> severities = {'debug', 'info', 'warning', 'error', 'critical'};
const Set<String> sources = {'manual', 'uncaught', 'unhandled_rejection', 'request', 'console', 'log', 'dead_click', 'crash'};

/// One error the SDK or the game reports.
class ErrorInfo {
  ErrorInfo({required this.message, this.severity = 'error', this.stack, this.source = 'manual', this.errorType, this.props});
  final String message;
  final String severity;
  final String? stack;
  final String source;
  final String? errorType;
  final Map<String, Object?>? props;
}

String? _scrubbed(String? value, int limit) {
  if (value == null || value.isEmpty) return null;
  return cutText(scrubText(cutText(value, limit * 4)), limit);
}

/// The data of one error event. [scrub] is true for automatic captures.
Map<String, Object?> buildErrorData(ErrorInfo info, {required bool scrub}) {
  final data = <String, Object?>{...?info.props};
  data['rs_kind'] = 'error';
  data['rs_severity'] = severities.contains(info.severity) ? info.severity : 'error';
  if (scrub) {
    data['rs_message'] = _scrubbed(info.message, messageChars) ?? '';
    final stack = _scrubbed(info.stack, stackChars);
    if (stack != null && stack.isNotEmpty) data['rs_stack'] = stack;
  } else {
    data['rs_message'] = cutText(info.message, messageChars);
    final stack = info.stack;
    if (stack != null && stack.isNotEmpty) data['rs_stack'] = cutText(stack, stackChars);
  }
  if (sources.contains(info.source) && info.source != 'manual') data['rs_source'] = info.source;
  final type = info.errorType;
  if (type != null && type.isNotEmpty) data['rs_error_type'] = cutText(type, typeChars);
  return data;
}

/// True for the SDK's own automatic captures (not a game's trackError).
bool isAutomaticError(Map<String, Object?> data) {
  final source = data['rs_source'];
  return data['rs_kind'] == 'error' && source is String && source != 'manual';
}

/// The message with quoted text, hex and numbers replaced, for the dedupe key.
String errorTemplate(String message) => message
    .replaceAll(RegExp(r'"[^"]*"'), '"?"')
    .replaceAll(RegExp(r"'[^']*'"), "'?'")
    .replaceAll(RegExp(r'0x[0-9a-fA-F]+'), '#')
    .replaceAll(RegExp(r'[0-9a-fA-F]{8,}'), '#')
    .replaceAll(RegExp(r'\d+'), '#');

String _firstFrame(String? stack) {
  if (stack == null) return '';
  for (final line in stack.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return '';
}

/// The per-session caps and the token bucket.
class ErrorLimiter {
  ErrorLimiter(this._nowSeconds) {
    resetSession();
  }
  final double Function() _nowSeconds;
  int _captures = 0;
  final Map<String, int> _perKey = {};
  double _tokens = bucketSize.toDouble();
  double _refilledAt = 0;

  void resetSession() {
    _captures = 0;
    _perKey.clear();
    _tokens = bucketSize.toDouble();
    _refilledAt = _nowSeconds();
  }

  /// True when this capture may be kept. Cheap checks first.
  bool allow(ErrorInfo info) {
    if (_captures >= sessionCap) return false;
    final t = _nowSeconds();
    final elapsed = t - _refilledAt;
    if (elapsed > 0) {
      _tokens = (_tokens + elapsed * bucketSize / bucketSeconds).clamp(0, bucketSize).toDouble();
      _refilledAt = t;
    }
    if (_tokens < 1) return false;
    final key = '${info.errorType ?? ''}|${errorTemplate(info.message)}|${_firstFrame(info.stack)}';
    final seen = _perKey[key] ?? 0;
    if (seen >= perKeyCap) return false;
    _perKey[key] = seen + 1;
    _tokens -= 1;
    _captures += 1;
    return true;
  }
}
