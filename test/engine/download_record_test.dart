/// The record beside a `.part`: what it keeps, and that it is saved even when
/// another program reads it.
library;

import 'dart:io';

import 'package:steadfast_downloader/src/engine/download_record.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('steadfast-record-');
    file = File(p.join(dir.path, 'Episode_1_720p.mp4.part.json'));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('what is written is what is read back', () async {
    const record = DownloadRecord(
      url: 'https://cdn.example/ep1.mp4',
      committedOffset: 70000,
      expectedSize: 200008,
      etag: '"abc"',
      etagHost: 'cdn.example',
    );
    await record.write(file);
    final read = await DownloadRecord.read(file);
    expect(read?.committedOffset, 70000);
    expect(read?.expectedSize, 200008);
    expect(read?.etag, '"abc"');
  });

  // Windows refuses to replace a file another program has open (an
  // antivirus scan, the search indexer): a save then has to wait its turn,
  // or a stop's committed offset would be lost.
  test('a record another program holds for a moment is still saved', () async {
    await const DownloadRecord(url: 'u', committedOffset: 1).write(file);
    final held = file.openSync();
    final saving = const DownloadRecord(
      url: 'u',
      committedOffset: 2,
    ).write(file);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    held.closeSync();

    await saving;

    expect((await DownloadRecord.read(file))?.committedOffset, 2);
  }, skip: !Platform.isWindows);
}
