import 'dart:io' show HttpDate;

import 'package:steadfast_downloader/src/engine/download_record.dart';

/// What the engine does with a server's answer, after RFC 9110 and how Chrome,
/// Firefox and yt-dlp resume.
sealed class Verdict {
  const Verdict();
}

/// A 206 going on from the asked offset: its bytes are appended.
final class AppendAt extends Verdict {
  const AppendAt(this.total);

  /// The whole file's size, when the answer gives it.
  final int? total;
}

/// The whole file from its first byte: the `.part` is written from the start.
final class WriteFromStart extends Verdict {
  const WriteFromStart(this.total);

  final int? total;
}

/// Nothing left to send: the `.part` is the whole file.
final class AlreadyComplete extends Verdict {
  const AlreadyComplete();
}

/// The answer can't be gone on from (another start, a changed file): ask
/// again from byte 0.
final class RequestFromZero extends Verdict {
  const RequestFromZero(this.reason);

  final String reason;
}

/// The link has expired, or answers with a page in place of the file: get a
/// fresh link; the `.part` is kept.
final class FreshLinkNeeded extends Verdict {
  const FreshLinkNeeded(this.reason);

  final String reason;
}

/// The server is busy or failing for now: try again, not before [after]
/// when it said so (`Retry-After`).
final class TryAgain extends Verdict {
  const TryAgain(this.reason, {this.after});

  final String reason;
  final Duration? after;
}

/// Nothing can be done with this answer.
final class Refused extends Verdict {
  const Refused(this.reason);

  final String reason;
}

/// The headers of a request for the file from [offset]: never a compressed
/// body (its offsets would be the compressed ones); `If-Range` only with a
/// strong ETag that [host] itself gave (CDN edges give different ones).
Map<String, String> requestHeaders({
  required int offset,
  required String host,
  required DownloadRecord? record,
}) {
  final etag = record?.etag;
  return {
    'accept-encoding': 'identity',
    if (offset > 0) 'range': 'bytes=$offset-',
    if (offset > 0 &&
        etag != null &&
        _isStrong(etag) &&
        record?.etagHost == host)
      'if-range': etag,
  };
}

/// Judges an answer to a request from [offset]. [headers] are lower-case.
/// [afterFreshLink]: the link was just fetched again, so an answer that
/// pointed at an expired link the first time now means what it says.
Verdict judgeResponse({
  required int offset,
  required int status,
  required Map<String, String> headers,
  required DownloadRecord? record,
  bool afterFreshLink = false,
}) {
  final encoding = headers['content-encoding']?.trim().toLowerCase() ?? '';
  final compressed = encoding.isNotEmpty && encoding != 'identity';
  final expected = record?.expectedSize;
  final page = _isPage(headers['content-type']);
  switch (status) {
    case 206:
      if (page) return const FreshLinkNeeded('a page in place of the file');
      if (compressed) return _compressed(encoding, afterFreshLink);
      final range = _contentRange(headers['content-range']);
      if (range == null || range.start != offset) {
        return RequestFromZero('a 206 from ${range?.start}, not $offset');
      }
      final total = range.total;
      if (total != null && expected != null && total != expected) {
        return RequestFromZero('the size went from $expected to $total');
      }
      final was = record?.lastModified;
      final now = headers['last-modified'];
      if (was != null && now != null && was != now) {
        return const RequestFromZero('Last-Modified changed');
      }
      return AppendAt(total);
    case 200:
      if (page) return const FreshLinkNeeded('a page in place of the file');
      if (compressed) return _compressed(encoding, afterFreshLink);
      final length = int.tryParse(headers['content-length'] ?? '');
      if (!afterFreshLink &&
          offset > 0 &&
          expected != null &&
          length != null &&
          length != expected) {
        return FreshLinkNeeded('$length bytes where $expected were expected');
      }
      return WriteFromStart(length);
    case 416:
      final total = _contentRange(headers['content-range'])?.total;
      if (total != null) {
        return total == offset && (expected == null || expected == total)
            ? const AlreadyComplete()
            : RequestFromZero('a 416 with $offset of $total on disk');
      }
      return expected != null && offset == expected
          ? const AlreadyComplete()
          : const RequestFromZero('a 416 with no size');
    case 401 || 403 || 404 || 410:
      return afterFreshLink
          ? Refused('$status after a fresh link')
          : FreshLinkNeeded('$status');
    case 408 || 429 || 500 || 502 || 503 || 504 || 522 || 524:
      return TryAgain('$status', after: _retryAfter(headers['retry-after']));
    default:
      return status >= 500
          ? TryAgain('$status', after: _retryAfter(headers['retry-after']))
          : Refused('$status');
  }
}

/// A compressed body, though none was asked for: its offsets are not the
/// file's, and a host that compresses anyway is most likely sending a page
/// (a host's page for an expired link). A fresh link, then refused.
Verdict _compressed(String encoding, bool afterFreshLink) {
  final reason = 'a $encoding body, whose offsets are not the file\'s';
  return afterFreshLink ? Refused(reason) : FreshLinkNeeded(reason);
}

/// [record] with what an answer says about the file: its size, a strong
/// ETag and the host that gave it, its date and type.
DownloadRecord recordAfter(
  DownloadRecord record, {
  required String host,
  required Map<String, String> headers,
  int? total,
}) {
  final etag = headers['etag'];
  final strong = etag != null && _isStrong(etag);
  return DownloadRecord(
    url: record.url,
    committedOffset: record.committedOffset,
    expectedSize: total ?? record.expectedSize,
    etag: strong ? etag : (etag == null ? record.etag : null),
    etagHost: strong ? host : (etag == null ? record.etagHost : null),
    lastModified: headers['last-modified'] ?? record.lastModified,
    contentType: headers['content-type'] ?? record.contentType,
  );
}

/// Whether the first bytes of a body are a web page, which hosts serve with
/// a 200 in place of the file (a captcha, an error).
bool looksLikeHtml(List<int> head) {
  final text = String.fromCharCodes(
    head.take(1024).where((b) => b >= 0x09 && b < 0x7F),
  ).trimLeft().toLowerCase();
  if (!text.startsWith('<')) return false;
  return text.startsWith('<!doctype html') ||
      text.contains('<html') ||
      text.contains('<head') ||
      text.contains('<body');
}

bool _isStrong(String etag) => !etag.toUpperCase().startsWith('W/');

bool _isPage(String? contentType) {
  final type = contentType?.toLowerCase().trim() ?? '';
  return type.startsWith('text/html') || type.startsWith('application/xhtml');
}

/// `bytes 1000-4999/5000` or `bytes */5000`.
({int? start, int? total})? _contentRange(String? header) {
  if (header == null) return null;
  final match = RegExp(
    r'^\s*bytes\s+(?:(\d+)-\d+|\*)\s*/\s*(\d+|\*)\s*$',
  ).firstMatch(header);
  if (match == null) return null;
  return (
    start: int.tryParse(match.group(1) ?? ''),
    total: int.tryParse(match.group(2) ?? ''),
  );
}

Duration? _retryAfter(String? header) {
  if (header == null) return null;
  final seconds = int.tryParse(header.trim());
  if (seconds != null) return Duration(seconds: seconds);
  try {
    final at = HttpDate.parse(header);
    final wait = at.difference(DateTime.now());
    return wait.isNegative ? Duration.zero : wait;
  } catch (_) {
    return null;
  }
}
