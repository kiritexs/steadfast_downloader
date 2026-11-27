/// The streaming downloader against a real local server that serves byte
/// ranges: a download in progress lives in `<name>.part` and takes the file's
/// name only when complete, and a partial is always gone on from, never thrown
/// away.
///
/// No Flutter test binding: it would answer every real request with a 400.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:steadfast_downloader/src/engine/retry_policy.dart' show backoff;
import 'package:steadfast_downloader/steadfast_downloader.dart';

void main() {
  // An MP4 header (`ftyp` at byte 4), so the partial reads as a video.
  final payload = [
    0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, //
    for (var i = 0; i < 200000; i++) i % 251,
  ];
  late HttpServer server;
  late Directory dir;
  late String target;
  final ranges = <String?>[];
  final encodings = <String?>[];
  final cookies = <String?>[];
  Completer<void>? gate;
  // How the server misbehaves: 'page' answers a web page, 'sniffPage' a page
  // that doesn't say it is one, 'wrongStartOnce' its first 206 from byte 0,
  // 'stallOnce' and 'dropOnce' send half the file then hang or cut the
  // connection, 'busyOnce' answers 503 first.
  var mode = 'normal';
  // `/once` sends half the file and cuts the connection, then answers 403:
  // a fresh link that expires again later in the run.
  var onceServed = false;
  // `/short` first sends half the file with no length and closes cleanly,
  // so the body ends as if whole; after that it serves as usual.
  var shortServed = false;
  final hung = <Completer<void>>[];

  setUp(() async {
    ranges.clear();
    encodings.clear();
    cookies.clear();
    gate = null;
    mode = 'normal';
    onceServed = false;
    shortServed = false;
    dir = await Directory.systemTemp.createTemp('steadfast-stream-');
    target = p.join(dir.path, 'Episode_1_720p.mp4');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final range = request.headers.value('range');
      ranges.add(range);
      encodings.add(request.headers.value('accept-encoding'));
      cookies.add(request.headers.value('cookie'));
      var start = range == null
          ? 0
          : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      final response = request.response;
      // A link that has expired, and one that answers with a page.
      if (request.uri.path == '/down' || mode == 'busyOnce') {
        if (mode == 'busyOnce') mode = 'normal';
        response.statusCode = HttpStatus.serviceUnavailable;
        response.headers.set('retry-after', '0');
        await response.close();
        return;
      }
      if (request.uri.path == '/short' && !shortServed) {
        shortServed = true;
        final socket = await response.detachSocket(writeHeaders: false);
        socket.write(
          'HTTP/1.1 206 Partial Content\r\n'
          'content-type: video/mp4\r\n'
          'content-range: bytes $start-${payload.length - 1}/${payload.length}'
          '\r\nconnection: close\r\n\r\n',
        );
        socket.add(
          payload.sublist(start, start + (payload.length - start) ~/ 2),
        );
        await socket.flush();
        await socket.close();
        return;
      }
      if (request.uri.path == '/once') {
        if (onceServed) {
          response.statusCode = HttpStatus.forbidden;
          await response.close();
          return;
        }
        onceServed = true;
        mode = 'dropOnce';
      }
      // Headers that never come: a server that accepted the connection
      // and went quiet.
      if (request.uri.path == '/noHeaders') {
        final hang = Completer<void>();
        hung.add(hang);
        await hang.future;
        return;
      }
      // A 200 with no body at all.
      if (request.uri.path == '/empty') {
        response.contentLength = 0;
        await response.close();
        return;
      }
      // A server that asks to be left alone for an hour.
      if (request.uri.path == '/busyLong') {
        response.statusCode = HttpStatus.serviceUnavailable;
        response.headers.set('retry-after', '3600');
        await response.close();
        return;
      }
      if (request.uri.path == '/expired') {
        response.statusCode = HttpStatus.forbidden;
        await response.close();
        return;
      }
      if (mode == 'page' ||
          mode == 'sniffPage' ||
          request.uri.path == '/page') {
        response.headers.contentType = mode == 'page'
            ? ContentType.html
            : ContentType.binary;
        response.write('<!DOCTYPE html><html><body>captcha</body></html>');
        await response.close();
        return;
      }
      if (start >= payload.length) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set('content-range', 'bytes */${payload.length}');
        await response.close();
        return;
      }
      if (range != null && mode == 'wrongStartOnce') {
        mode = 'normal';
        start = 0;
      }
      if (range != null) {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          'content-range',
          'bytes $start-${payload.length - 1}/${payload.length}',
        );
      }
      final body = payload.sublist(start);
      response.contentLength = body.length;
      if (mode == 'dropOnce') {
        // Headers that promise the whole body, half of it, then the
        // connection cut: what a dropped network looks like.
        mode = 'normal';
        final socket = await response.detachSocket(writeHeaders: false);
        socket.write(
          'HTTP/1.1 200 OK\r\n'
          'content-type: video/mp4\r\n'
          'content-length: ${body.length}\r\n\r\n',
        );
        socket.add(body.sublist(0, body.length ~/ 2));
        await socket.flush();
        socket.destroy();
        return;
      }
      if (mode == 'stallOnce') {
        mode = 'normal';
        response.add(body.sublist(0, body.length ~/ 2));
        await response.flush();
        final hang = Completer<void>();
        hung.add(hang);
        await hang.future;
        return;
      }
      final held = gate;
      if (held == null) {
        response.add(body);
      } else {
        response.add(body.sublist(0, body.length ~/ 2));
        await response.flush();
        await held.future;
        response.add(body.sublist(body.length ~/ 2));
      }
      await response.close();
    });
  });

  tearDown(() async {
    for (final h in hung) {
      if (!h.isCompleted) h.complete();
    }
    hung.clear();
    await server.close(force: true);
    await dir.delete(recursive: true);
  });

  String link(String path) =>
      'http://${server.address.host}:${server.port}$path';

  Future<DownloadResult> download({
    StreamingDownloader? using,
    String path = '/ep1.mp4',
    Map<String, String> headers = const {},
    Future<FreshLink?> Function()? freshLink,
  }) => (using ?? StreamingDownloader()).run(
    taskId: 'a_1_720p',
    url: link(path),
    absFilePath: target,
    headers: headers,
    onProgress: (_, _) {},
    freshLink: freshLink,
  );

  File part() => File(partialPathFor(target));

  /// The offset the record beside the .part has committed; 0 with none.
  Future<int> committed() async =>
      (await DownloadRecord.read(
        File(recordPathFor(target)),
      ))?.committedOffset ??
      0;

  test(
    'a download in progress is a .part, the episode only when complete',
    () async {
      gate = Completer<void>();
      final running = download();
      // Half the file has come; it may still be in memory (written in
      // blocks), but the file on disk is the .part.
      while (!part().existsSync()) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(File(target).existsSync(), isFalse);

      gate!.complete();
      final result = await running;

      expect(result.outcome, DownloadOutcome.completed);
      expect(File(target).readAsBytesSync(), payload);
      expect(part().existsSync(), isFalse);
    },
  );

  test('a .part is gone on from with a range request', () async {
    part().writeAsBytesSync(payload.sublist(0, 70000));

    final result = await download();

    expect(ranges, ['bytes=70000-']);
    expect(result.outcome, DownloadOutcome.completed);
    expect(File(target).readAsBytesSync(), payload);
    expect(part().existsSync(), isFalse);
  });

  test('with adoptExistingFile, a partial an older downloader left under the '
      'episode name is gone on from too', () async {
    File(target).writeAsBytesSync(payload.sublist(0, 70000));

    final result = await download(
      using: StreamingDownloader(adoptExistingFile: true),
    );

    expect(ranges, ['bytes=70000-']);
    expect(result.outcome, DownloadOutcome.completed);
    expect(File(target).readAsBytesSync(), payload);
    expect(part().existsSync(), isFalse);
  });

  test('by default, a file already at the final path is left alone and '
      'replaced once the download completes', () async {
    File(target).writeAsBytesSync(List.filled(70000, 0x41));

    gate = Completer<void>();
    final running = download();
    while (!part().existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(File(target).lengthSync(), 70000);
    gate!.complete();
    final result = await running;

    expect(ranges, [null]);
    expect(result.outcome, DownloadOutcome.completed);
    expect(File(target).readAsBytesSync(), payload);
  });

  test('each attempt uses a client from clientFactory', () async {
    var made = 0;

    final result = await download(
      using: StreamingDownloader(
        clientFactory: () {
          made++;
          return http.Client();
        },
      ),
    );

    expect(result.outcome, DownloadOutcome.completed);
    expect(made, 1);
  });

  test('a partial turned down by the check is started again', () async {
    part().writeAsBytesSync(List.filled(70000, 0x3C)); // '<<<<' (a page)

    final result = await download(
      using: StreamingDownloader(partialIsValid: (_) async => false),
    );

    expect(ranges, [null]);
    expect(result.outcome, DownloadOutcome.completed);
    expect(File(target).readAsBytesSync(), payload);
  });

  test('a complete .part is put in place', () async {
    part().writeAsBytesSync(payload);

    final result = await download();

    expect(result.outcome, DownloadOutcome.completed);
    expect(File(target).readAsBytesSync(), payload);
    expect(part().existsSync(), isFalse);
  });

  group('the answers it checks', () {
    test('it never asks for a compressed body', () async {
      await download();
      expect(encodings, ['identity']);
    });

    for (final (name, how) in [
      ('a page served in place of the file', 'page'),
      ('a page that does not say it is one', 'sniffPage'),
    ]) {
      test('$name leaves the .part as it was', () async {
        mode = how;
        part().writeAsBytesSync(payload.sublist(0, 70000));

        final result = await download();

        expect(result.outcome, DownloadOutcome.needsFreshLink);
        expect(part().readAsBytesSync(), payload.sublist(0, 70000));
        expect(File(target).existsSync(), isFalse);
      });
    }

    test('a 206 from another offset is asked for again from zero', () async {
      mode = 'wrongStartOnce';
      part().writeAsBytesSync(payload.sublist(0, 70000));

      final result = await download();

      expect(ranges, ['bytes=70000-', null]);
      expect(result.outcome, DownloadOutcome.completed);
      expect(File(target).readAsBytesSync(), payload);
    });
  });

  group('a fresh link', () {
    test('replaces an expired one, and the .part is gone on from', () async {
      part().writeAsBytesSync(payload.sublist(0, 70000));
      var asked = 0;

      final result = await download(
        path: '/expired',
        freshLink: () async {
          asked++;
          return FreshLink(link('/ep1.mp4'));
        },
      );

      expect(asked, 1);
      expect(ranges, ['bytes=70000-', 'bytes=70000-']);
      expect(result.outcome, DownloadOutcome.completed);
      expect(File(target).readAsBytesSync(), payload);
    });

    test('brings the headers it needs, or keeps the run\'s', () async {
      final result = await download(
        path: '/expired',
        headers: const {'cookie': 'old'},
        freshLink: () async =>
            FreshLink(link('/ep1.mp4'), headers: const {'cookie': 'new'}),
      );
      expect(result.outcome, DownloadOutcome.completed);
      expect(cookies, ['old', 'new']);

      File(target).deleteSync();
      cookies.clear();
      final kept = await download(
        path: '/expired',
        headers: const {'cookie': 'old'},
        freshLink: () async => FreshLink(link('/ep1.mp4')),
      );
      expect(kept.outcome, DownloadOutcome.completed);
      expect(cookies, ['old', 'old']);
    });

    test('that is refused too is a failure, the .part kept', () async {
      part().writeAsBytesSync(payload.sublist(0, 70000));

      final result = await download(
        path: '/expired',
        freshLink: () async => FreshLink(link('/expired')),
      );

      expect(result.outcome, DownloadOutcome.failed);
      expect(part().readAsBytesSync(), payload.sublist(0, 70000));
    });

    test('is asked for twice at most, then the app is', () async {
      part().writeAsBytesSync(payload.sublist(0, 70000));
      var asked = 0;

      final result = await download(
        path: '/page',
        freshLink: () async {
          asked++;
          return FreshLink(link('/page'));
        },
      );

      expect(asked, 2);
      expect(result.outcome, DownloadOutcome.needsFreshLink);
      expect(part().readAsBytesSync(), payload.sublist(0, 70000));
    });

    // After one renewal every later 403 read as the fresh link refused,
    // though a run allows two.
    test(
      'a link that expires again later in the run is renewed again',
      () async {
        final links = ['/once', '/ep1.mp4'];
        var asked = 0;

        final result = await download(
          path: '/expired',
          using: StreamingDownloader(
            stallTimeout: const Duration(milliseconds: 300),
            retryBase: const Duration(milliseconds: 1),
            retryCap: const Duration(milliseconds: 10),
            quietAttempts: 3,
          ),
          freshLink: () async => FreshLink(link(links[asked++])),
        );

        expect(asked, 2);
        expect(result.outcome, DownloadOutcome.completed);
        expect(File(target).readAsBytesSync(), payload);
      },
    );

    // A lookup that failed on the way read as "no fresh link", and the
    // caller took it for a refusal.
    test(
      'a renewal whose lookup fails on the way is tried again, not given up',
      () async {
        var asked = 0;
        final result = await download(
          path: '/expired',
          using: StreamingDownloader(
            stallTimeout: const Duration(milliseconds: 300),
            retryBase: const Duration(milliseconds: 1),
            retryCap: const Duration(milliseconds: 10),
            quietAttempts: 5,
          ),
          freshLink: () async {
            if (asked++ < 2) throw const ServerBusy('the link lookup failed');
            return FreshLink(link('/ep1.mp4'));
          },
        );

        expect(asked, 3);
        expect(result.outcome, DownloadOutcome.completed);
      },
    );

    test('that cannot be had leaves it to the app', () async {
      part().writeAsBytesSync(payload.sublist(0, 70000));

      final none = await download(
        path: '/expired',
        freshLink: () async => null,
      );
      final noHook = await download(path: '/expired');

      expect(none.outcome, DownloadOutcome.needsFreshLink);
      expect(noHook.outcome, DownloadOutcome.needsFreshLink);
      expect(part().readAsBytesSync(), payload.sublist(0, 70000));
    });
  });

  group('a connection that fails', () {
    // Quick to give up, so the tests don't wait.
    StreamingDownloader quick() => StreamingDownloader(
      stallTimeout: const Duration(milliseconds: 300),
      retryBase: const Duration(milliseconds: 1),
      retryCap: const Duration(milliseconds: 10),
      quietAttempts: 3,
    );

    // A body with no length ends cleanly wherever it is cut, and the half
    // that came was taken as the file.
    test('a body that ends short of the size it said is gone on from, not '
        'taken as whole', () async {
      final result = await download(path: '/short', using: quick());

      expect(result.outcome, DownloadOutcome.completed);
      expect(File(target).readAsBytesSync(), payload);
    });

    for (final (name, how) in [
      ('that stalls is dropped', 'stallOnce'),
      ('that is cut', 'dropOnce'),
    ]) {
      test('$name and gone on from where it stopped', () async {
        mode = how;

        final result = await download(using: quick());

        expect(result.outcome, DownloadOutcome.completed);
        expect(ranges.first, isNull);
        expect(ranges.last, startsWith('bytes='));
        expect(File(target).readAsBytesSync(), payload);
      });
    }

    test('to a busy server is tried again', () async {
      mode = 'busyOnce';

      final result = await download(using: quick());

      expect(result.outcome, DownloadOutcome.completed);
      expect(File(target).readAsBytesSync(), payload);
    });

    test('that never gets through is interrupted, the .part kept', () async {
      part().writeAsBytesSync(payload.sublist(0, 70000));

      final down = await download(using: quick(), path: '/down');

      expect(down.outcome, DownloadOutcome.interrupted);
      expect(ranges, hasLength(4));
      expect(part().readAsBytesSync(), payload.sublist(0, 70000));
    });

    test(
      'to a host that cannot be reached is interrupted, not failed',
      () async {
        final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = closed.port;
        await closed.close();

        final result = await quick().run(
          taskId: 'a_1_720p',
          url: 'http://127.0.0.1:$port/ep1.mp4',
          absFilePath: target,
          headers: const {},
          onProgress: (_, _) {},
        );

        expect(result.outcome, DownloadOutcome.interrupted);
      },
    );
  });

  // A cancel is answered at once whatever the
  // run waits for, and the app hears each wait.
  group('cancels and waits', () {
    StreamingDownloader quick() => StreamingDownloader(
      stallTimeout: const Duration(milliseconds: 300),
      retryBase: const Duration(milliseconds: 1),
      retryCap: const Duration(milliseconds: 10),
      quietAttempts: 2,
    );

    test(
      'an empty body is never a file, and leaves the .part as it was',
      () async {
        part().writeAsBytesSync(payload.sublist(0, 70000));

        final result = await download(using: quick(), path: '/empty');

        expect(result.outcome, DownloadOutcome.interrupted);
        expect(File(target).existsSync(), isFalse);
        expect(part().readAsBytesSync(), payload.sublist(0, 70000));
      },
    );

    test('a cancel while the server has sent no headers ends the run at '
        'once, not after the stall timeout', () async {
      part().writeAsBytesSync(payload.sublist(0, 70000));
      final downloader = StreamingDownloader();
      final running = download(using: downloader, path: '/noHeaders');
      while (ranges.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      final watch = Stopwatch()..start();
      await downloader.cancel('a_1_720p');
      final result = await running;

      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(result.outcome, DownloadOutcome.cancelled);
      expect(result.bytesOnDisk, 70000);
      expect(part().readAsBytesSync(), payload.sublist(0, 70000));
    });

    test('two runs of a task that is already running: the last one alone '
        'goes on, never two on one .part', () async {
      gate = Completer<void>();
      final downloader = StreamingDownloader();
      final first = download(using: downloader);
      while (!part().existsSync()) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final second = download(using: downloader);
      final third = download(using: downloader);
      gate!.complete();

      expect((await first).outcome, DownloadOutcome.cancelled);
      expect((await second).outcome, DownloadOutcome.cancelled);
      expect((await third).outcome, DownloadOutcome.completed);
      expect(File(target).readAsBytesSync(), payload);
      expect(downloader.isActive('a_1_720p'), isFalse);
    });

    test('a run stopped before its first request reports the .part it '
        'found', () async {
      part().writeAsBytesSync(payload.sublist(0, 70000));
      late StreamingDownloader downloader;
      downloader = StreamingDownloader(
        partialIsValid: (_) async {
          unawaited(downloader.cancel('a_1_720p'));
          return true;
        },
      );

      final result = await download(using: downloader);

      expect(result.outcome, DownloadOutcome.cancelled);
      expect(result.bytesOnDisk, 70000);
    });

    test("the app's progress callback throwing is not the download's "
        'failure', () async {
      final result = await StreamingDownloader().run(
        taskId: 'a_1_720p',
        url: link('/ep1.mp4'),
        absFilePath: target,
        headers: const {},
        onProgress: (_, _) => throw StateError('a closed screen'),
      );

      expect(result.outcome, DownloadOutcome.completed);
      expect(File(target).readAsBytesSync(), payload);
    });
  });

  group('a run that waits', () {
    test('for a fresh link that never comes is cancelled at once', () async {
      part().writeAsBytesSync(payload.sublist(0, 70000));
      final downloader = StreamingDownloader();
      final asked = Completer<void>();
      final running = download(
        using: downloader,
        path: '/expired',
        freshLink: () {
          asked.complete();
          return Completer<FreshLink?>().future;
        },
      );
      await asked.future;

      final watch = Stopwatch()..start();
      await downloader.cancel('a_1_720p');
      final result = await running;

      expect(watch.elapsed, lessThan(const Duration(milliseconds: 200)));
      expect(result.outcome, DownloadOutcome.cancelled);
      expect(downloader.isActive('a_1_720p'), isFalse);
      expect(part().readAsBytesSync(), payload.sublist(0, 70000));
    });

    test('for a fresh link that fails after the cancel ends cancelled, not '
        'as a link to renew', () async {
      final downloader = StreamingDownloader();
      final lookup = Completer<FreshLink?>();
      final asked = Completer<void>();
      final running = download(
        using: downloader,
        path: '/expired',
        freshLink: () {
          asked.complete();
          return lookup.future;
        },
      );
      await asked.future;

      await downloader.cancel('a_1_720p');
      lookup.completeError(const ServerBusy('late'));

      expect((await running).outcome, DownloadOutcome.cancelled);
    });

    test("out a busy server's Retry-After: capped, told to the app, and a "
        'cancel ends it at once', () async {
      final downloader = StreamingDownloader();
      final waits = <(Duration, Object)>[];
      final running = downloader.run(
        taskId: 'a_1_720p',
        url: link('/busyLong'),
        absFilePath: target,
        headers: const {},
        onProgress: (_, _) {},
        onWaiting: (wait, error) => waits.add((wait, error)),
      );
      while (waits.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final watch = Stopwatch()..start();
      await downloader.cancel('a_1_720p');
      final result = await running;

      expect(waits.single.$1, const Duration(minutes: 10));
      expect(waits.single.$2, isA<ServerBusy>());
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 200)));
      expect(result.outcome, DownloadOutcome.cancelled);
    });

    test('out a failed connection: the jittered back-off, told to the '
        'app', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      const base = Duration(milliseconds: 20);
      const cap = Duration(milliseconds: 40);
      final waits = <(Duration, Object)>[];

      final result =
          await StreamingDownloader(
            retryBase: base,
            retryCap: cap,
            quietAttempts: 2,
            random: Random(7),
          ).run(
            taskId: 'a_1_720p',
            url: 'http://127.0.0.1:$port/ep1.mp4',
            absFilePath: target,
            headers: const {},
            onProgress: (_, _) {},
            onWaiting: (wait, error) => waits.add((wait, error)),
          );

      final expected = Random(7);
      expect(result.outcome, DownloadOutcome.interrupted);
      expect(waits.map((w) => w.$1), [
        backoff(1, base: base, cap: cap, random: expected),
        backoff(2, base: base, cap: cap, random: expected),
      ]);
      expect(waits.first.$2, isA<SocketException>());
    });
  });

  test('a full disk stops the run with the .part kept, and it goes on once '
      'there is room', () async {
    // Some of the first half is committed before the disk fills, however
    // its bytes arrive: one chunk can be bigger than the room.
    gate = Completer<void>();
    final running = IOOverrides.runWithIOOverrides(
      () => download(using: StreamingDownloader(commitEveryBytes: 16 * 1024)),
      _FullDisk(partialPathFor(target), room: 150000),
    );
    while (await committed() == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    gate!.complete();
    final full = await running;

    expect(full.outcome, DownloadOutcome.diskFull);
    expect(part().existsSync(), isTrue);
    final record = await DownloadRecord.read(File(recordPathFor(target)));
    expect(record!.committedOffset, greaterThan(0));
    expect(record.committedOffset, lessThanOrEqualTo(part().lengthSync()));

    final roomAgain = await download();

    expect(ranges.last, 'bytes=${record.committedOffset}-');
    expect(roomAgain.outcome, DownloadOutcome.completed);
    expect(File(target).readAsBytesSync(), payload);
  });

  group('the record beside the .part', () {
    File record() => File(recordPathFor(target));

    test('the committed offset is where it goes on from; a torn tail is '
        'cut', () async {
      // 70000 bytes committed, then 30000 written but never committed: the
      // tail a crash between a write and its commit leaves.
      part().writeAsBytesSync([
        ...payload.sublist(0, 70000),
        ...List.filled(30000, 0xEE),
      ]);
      await const DownloadRecord(
        url: 'x',
        committedOffset: 70000,
      ).write(record());

      final result = await download();

      expect(ranges, ['bytes=70000-']);
      expect(result.outcome, DownloadOutcome.completed);
      expect(File(target).readAsBytesSync(), payload);
    });

    test('the offset is committed as it goes and when it stops', () async {
      gate = Completer<void>();
      final downloader = StreamingDownloader(commitEveryBytes: 16 * 1024);
      final running = download(using: downloader);
      DownloadRecord? midway;
      while (midway == null || midway.committedOffset == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        midway = await DownloadRecord.read(record());
      }
      expect(midway.committedOffset, greaterThan(0));

      await downloader.cancel('a_1_720p');
      final result = await running;
      gate!.complete();

      expect(result.outcome, DownloadOutcome.cancelled);
      final stopped = await DownloadRecord.read(record());
      expect(stopped!.committedOffset, part().lengthSync());
      expect(stopped.url, contains('/ep1.mp4'));
    });

    test('stopping them all waits until each has committed', () async {
      gate = Completer<void>();
      final downloader = StreamingDownloader(commitEveryBytes: 16 * 1024);
      final running = download(using: downloader);
      while (await committed() == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      await downloader.cancelAll();

      expect(downloader.isActive('a_1_720p'), isFalse);
      expect(await committed(), part().lengthSync());
      gate!.complete();
      expect((await running).outcome, DownloadOutcome.cancelled);
    });

    test('a finished download leaves neither .part nor record', () async {
      final result = await download();

      expect(result.outcome, DownloadOutcome.completed);
      expect(part().existsSync(), isFalse);
      expect(record().existsSync(), isFalse);
      expect(workingPathsFor(target), [
        target,
        part().path,
        record().path,
        '${record().path}.tmp',
      ]);
    });
  });

  // Windows only: elsewhere a file another program holds can still be
  // renamed.
  test('a .part that cannot take its name stays, for the next try', () async {
    part().writeAsBytesSync(payload);
    // Another program has it open: an antivirus scan, the search indexer.
    final held = part().openSync();
    final DownloadResult result;
    try {
      result = await download();
    } finally {
      held.closeSync();
    }

    expect(result.outcome, DownloadOutcome.failed);
    expect(File(target).existsSync(), isFalse);
    expect(part().readAsBytesSync(), payload);
  }, skip: !Platform.isWindows);
}

/// The disk under the file at [path] fills up after [room] bytes.
final class _FullDisk extends IOOverrides {
  _FullDisk(this.path, {required this.room});

  final String path;
  final int room;

  @override
  File createFile(String p) {
    final real = super.createFile(p);
    return p == path ? _FullDiskFile(real, room) : real;
  }
}

class _FullDiskFile implements File {
  _FullDiskFile(this._real, this._room);

  final File _real;
  final int _room;

  @override
  String get path => _real.path;

  @override
  Directory get parent => _real.parent;

  @override
  Future<bool> exists() => _real.exists();

  @override
  Future<int> length() => _real.length();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      _real.delete(recursive: recursive);

  @override
  Future<File> rename(String newPath) => _real.rename(newPath);

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      _FullDiskWrites(await _real.open(mode: mode), _room);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FullDiskWrites implements RandomAccessFile {
  _FullDiskWrites(this._real, this._room);

  final RandomAccessFile _real;
  int _room;

  @override
  String get path => _real.path;

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async {
    final count = (end ?? buffer.length) - start;
    if (count > _room) {
      throw FileSystemException(
        'There is not enough space on the disk',
        path,
        OSError('disk full', Platform.isWindows ? 112 : 28),
      );
    }
    _room -= count;
    await _real.writeFrom(buffer, start, end);
    return this;
  }

  @override
  Future<RandomAccessFile> flush() async {
    await _real.flush();
    return this;
  }

  @override
  Future<RandomAccessFile> truncate(int length) async {
    await _real.truncate(length);
    return this;
  }

  @override
  Future<void> close() => _real.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
