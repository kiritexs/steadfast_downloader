/// How the engine judges a server's answer, after RFC 9110 and how Chrome,
/// Firefox and yt-dlp resume.
library;

import 'package:steadfast_downloader/src/engine/download_record.dart';
import 'package:steadfast_downloader/src/engine/response_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const record = DownloadRecord(
    url: 'https://cdn.example/ep1.mp4',
    committedOffset: 1000,
    expectedSize: 5000,
    etag: '"abc"',
    etagHost: 'cdn.example',
    lastModified: 'Wed, 01 Oct 2026 10:00:00 GMT',
    contentType: 'video/mp4',
  );

  Verdict judge(
    int status, {
    Map<String, String> headers = const {},
    int offset = 1000,
    DownloadRecord? known = record,
    bool afterFreshLink = false,
  }) => judgeResponse(
    offset: offset,
    status: status,
    headers: headers,
    record: known,
    afterFreshLink: afterFreshLink,
  );

  group('a request', () {
    test('never takes a compressed body, whose offsets would be wrong', () {
      expect(requestHeaders(offset: 0, host: 'cdn.example', record: null), {
        'accept-encoding': 'identity',
      });
    });

    test('goes on with Range, and If-Range only with a strong validator '
        'from the same host', () {
      expect(
        requestHeaders(offset: 1000, host: 'cdn.example', record: record),
        {
          'accept-encoding': 'identity',
          'range': 'bytes=1000-',
          'if-range': '"abc"',
        },
      );
      expect(
        requestHeaders(offset: 1000, host: 'other.example', record: record),
        {'accept-encoding': 'identity', 'range': 'bytes=1000-'},
      );
      expect(
        requestHeaders(
          offset: 1000,
          host: 'cdn.example',
          record: record.copyWith(etag: 'W/"abc"'),
        ),
        {'accept-encoding': 'identity', 'range': 'bytes=1000-'},
      );
    });
  });

  group('a 206', () {
    test('that starts at the offset is appended', () {
      final verdict = judge(
        206,
        headers: {
          'content-range': 'bytes 1000-4999/5000',
          'content-type': 'video/mp4',
          'last-modified': record.lastModified!,
        },
      );
      expect(verdict, isA<AppendAt>());
      expect((verdict as AppendAt).total, 5000);
    });

    test('that starts elsewhere is asked for again from zero', () {
      expect(
        judge(206, headers: {'content-range': 'bytes 0-4999/5000'}),
        isA<RequestFromZero>(),
      );
    });

    test('of a file whose size or date changed is asked for again from '
        'zero', () {
      expect(
        judge(206, headers: {'content-range': 'bytes 1000-5999/6000'}),
        isA<RequestFromZero>(),
      );
      expect(
        judge(
          206,
          headers: {
            'content-range': 'bytes 1000-4999/5000',
            'last-modified': 'Thu, 02 Oct 2026 10:00:00 GMT',
          },
        ),
        isA<RequestFromZero>(),
      );
    });

    test('that is a web page needs a fresh link', () {
      expect(
        judge(
          206,
          headers: {
            'content-range': 'bytes 1000-4999/5000',
            'content-type': 'text/html; charset=utf-8',
          },
        ),
        isA<FreshLinkNeeded>(),
      );
    });
  });

  group('a 200', () {
    test('with the file is written from the start', () {
      final verdict = judge(
        200,
        headers: {'content-length': '5000', 'content-type': 'video/mp4'},
      );
      expect(verdict, isA<WriteFromStart>());
      expect((verdict as WriteFromStart).total, 5000);
    });

    test('that is a web page needs a fresh link; the .part is kept', () {
      expect(
        judge(200, headers: {'content-type': 'text/html'}),
        isA<FreshLinkNeeded>(),
      );
    });

    test('of another size while going on needs a fresh link; after one, '
        'it is the changed file', () {
      expect(
        judge(200, headers: {'content-length': '1234'}),
        isA<FreshLinkNeeded>(),
      );
      expect(
        judge(
          200,
          headers: {'content-length': '1234', 'content-type': 'video/mp4'},
          afterFreshLink: true,
        ),
        isA<WriteFromStart>(),
      );
      // From the start, any size is the file.
      expect(
        judge(200, headers: {'content-length': '1234'}, offset: 0),
        isA<WriteFromStart>(),
      );
    });

    // Asked for no compression, a host that compresses anyway is most
    // likely sending a page, for a link that has expired.
    test('that is a compressed page asks for a fresh link', () {
      for (final status in [200, 206]) {
        expect(
          judge(
            status,
            headers: {
              'content-encoding': 'gzip',
              'content-type': 'text/html; charset=utf-8',
            },
          ),
          isA<FreshLinkNeeded>(),
          reason: '$status',
        );
      }
    });

    test('that is compressed asks for a fresh link once, then is '
        'refused', () {
      const compressed = {
        'content-encoding': 'gzip',
        'content-type': 'video/mp4',
      };
      expect(
        judge(200, headers: compressed, offset: 0),
        isA<FreshLinkNeeded>(),
      );
      expect(
        judge(200, headers: compressed, offset: 0, afterFreshLink: true),
        isA<Refused>(),
      );
    });
  });

  test('an error is judged by its status, compressed or not', () {
    expect(
      judge(403, headers: {'content-encoding': 'gzip'}),
      isA<FreshLinkNeeded>(),
    );
    expect(judge(503, headers: {'content-encoding': 'br'}), isA<TryAgain>());
  });

  group('a 416', () {
    test('is complete when the size on disk is the whole file', () {
      expect(
        judge(416, headers: {'content-range': 'bytes */5000'}, offset: 5000),
        isA<AlreadyComplete>(),
      );
      expect(judge(416, offset: 5000), isA<AlreadyComplete>());
    });

    test('is asked for again from zero otherwise', () {
      expect(
        judge(416, headers: {'content-range': 'bytes */4000'}, offset: 5000),
        isA<RequestFromZero>(),
      );
      expect(judge(416, known: null), isA<RequestFromZero>());
    });
  });

  group('other answers', () {
    test('an expired or refused link needs a fresh one; after one, it is '
        'refused', () {
      for (final status in [401, 403, 404, 410]) {
        expect(judge(status), isA<FreshLinkNeeded>(), reason: '$status');
        expect(
          judge(status, afterFreshLink: true),
          isA<Refused>(),
          reason: '$status',
        );
      }
    });

    test('a busy or failing server is tried again, after Retry-After', () {
      final verdict = judge(429, headers: {'retry-after': '120'});
      expect(verdict, isA<TryAgain>());
      expect((verdict as TryAgain).after, const Duration(seconds: 120));
      for (final status in [408, 500, 502, 503, 504, 522, 524]) {
        expect(judge(status), isA<TryAgain>(), reason: '$status');
      }
    });

    test('anything else is refused', () {
      expect(judge(400), isA<Refused>());
      expect(judge(204), isA<Refused>());
    });
  });

  group('the record after an answer', () {
    test('keeps the size, a strong ETag with its host, the date and the '
        'type', () {
      final after = recordAfter(
        const DownloadRecord(url: 'u', committedOffset: 0),
        host: 'cdn.example',
        total: 5000,
        headers: {
          'etag': '"v2"',
          'last-modified': 'Fri, 03 Oct 2026 10:00:00 GMT',
          'content-type': 'video/mp4',
        },
      );
      expect(after.expectedSize, 5000);
      expect(after.etag, '"v2"');
      expect(after.etagHost, 'cdn.example');
      expect(after.lastModified, 'Fri, 03 Oct 2026 10:00:00 GMT');
      expect(after.contentType, 'video/mp4');
    });

    test('never keeps a weak ETag', () {
      final after = recordAfter(
        const DownloadRecord(url: 'u', committedOffset: 0),
        host: 'cdn.example',
        headers: {'etag': 'W/"v2"'},
      );
      expect(after.etag, isNull);
    });
  });

  test('a web page is told from a file by its first bytes', () {
    expect(looksLikeHtml('  <!DOCTYPE html><html>'.codeUnits), isTrue);
    expect(looksLikeHtml('<html lang="en">'.codeUnits), isTrue);
    expect(looksLikeHtml([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70]), isFalse);
  });
}
