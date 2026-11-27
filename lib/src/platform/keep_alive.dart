import 'dart:async';

import 'package:flutter/services.dart';

/// Keeps the app able to download while it isn't in front: Windows' power
/// request, Android's foreground service, iOS's silent audio session.
abstract interface class KeepAlive {
  /// This platform's keep-alive, made on first use: the plugin's own
  /// ([MethodChannelKeepAlive]) on Android, iOS and Windows, and
  /// [UnsupportedKeepAlive] on Linux and macOS, which have no native side.
  /// Set it to use another (a fake in tests).
  static KeepAlive get instance => _instance ??= MethodChannelKeepAlive();
  static set instance(KeepAlive value) => _instance = value;
  static KeepAlive? _instance;

  /// Downloads are waiting or running. [notice] is shown where the system
  /// shows one: Android's notification, `powercfg /requests` on Windows.
  Future<KeepAliveHold> hold(KeepAliveNotice notice);

  /// What is shown while held, again: progress, another download.
  Future<void> update(KeepAliveNotice notice);

  /// Nothing is left to download.
  Future<void> release();

  /// What the system tells the downloads.
  Stream<KeepAliveEvent> get events;
}

/// What the system shows while the keep-alive is held, in the app's own
/// words: a title, a line, progress from 0 to 1 (null: no bar), and the name
/// of the group it is shown under (Android's notification channel).
class KeepAliveNotice {
  const KeepAliveNotice({
    required this.title,
    this.text = '',
    this.progress,
    required this.channelName,
  });

  final String title;
  final String text;
  final double? progress;
  final String channelName;

  Map<String, Object?> toMap() => {
    'title': title,
    'text': text,
    'progress': progress,
    'channelName': channelName,
  };

  @override
  bool operator ==(Object other) =>
      other is KeepAliveNotice &&
      other.title == title &&
      other.text == text &&
      other.progress == progress &&
      other.channelName == channelName;

  @override
  int get hashCode => Object.hash(title, text, progress, channelName);
}

enum KeepAliveHold {
  held,

  /// The system said no (Android: a foreground service started while the
  /// app isn't in front); downloads go on unprotected.
  refused,

  /// This platform has nothing to hold.
  unsupported,
}

enum KeepAliveEvent {
  /// The system is about to sleep: commit and stop.
  suspending,

  /// Back from sleep: go on.
  resumed,

  /// The system took the keep-alive back (Android 15+'s 6 hours a day).
  timedOut,

  /// The person tapped what was shown (Android's notification).
  tapped,
}

/// [KeepAlive] over the plugin's channel, `steadfast_downloader/keep_alive`.
class MethodChannelKeepAlive implements KeepAlive {
  MethodChannelKeepAlive({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_fromPlatform);
  }

  static const channelName = 'steadfast_downloader/keep_alive';

  final MethodChannel _channel;
  final _events = StreamController<KeepAliveEvent>.broadcast();

  @override
  Stream<KeepAliveEvent> get events => _events.stream;

  @override
  Future<KeepAliveHold> hold(KeepAliveNotice notice) async {
    try {
      final answer = await _channel.invokeMethod<String>(
        'hold',
        notice.toMap(),
      );
      return answer == 'held' ? KeepAliveHold.held : KeepAliveHold.refused;
    } on MissingPluginException {
      return KeepAliveHold.unsupported;
    }
  }

  @override
  Future<void> update(KeepAliveNotice notice) async {
    try {
      await _channel.invokeMethod<void>('update', notice.toMap());
    } on MissingPluginException {
      // Nothing is shown.
    }
  }

  @override
  Future<void> release() async {
    try {
      await _channel.invokeMethod<void>('release');
    } on MissingPluginException {
      // Nothing was held.
    }
  }

  Future<void> _fromPlatform(MethodCall call) async {
    final event = switch (call.method) {
      'suspending' => KeepAliveEvent.suspending,
      'resumed' => KeepAliveEvent.resumed,
      'timedOut' => KeepAliveEvent.timedOut,
      'tapped' => KeepAliveEvent.tapped,
      _ => null,
    };
    if (event != null) _events.add(event);
  }
}

/// [KeepAlive] where the platform has nothing to hold (Linux, macOS):
/// [hold] answers [KeepAliveHold.unsupported], the rest does nothing, and
/// no event ever comes. Downloads run as long as the app does.
class UnsupportedKeepAlive implements KeepAlive {
  const UnsupportedKeepAlive();

  @override
  Stream<KeepAliveEvent> get events => const Stream.empty();

  @override
  Future<KeepAliveHold> hold(KeepAliveNotice notice) async =>
      KeepAliveHold.unsupported;

  @override
  Future<void> update(KeepAliveNotice notice) async {}

  @override
  Future<void> release() async {}
}
