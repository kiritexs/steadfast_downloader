import 'download_notifier.dart';
import 'keep_alive.dart';

/// The plugin on Linux and macOS, where it has no native code: Flutter calls
/// [registerWith] at startup, which points [KeepAlive.instance] and
/// [DownloadNotifier.instance] at their no-op versions. The engine itself is
/// pure Dart and needs nothing here.
abstract final class SteadfastDownloaderDartPlugin {
  /// Called by Flutter's plugin registrant; apps don't call it.
  static void registerWith() {
    KeepAlive.instance = const UnsupportedKeepAlive();
    DownloadNotifier.instance = const UnsupportedDownloadNotifier();
  }
}
