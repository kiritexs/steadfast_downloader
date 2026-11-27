/// The keep-alive channel's names and answers, which the native side of each
/// platform implements.
library;

import 'package:steadfast_downloader/src/platform/keep_alive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel(MethodChannelKeepAlive.channelName);
  final calls = <MethodCall>[];
  const notice = KeepAliveNotice(
    title: 'Downloading Frieren · EP 3',
    text: '45% · 120 MB of 268 MB',
    progress: 0.45,
    channelName: 'Downloads',
  );
  const noticeArgs = {
    'title': 'Downloading Frieren · EP 3',
    'text': '45% · 120 MB of 268 MB',
    'progress': 0.45,
    'channelName': 'Downloads',
  };

  void answer(Object? Function(MethodCall call)? reply) {
    calls.clear();
    messenger.setMockMethodCallHandler(
      channel,
      reply == null ? null : (call) async => reply(call),
    );
  }

  Object? record(MethodCall call) {
    calls.add(call);
    return null;
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('hold sends its notice and reads the answer', () async {
    final keepAlive = MethodChannelKeepAlive();
    answer((call) {
      calls.add(call);
      return 'held';
    });

    expect(await keepAlive.hold(notice), KeepAliveHold.held);
    expect(calls.single.method, 'hold');
    expect(calls.single.arguments, noticeArgs);

    answer((_) => 'refused');
    expect(await keepAlive.hold(notice), KeepAliveHold.refused);
  });

  test('a notice with no progress sends none', () async {
    final keepAlive = MethodChannelKeepAlive();
    answer(record);

    await keepAlive.update(
      const KeepAliveNotice(title: 'Waiting for network', channelName: 'x'),
    );

    expect(calls.single.method, 'update');
    expect(calls.single.arguments, {
      'title': 'Waiting for network',
      'text': '',
      'progress': null,
      'channelName': 'x',
    });
  });

  test('a platform with no native side is unsupported, never an '
      'error', () async {
    final keepAlive = MethodChannelKeepAlive();
    answer(null);

    expect(await keepAlive.hold(notice), KeepAliveHold.unsupported);
    await keepAlive.update(notice);
    await keepAlive.release();
  });

  test('update and release are sent', () async {
    final keepAlive = MethodChannelKeepAlive();
    answer(record);

    await keepAlive.update(notice);
    await keepAlive.release();

    expect(calls.map((c) => c.method), ['update', 'release']);
    expect(calls.first.arguments, noticeArgs);
  });

  test('the system\'s word arrives as events', () async {
    final keepAlive = MethodChannelKeepAlive();
    final heard = <KeepAliveEvent>[];
    final sub = keepAlive.events.listen(heard.add);
    addTearDown(sub.cancel);

    for (final method in [
      'suspending',
      'resumed',
      'timedOut',
      'tapped',
      'unknown',
    ]) {
      await messenger.handlePlatformMessage(
        MethodChannelKeepAlive.channelName,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
        (_) {},
      );
    }
    await Future<void>.delayed(Duration.zero);

    expect(heard, [
      KeepAliveEvent.suspending,
      KeepAliveEvent.resumed,
      KeepAliveEvent.timedOut,
      KeepAliveEvent.tapped,
    ]);
  });
}
