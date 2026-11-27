/// Linux and macOS: the plugin's Dart-only side, whose keep-alive and
/// notifier do nothing, and the platform defaults it sets.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:steadfast_downloader/steadfast_downloader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const notice = KeepAliveNotice(
    title: 'Downloading',
    channelName: 'Downloads',
  );
  const finished = FinishNotice(title: 'Done', channelName: 'Finished');

  test('the defaults are the channel ones until a platform sets others', () {
    expect(KeepAlive.instance, isA<MethodChannelKeepAlive>());
    expect(KeepAlive.instance, same(KeepAlive.instance));
    expect(DownloadNotifier.instance, isA<MethodChannelDownloadNotifier>());
    expect(DownloadNotifier.instance, same(DownloadNotifier.instance));
  });

  test('registerWith points both at their no-op versions', () {
    SteadfastDownloaderDartPlugin.registerWith();
    expect(KeepAlive.instance, isA<UnsupportedKeepAlive>());
    expect(DownloadNotifier.instance, isA<UnsupportedDownloadNotifier>());
  });

  test('the no-op keep-alive holds nothing and says so', () async {
    const keepAlive = UnsupportedKeepAlive();
    expect(await keepAlive.hold(notice), KeepAliveHold.unsupported);
    await keepAlive.update(notice);
    await keepAlive.release();
    await expectLater(keepAlive.events, emitsDone);
  });

  test('the no-op notifier shows nothing and has no taps', () async {
    const notifier = UnsupportedDownloadNotifier();
    expect(await notifier.permission(), isFalse);
    expect(await notifier.permission(ask: false), isFalse);
    await notifier.show('file-1', finished);
    expect(await notifier.launchTap(), isNull);
    await expectLater(notifier.taps, emitsDone);
  });
}
