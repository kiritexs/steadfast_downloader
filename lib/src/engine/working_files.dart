/// Where a download in progress lives until it is complete: never under the
/// file's own name, so a half-downloaded file can't pass for a finished one.
String partialPathFor(String absFilePath) => '$absFilePath.part';

/// The [DownloadRecord] kept beside a download's `.part`.
String recordPathFor(String absFilePath) => '$absFilePath.part.json';

/// Every file a download may leave at [absFilePath]: the finished file, its
/// `.part`, its record, and the record's `.tmp` when a write of it stopped
/// half way (`DownloadRecord.write`). Removing a download removes them all.
List<String> workingPathsFor(String absFilePath) => [
  absFilePath,
  partialPathFor(absFilePath),
  recordPathFor(absFilePath),
  '${recordPathFor(absFilePath)}.tmp',
];
