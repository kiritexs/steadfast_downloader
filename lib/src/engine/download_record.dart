import 'dart:convert';
import 'dart:io';

/// What a download knows about its `.part`, kept beside it
/// ([recordPathFor]) so a continuation can be checked and a torn tail cut.
class DownloadRecord {
  const DownloadRecord({
    required this.url,
    required this.committedOffset,
    this.expectedSize,
    this.etag,
    this.etagHost,
    this.lastModified,
    this.contentType,
  });

  /// The link the bytes came from last.
  final String url;

  /// Bytes of the `.part` known to be on disk: flushed, then recorded. Bytes
  /// past it may be torn, and are cut before going on.
  final int committedOffset;

  /// The whole file's size, when the server said it.
  final int? expectedSize;

  /// A strong ETag (never a weak `W/` one) and the host that sent it.
  final String? etag;
  final String? etagHost;

  final String? lastModified;
  final String? contentType;

  DownloadRecord copyWith({
    String? url,
    int? committedOffset,
    int? expectedSize,
    String? etag,
    String? etagHost,
    String? lastModified,
    String? contentType,
  }) => DownloadRecord(
    url: url ?? this.url,
    committedOffset: committedOffset ?? this.committedOffset,
    expectedSize: expectedSize ?? this.expectedSize,
    etag: etag ?? this.etag,
    etagHost: etagHost ?? this.etagHost,
    lastModified: lastModified ?? this.lastModified,
    contentType: contentType ?? this.contentType,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'url': url,
    'committed_offset': committedOffset,
    'expected_size': expectedSize,
    'etag': etag,
    'etag_host': etagHost,
    'last_modified': lastModified,
    'content_type': contentType,
  };

  static DownloadRecord fromJson(Map<String, Object?> json) => DownloadRecord(
    url: json['url'] as String? ?? '',
    committedOffset: (json['committed_offset'] as num?)?.toInt() ?? 0,
    expectedSize: (json['expected_size'] as num?)?.toInt(),
    etag: json['etag'] as String?,
    etagHost: json['etag_host'] as String?,
    lastModified: json['last_modified'] as String?,
    contentType: json['content_type'] as String?,
  );

  /// The record at [file], or null when there is none or it can't be read
  /// (the `.part`'s own length is trusted then).
  static Future<DownloadRecord?> read(File file) async {
    try {
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString());
      return json is Map<String, Object?> ? fromJson(json) : null;
    } catch (_) {
      return null;
    }
  }

  /// Written whole: to `<record>.tmp`, then renamed over the record, so a
  /// crash leaves the old record or the new one. Windows refuses to replace
  /// a file another program has open for a moment (an antivirus scan, the
  /// search indexer), so the rename is tried a few times before it fails.
  Future<void> write(File file) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(toJson()), flush: true);
    for (var attempt = 1; ; attempt++) {
      try {
        await tmp.rename(file.path);
        return;
      } on FileSystemException {
        if (attempt == _renameAttempts) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 50 * attempt));
      }
    }
  }

  /// Up to 300 ms of waiting in all: 50, 100 and 150 ms.
  static const _renameAttempts = 4;
}
