/// The notifications channel's names and answers, which the native side of
/// Android and iOS implements.
library;

import 'package:steadfast_downloader/src/platform/download_notifier.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel(MethodChannelDownloadNotifier.channelName);
  final calls = <MethodCall>[];

  void answer(Object? Function(MethodCall call)? reply) {
    calls.clear();
    messenger.setMockMethodCallHandler(
      channel,
      reply == null
          ? null
          : (call) async {
              calls.add(call);
              return reply(call);
            },
    );
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('permission says whether to ask, and reads the answer', () async {
    final notifier = MethodChannelDownloadNotifier();
    answer((_) => true);

    expect(await notifier.permission(), isTrue);
    expect(calls.single.method, 'permission');
    expect(calls.single.arguments, {'ask': true});

    answer((_) => false);
    expect(await notifier.permission(ask: false), isFalse);
    expect(calls.single.arguments, {'ask': false});
  });

  test('show sends the download and its notice', () async {
    final notifier = MethodChannelDownloadNotifier();
    answer((_) => null);

    await notifier.show(
      'frieren_3',
      const FinishNotice(
        title: 'Download failed',
        text: 'Frieren · EP 3',
        channelName: 'Finished downloads',
        failed: true,
      ),
    );

    expect(calls.single.method, 'show');
    expect(calls.single.arguments, {
      'id': 'frieren_3',
      'title': 'Download failed',
      'text': 'Frieren · EP 3',
      'channelName': 'Finished downloads',
      'failed': true,
    });
  });

  test('a platform with no native side shows nothing and is never '
      'allowed, never an error', () async {
    final notifier = MethodChannelDownloadNotifier();
    answer(null);

    expect(await notifier.permission(), isFalse);
    await notifier.show(
      'a',
      const FinishNotice(title: 'Download complete', channelName: 'x'),
    );
  });

  test('the tap that opened the app is asked for, and may be none', () async {
    final notifier = MethodChannelDownloadNotifier();
    answer((_) => 'frieren_3');
    expect(await notifier.launchTap(), 'frieren_3');
    expect(calls.single.method, 'launchTap');

    answer((_) => null);
    expect(await notifier.launchTap(), isNull);
  });

  test('a platform with no native side has no launch tap', () async {
    final notifier = MethodChannelDownloadNotifier();
    answer(null);

    expect(await notifier.launchTap(), isNull);
  });

  test('a tap names its download; anything else is ignored', () async {
    final notifier = MethodChannelDownloadNotifier();
    final heard = <String>[];
    final sub = notifier.taps.listen(heard.add);
    addTearDown(sub.cancel);

    for (final call in const [
      MethodCall('tapped', {'id': 'frieren_3'}),
      MethodCall('tapped'),
      MethodCall('unknown', {'id': 'x'}),
    ]) {
      await messenger.handlePlatformMessage(
        MethodChannelDownloadNotifier.channelName,
        const StandardMethodCodec().encodeMethodCall(call),
        (_) {},
      );
    }
    await Future<void>.delayed(Duration.zero);

    expect(heard, ['frieren_3']);
  });
}
