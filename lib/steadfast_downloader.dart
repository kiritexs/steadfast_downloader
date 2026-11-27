/// Downloads that are never lost or restarted from nothing: a file streams
/// into `<name>.part` and takes its name only when complete.
library;

export 'src/engine/download_record.dart';
export 'src/engine/retry_policy.dart' show ServerBusy, isDiskFull;
export 'src/engine/streaming_downloader.dart';
export 'src/engine/working_files.dart';
export 'src/platform/dart_plugin.dart';
export 'src/platform/download_notifier.dart';
export 'src/platform/keep_alive.dart';
