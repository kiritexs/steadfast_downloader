# steadfast_downloader example

A compact walk through one download from start to finish: start it, follow
its progress, keep it alive in the background, and handle each way it can end.
`myApi` and `openDownload` stand for your own code.

## 1. Set up once

Create each of these once and keep them. `KeepAlive.instance` and
`DownloadNotifier.instance` are the platform's own (each takes over its
platform channel on Android, iOS and Windows; both do nothing on Linux and
macOS), so read them after `WidgetsFlutterBinding.ensureInitialized()`.

```dart
import 'dart:io';

import 'package:steadfast_downloader/steadfast_downloader.dart';
import 'package:flutter/foundation.dart';

final downloader = StreamingDownloader(
  log: debugPrint,
  // Optional: refuse a partial that is not what you expect.
  partialIsValid: (partial) async => true,
);
final keepAlive = KeepAlive.instance;
final notifier = DownloadNotifier.instance;

/// What a download was asked for, so it can start again after the PC wakes
/// from sleep.
typedef Request = ({String url, String path, String title});

final requests = <String, Request>{};
var stoppedForSleep = <String, Request>{};
var _lastNoticeAt = DateTime(0);

Future<void> initDownloads() async {
  // Asks on Android 13+ and iOS the first time; false elsewhere.
  await notifier.permission();
  keepAlive.events.listen(onSystemEvent);
  notifier.taps.listen(openDownload);
  // Once the app is on screen: the download whose notice launched the app.
  final launchedBy = await notifier.launchTap();
  if (launchedBy != null) openDownload(launchedBy);
}
```

## 2. Start a download

`run` streams into `<path>.part`, resumes from it if it is already there, and
returns when the download ends one way or another. The keep-alive is held
while anything runs and released when nothing does.

```dart
Future<void> start(String id, String url, String path, String title) async {
  requests[id] = (url: url, path: path, title: title);
  await hold(title);
  try {
    final result = await downloader.run(
      taskId: id,
      url: url,
      absFilePath: path,
      headers: const {},
      onProgress: (bytesOnDisk, totalBytes) {
        // Called about every 150 ms; totalBytes is 0 when it is not known.
        if (totalBytes > 0) showProgress(title, bytesOnDisk / totalBytes);
      },
      // Called when the link has expired (at most twice a run).
      freshLink: () async {
        final next = await myApi.linkFor(id);
        return next == null ? null : FreshLink(next.url, headers: next.headers);
      },
    );
    await ended(id, title, result);
  } finally {
    requests.remove(id);
    if (requests.isEmpty) await keepAlive.release();
  }
}

Future<void> hold(String title) async {
  if (requests.length > 1) return; // already held for the others
  await keepAlive.hold(
    KeepAliveNotice(title: title, channelName: 'Downloads'),
  );
}

/// Android's notification and its wake lock are renewed by `update`; about
/// once a second is plenty.
void showProgress(String title, double progress) {
  final now = DateTime.now();
  if (now.difference(_lastNoticeAt) < const Duration(seconds: 1)) return;
  _lastNoticeAt = now;
  keepAlive.update(
    KeepAliveNotice(title: title, progress: progress, channelName: 'Downloads'),
  );
}
```

## 3. Handle how it ended

Every outcome except `completed` leaves the `.part` and its record on disk, so
running again goes on from where it stopped.

```dart
final retryLater = <String>{};

Future<void> ended(String id, String title, DownloadResult result) async {
  switch (result.outcome) {
    case DownloadOutcome.completed:
      await notifier.show(
        id,
        FinishNotice(
          title: 'Download complete',
          text: title,
          channelName: 'Finished downloads',
        ),
      );
    case DownloadOutcome.cancelled:
      retryLater.remove(id); // you stopped it (pause, or the system sleeping)
    case DownloadOutcome.interrupted:
      // Offline or the server failing for a while, no bytes coming.
      retryLater.add(id); // try again when the network is back
    case DownloadOutcome.needsFreshLink:
      // The link expired and freshLink gave nothing.
      retryLater.add(id); // ask for a new link when the person asks again
    case DownloadOutcome.diskFull:
      retryLater.add(id); // never retried by itself: tell the person
      await notifier.show(
        id,
        FinishNotice(
          title: 'Not enough space',
          text: title,
          channelName: 'Finished downloads',
          failed: true,
        ),
      );
    case DownloadOutcome.failed:
      debugPrint('$id failed at ${result.bytesOnDisk} bytes: ${result.error}');
      await notifier.show(
        id,
        FinishNotice(
          title: 'Download failed',
          text: title,
          channelName: 'Finished downloads',
          failed: true,
        ),
      );
  }
}
```

## 4. React to the system, pause and remove

```dart
void onSystemEvent(KeepAliveEvent event) {
  switch (event) {
    case KeepAliveEvent.suspending:
      // Windows is about to sleep: commit the bytes and stop.
      stoppedForSleep = {...requests};
      downloader.cancelAll();
    case KeepAliveEvent.resumed:
      // Awake again: start the stopped ones from their `.part`.
      final again = stoppedForSleep;
      stoppedForSleep = {};
      for (final MapEntry(:key, :value) in again.entries) {
        start(key, value.url, value.path, value.title);
      }
    case KeepAliveEvent.timedOut:
      // Android 15+: today's background time is used up. Downloads go on
      // only while the app is in front.
      debugPrint('background time is up');
    case KeepAliveEvent.tapped:
      // The person tapped the Android notification: show the downloads page.
      openDownload(null);
  }
}

/// Pause: stops the transfer and keeps the `.part`; `start` goes on from it.
Future<void> pause(String id) => downloader.cancel(id);

/// Remove: stops it, then deletes the file, its `.part` and its record.
Future<void> remove(String id, String path) async {
  await downloader.cancel(id);
  for (final file in workingPathsFor(path)) {
    final entity = File(file);
    if (await entity.exists()) await entity.delete();
  }
}
```

## Setting the app up

The platform setup (Android's `INTERNET` permission and notification
permission, iOS's `audio` background mode) is in the package README.
