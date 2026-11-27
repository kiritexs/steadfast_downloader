import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

/// Whether [error] is worth trying again: the connection failed (DNS, a
/// socket, TLS, a timeout, a body cut short, a stall), not the answer. A file
/// system error is not.
bool isTransient(Object error) =>
    error is SocketException ||
    error is TlsException ||
    error is TimeoutException ||
    error is HttpException ||
    error is http.ClientException ||
    error is ServerBusy;

/// Whether [error] is the disk being full: never tried again, the `.part`
/// kept. Windows says 112 or 39; Android, iOS, Linux and macOS say ENOSPC,
/// 28 (39 is ENOTEMPTY on Linux).
bool isDiskFull(Object error, {bool? windows}) {
  if (error is! FileSystemException) return false;
  final code = error.osError?.errorCode;
  return (windows ?? Platform.isWindows)
      ? code == 112 || code == 39
      : code == 28;
}

/// A busy or failing server (408, 429, 5xx): tried again, not before [after]
/// when it said so.
class ServerBusy implements Exception {
  const ServerBusy(this.reason, {this.after});

  final String reason;
  final Duration? after;

  @override
  String toString() => 'ServerBusy($reason)';
}

/// How long to wait before attempt [attempt] (1-based) of a stretch with no
/// bytes: "full jitter", anywhere from 0 to [base] doubled per attempt, never
/// over [cap], so many clients failing together don't come back together.
Duration backoff(
  int attempt, {
  required Duration base,
  required Duration cap,
  required Random random,
}) {
  final doubled = base.inMicroseconds * pow(2, max(0, attempt - 1));
  final ceiling = min(cap.inMicroseconds.toDouble(), doubled.toDouble());
  return Duration(microseconds: (random.nextDouble() * ceiling).round());
}
