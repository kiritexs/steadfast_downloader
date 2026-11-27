import 'dart:async';

import 'package:flutter/services.dart';

/// Tells the person how a download ended, where the system shows such
/// things: Android's and iOS's notifications. Windows, Linux and macOS have
/// none here.
abstract interface class DownloadNotifier {
  /// This platform's notifier, made on first use: the plugin's own
  /// ([MethodChannelDownloadNotifier]) on Android, iOS and Windows, and
  /// [UnsupportedDownloadNotifier] on Linux and macOS, which have no native
  /// side. Set it to use another (a fake in tests).
  static DownloadNotifier get instance =>
      _instance ??= MethodChannelDownloadNotifier();
  static set instance(DownloadNotifier value) => _instance = value;
  static DownloadNotifier? _instance;

  /// Whether notifications may be shown, asking the person first when [ask]
  /// and they haven't answered yet. False where the platform has none.
  Future<bool> permission({bool ask = true});

  /// Shows [notice] for the download [id]; a later one for the same
  /// download takes its place.
  Future<void> show(String id, FinishNotice notice);

  /// A tap on one shown, with its download's id, once [launchTap] was
  /// asked.
  Stream<String> get taps;

  /// The download whose notification opened the app, once; null when it
  /// opened another way. Asked once the app is on screen: a tap that
  /// launches the app comes before Dart can hear it, so the native side
  /// keeps taps until this is asked, and sends them through [taps] after.
  Future<String?> launchTap();
}

/// How a download ended, in the app's own words: a title, a line, and the
/// name of the group it is shown under (Android's notification channel).
class FinishNotice {
  const FinishNotice({
    required this.title,
    this.text = '',
    required this.channelName,
    this.failed = false,
  });

  final String title;
  final String text;
  final String channelName;

  /// It stopped for good (its own icon), rather than finished.
  final bool failed;

  Map<String, Object?> toMap() => {
    'title': title,
    'text': text,
    'channelName': channelName,
    'failed': failed,
  };

  @override
  bool operator ==(Object other) =>
      other is FinishNotice &&
      other.title == title &&
      other.text == text &&
      other.channelName == channelName &&
      other.failed == failed;

  @override
  int get hashCode => Object.hash(title, text, channelName, failed);
}

/// [DownloadNotifier] over the plugin's channel,
/// `steadfast_downloader/notifications`.
class MethodChannelDownloadNotifier implements DownloadNotifier {
  MethodChannelDownloadNotifier({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_fromPlatform);
  }

  static const channelName = 'steadfast_downloader/notifications';

  final MethodChannel _channel;
  final _taps = StreamController<String>.broadcast();

  @override
  Stream<String> get taps => _taps.stream;

  @override
  Future<bool> permission({bool ask = true}) async {
    try {
      return await _channel.invokeMethod<bool>('permission', {'ask': ask}) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> show(String id, FinishNotice notice) async {
    try {
      await _channel.invokeMethod<void>('show', {'id': id, ...notice.toMap()});
    } on MissingPluginException {
      // Nothing is shown here.
    }
  }

  @override
  Future<String?> launchTap() async {
    try {
      return await _channel.invokeMethod<String>('launchTap');
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> _fromPlatform(MethodCall call) async {
    if (call.method != 'tapped') return;
    final id = (call.arguments as Map?)?['id'];
    if (id is String) _taps.add(id);
  }
}

/// [DownloadNotifier] where the plugin shows nothing (Linux, macOS):
/// [permission] is false, [show] does nothing, no tap ever comes.
class UnsupportedDownloadNotifier implements DownloadNotifier {
  const UnsupportedDownloadNotifier();

  @override
  Stream<String> get taps => const Stream.empty();

  @override
  Future<bool> permission({bool ask = true}) async => false;

  @override
  Future<void> show(String id, FinishNotice notice) async {}

  @override
  Future<String?> launchTap() async => null;
}
