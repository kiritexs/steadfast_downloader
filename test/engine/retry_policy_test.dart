/// What is tried again and how long it waits.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:steadfast_downloader/src/engine/retry_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test('a failed connection is tried again; a file error is not', () {
    expect(isTransient(const SocketException('Failed host lookup')), isTrue);
    expect(isTransient(TimeoutException('no headers')), isTrue);
    expect(isTransient(http.ClientException('Connection closed')), isTrue);
    expect(isTransient(const HttpException('cut short')), isTrue);
    expect(isTransient(const ServerBusy('503')), isTrue);
    expect(isTransient(const FileSystemException('disk full')), isFalse);
    expect(isTransient(ArgumentError('bug')), isFalse);
  });

  test('a full disk is told by its own error codes on each system', () {
    FileSystemException failing(int code) =>
        FileSystemException('write failed', 'x.part', OSError('', code));
    expect(isDiskFull(failing(112), windows: true), isTrue);
    expect(isDiskFull(failing(39), windows: true), isTrue);
    expect(isDiskFull(failing(28), windows: false), isTrue);
    // 39 is ENOTEMPTY on Linux, 28 something else on Windows.
    expect(isDiskFull(failing(39), windows: false), isFalse);
    expect(isDiskFull(failing(28), windows: true), isFalse);
    expect(isDiskFull(failing(5), windows: true), isFalse);
    expect(isDiskFull(const SocketException('x'), windows: true), isFalse);
  });

  test('the wait is full jitter: up to the base doubled per attempt, '
      'never over the cap', () {
    final random = Random(7);
    const base = Duration(seconds: 1);
    const cap = Duration(minutes: 2);
    for (var attempt = 1; attempt <= 12; attempt++) {
      final ceiling = Duration(
        microseconds: min(
          cap.inMicroseconds,
          base.inMicroseconds * pow(2, attempt - 1).toInt(),
        ),
      );
      for (var i = 0; i < 50; i++) {
        final wait = backoff(attempt, base: base, cap: cap, random: random);
        expect(wait, greaterThanOrEqualTo(Duration.zero));
        expect(wait, lessThanOrEqualTo(ceiling), reason: 'attempt $attempt');
      }
    }
  });
}
