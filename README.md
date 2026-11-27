# steadfast_downloader

Downloads that are never lost or restarted from nothing, for Flutter apps on
Android, iOS, Linux, macOS and Windows.

A file streams into `<name>.part` beside its final path, continues with an
HTTP `Range` request after any interruption (a dropped connection, a pause,
the app being closed), and takes its final name only when it is complete. A
partial is never thrown away unless your own check turns it down.

The package has two halves:

- **The engine** (`StreamingDownloader`, pure Dart over `package:http`):
  streams, resumes, retries, and judges what the server answers.
- **The platform side** (a small native plugin): keeps the app downloading
  while it is not in front, and tells the person how a download ended.

It is host-agnostic. It does not know where your files come from: your app
supplies fresh links when one expires and its own check of a partial. It is
also not a queue or a download manager: you decide what runs, when, and how
many at once.

---

## Platform support

| | Android | iOS | Linux | macOS | Windows |
|---|---|---|---|---|---|
| Streaming, resume, retry | yes | yes | yes | yes | yes |
| Keeps downloading in the background | foreground service (`dataSync`) and a partial wake lock | a silent, mixable audio session | no: `hold` answers `unsupported`; downloads run while the app runs | no: as on Linux | a power request: the PC does not sleep by itself while a download runs |
| Tells you the system sleeps and wakes | no | no | no | no | yes (`suspending`, `resumed`) |
| "Download finished / failed" notifications | yes | yes, while the app is in the background | no | no | no |
| Notification permission | asked at runtime on Android 13+ | asked at runtime | not needed | not needed | not needed |

The engine is pure Dart and the same everywhere. Linux and macOS have no
native code: there the plugin registers a Dart-only side whose keep-alive and
notifier do nothing (`UnsupportedKeepAlive`, `UnsupportedDownloadNotifier`),
so every call is safe and none throws.

Requires Dart 3.10 or newer. iOS 13.0 or newer. On Android the plugin follows
Flutter's own `minSdkVersion` and builds with Java 17. Web is not supported and
cannot be: the engine writes files with `dart:io`, which browsers do not have.

---

## Install

```bash
flutter pub add steadfast_downloader
```

---

## Platform setup

### Android

The plugin's manifest is merged into yours and already declares what it needs:

| Declared by the plugin | For |
|---|---|
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC` | the foreground service of type `dataSync` (the type and its permission are required from Android 14) |
| `WAKE_LOCK` | a partial wake lock while the service runs |
| `POST_NOTIFICATIONS` | the service's notification and the finish notices |
| `SteadfastDownloadService` (not exported) | the foreground service itself |

What your app still does:

- Declare `android.permission.INTERNET` in your main manifest if it does not
  already (Flutter's template only has it in the debug and profile manifests).
  The plugin does not declare it.
- Ask for the notification permission, on Android 13 and later, at a moment you
  choose: `DownloadNotifier.instance.permission()`. Without it the finish
  notices are not shown.
- Call `KeepAlive.hold` while the app is in front. From Android 12, the system
  refuses to start a foreground service from the background; `hold` then
  answers `KeepAliveHold.refused` and downloads carry on unprotected.

### iOS

Add the audio background mode to `ios/Runner/Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
</array>
```

That is all: no entitlement, and no Info.plist key for notifications. The
plugin links `AVFoundation` and `UserNotifications` itself.

### Windows and Linux

Nothing to declare.

### macOS

A sandboxed macOS app (Flutter's default) needs the network client
entitlement to download at all, and Flutter's templates leave it out. Add it to
both `macos/Runner/DebugProfile.entitlements` and `Release.entitlements`:

```xml
<key>com.apple.security.network.client</key>
<true/>
```

The sandbox also limits where files can be written: the app's own container
always works; the Downloads folder needs
`com.apple.security.files.downloads.read-write`.

---

## Usage

### Download a file

```dart
import 'package:steadfast_downloader/steadfast_downloader.dart';

final downloader = StreamingDownloader(
  log: print,
  // Optional: look at a partial before it is gone on from. Return false to
  // throw it away and start again (a web page saved in place of the file).
  partialIsValid: (partial) async => true,
);

final result = await downloader.run(
  taskId: 'file-42',                       // one run per task id at a time
  url: 'https://example.com/video.mp4',
  absFilePath: '/storage/downloads/video.mp4',
  headers: const {'User-Agent': 'my-app'},
  onProgress: (bytesOnDisk, totalBytes) {   // totalBytes is 0 when unknown
    print('$bytesOnDisk / $totalBytes');
  },
  // Optional: a new link when this one has expired (see "Link renewal").
  freshLink: () async {
    final next = await myApi.linkFor('file-42');
    return next == null ? null : FreshLink(next.url, headers: next.headers);
  },
  // Optional: the run is waiting out a back-off (a busy server, a dropped
  // connection) before it tries again by itself.
  onWaiting: (wait, error) {
    print('trying again in ${wait.inSeconds}s ($error)');
  },
);

if (result.outcome == DownloadOutcome.completed) {
  // The file is at absFilePath.
}
```

Call `run` again with the same arguments to continue after any other outcome:
it picks up from the `.part`. `cancel(taskId)` stops one transfer and
`cancelAll()` stops every one; each completes once the bytes on disk are
committed and the file is let go. The `.part` is kept. A cancel is answered at
once even while the run waits for your `freshLink` or out a back-off: the run
ends `cancelled`, and whatever the abandoned `freshLink` returns later is not
used (write it to your own storage only if the download is still wanted).

#### How a run ends

| `DownloadOutcome` | Meaning | The `.part` |
|---|---|---|
| `completed` | Whole file, renamed to its final path. | gone (it is the file) |
| `cancelled` | You stopped it. | kept |
| `interrupted` | The connection or server failed for a while with no bytes coming. Try again later. | kept |
| `needsFreshLink` | The link expired, or a page came in place of the file, and `freshLink` gave nothing. | kept |
| `diskFull` | No room left. Never tried again by itself. | kept |
| `failed` | The server refused for good, or the file could not be written or renamed. `result.error` says why. | kept |

`bytesOnDisk` and `totalBytes` on the result are what the `.part` holds and
what the server said the whole file is (0 if it did not).

#### Options

All of these are optional constructor arguments:

| Argument | Default | Meaning |
|---|---|---|
| `log` | none | Receives one line per step. |
| `partialIsValid` | accepts all | Your check of a partial before going on from it. |
| `commitEveryBytes`, `commitEvery` | 8 MiB, 5 s | How often the bytes on disk are recorded. |
| `stallTimeout` | 30 s | A connection with no bytes (headers included) for this long is dropped and retried. |
| `retryBase`, `retryCap` | 1 s, 2 min | Wait between tries: random, up to `retryBase` doubled each try, never over `retryCap`. |
| `quietAttempts` | 5 | Tries in a row with no bytes before the run ends as `interrupted`. Any bytes start the count again. |

### Keep downloading in the background

Hold the keep-alive while anything downloads, release it when nothing does.
`KeepAlive.instance` is the one for the platform the app runs on (the plugin's
channel on Android, iOS and Windows, a no-op on Linux and macOS). If you make
your own `MethodChannelKeepAlive` instead, make one and keep it: it owns its
platform channel.

```dart
final keepAlive = KeepAlive.instance;

keepAlive.events.listen((event) {
  switch (event) {
    case KeepAliveEvent.suspending: // Windows is going to sleep: stop now
      downloader.cancelAll();
    case KeepAliveEvent.resumed: // awake again: start them again
      resumeDownloads();
    case KeepAliveEvent.timedOut: // Android 15+: today's background time is up
      showBackgroundTimeUp();
    case KeepAliveEvent.tapped: // the person tapped the Android notification
      openDownloadsPage();
  }
});

final hold = await keepAlive.hold(
  const KeepAliveNotice(title: 'Downloading', channelName: 'Downloads'),
);
// hold: held, refused (Android refused the service) or unsupported (no plugin
// on this platform).

await keepAlive.update(
  const KeepAliveNotice(
    title: 'Downloading',
    text: '2 files',
    progress: 0.4,       // 0 to 1; null shows no bar
    channelName: 'Downloads',
  ),
);

await keepAlive.release();
```

What the notice means per platform:

| | `title` | `text`, `progress` | `channelName` |
|---|---|---|---|
| Android | the foreground notification's title | its line and progress bar | the notification channel's name |
| iOS | not shown | not shown (`update` does nothing) | not used |
| Windows | the reason shown by `powercfg /requests` | not shown | not used |
| Linux, macOS | not shown | not shown | not used |

On Android the wake lock is leased for 30 minutes and renewed by every
`update`, so call `update` as progress comes in (a few times a minute is
plenty, not on every `onProgress`).

### Tell the person how a download ended

```dart
// The plugin's channel on Android, iOS and Windows; a no-op on Linux and macOS.
final notifier = DownloadNotifier.instance;

// Asks on Android 13+ and iOS the first time; false when not allowed or when
// the plugin shows no notifications there (Windows, Linux, macOS).
final allowed = await notifier.permission();

await notifier.show(
  'file-42', // a later notice for the same id takes its place
  const FinishNotice(
    title: 'Download complete',
    text: 'video.mp4',
    channelName: 'Finished downloads',
    // failed: true,   // for one that stopped for good (Android shows another icon)
  ),
);

// A tap on a notice arrives with the download's id.
notifier.taps.listen(openDownload);

// Once the app is on screen: the download whose notice launched the app, or
// null. Taps before this call are kept, then sent through `taps`.
final launchedBy = await notifier.launchTap();
```

On iOS a notice is shown only while the app is in the background; in front, it
is suppressed and your own screens are expected to say so.

---

## Link renewal

Many hosts hand out links that expire. When an answer says the link is no
good (401, 403, 404 or 410; a web page instead of the file; a compressed body
when none was asked for), the engine asks your `freshLink` callback for a new
one and goes on from the same `.part`:

- It asks at most twice in one run. A link that expires again later in the run
  is renewed again, up to those two.
- `FreshLink.headers` replace the run's headers when they are not empty (a
  host's new cookie, for example).
- If the callback returns `null`, an empty link, or throws, the run ends in
  `needsFreshLink` and the `.part` is kept for you to try again later.
- If the callback throws `ServerBusy` (your own lookup failed on the way), the
  run waits with its normal backoff and tries again; that does not count as a
  renewal.
- A `cancel` while the callback runs ends the run as `cancelled` at once; the
  callback is left to finish on its own.
- Right after a renewal, a 401, 403, 404 or 410 is final: the run ends as
  `failed` rather than renewing in a loop.

---

## What a download leaves on disk

For a download to `/downloads/video.mp4`:

| File | When |
|---|---|
| `/downloads/video.mp4.part` | while it is incomplete |
| `/downloads/video.mp4.part.json` | its record: the committed offset, the link, size, strong ETag and the host that sent it, `Last-Modified`, content type |
| `/downloads/video.mp4.part.json.tmp` | only while the record is being rewritten (written whole, then renamed over the old one) |
| `/downloads/video.mp4` | only when the download is complete |

`workingPathsFor(absFilePath)` lists all four, for when you remove a download.
`partialPathFor` and `recordPathFor` give the other two on their own. The
folder is created when it is missing.

Bytes are flushed and then recorded. After a crash, whatever sits in the
`.part` beyond the recorded offset may be torn, and is cut before the download
goes on.

---

## Notes and limits

- **The server ignores `Range`.** An answer of 200 to a ranged request means
  the whole file is coming: the `.part` is rewritten from byte 0. (If its
  length differs from the size recorded earlier, it is first taken as an
  expired link.) Resuming only helps against servers that answer 206.
- **Resume is checked, not assumed.** A 206 must start at the asked offset,
  and the total size and `Last-Modified` must not have changed. If they have,
  the engine asks again from zero, and fails after doing so twice.
  `If-Range` is sent only with a strong ETag that the same host gave, since
  CDN edges often give different ones.
- **No compression.** Requests carry `Accept-Encoding: identity`, because
  compressed offsets are not the file's. `Range`, `If-Range` and
  `Accept-Encoding` in your `headers` are ignored.
- **A page is not a file.** If the body starts like HTML, it never reaches the
  `.part`; the engine treats it as an expired link.
- **A short body is not a file.** A body that ends before the size the server
  gave is retried, not taken as complete. Without a size (no `Content-Length`
  or `Content-Range`), a body cut short can't be told from a whole one.
- **An empty body is not a file.** A 200 or 206 with no bytes is retried, and
  never touches the `.part`.
- **Busy servers.** 408, 429 and 5xx answers are retried with backoff, honouring
  `Retry-After` up to 10 minutes. Other 4xx answers end the run as `failed`
  (416 is judged against the size on disk).
- **Rename on Windows.** Another program holding the `.part` open (an
  antivirus scan, the search indexer) can block the final rename; it is tried
  three times. If it still fails, the `.part` stays and the run reports
  `failed`; running again finds it complete and tries the rename again.
- **A file already at the final path** with no `.part` beside it is left
  alone and replaced once the download completes. If your app's older
  downloader kept partials under the final name, pass
  `adoptExistingFile: true`: such a file is then taken as a partial and
  checked with the server, so don't call `run` for a download you already
  finished.
- **Same task id.** Starting a second run with a `taskId` already running
  stops the first and waits for it to unwind.
- **Your own HTTP client.** `clientFactory` makes the client for each
  attempt (a proxy, your own certificate checks); by default it is
  `package:http`'s. The engine closes each client when its attempt ends.
- **No queue, no storage.** Nothing here remembers which downloads you wanted
  or how many may run at once; the `.part` files are what survives a restart.
- **Android swipe-away.** When the app is swiped away, the engine goes with it
  and the service stops. The `.part` covers the next launch.
- **iOS is best effort.** The silent audio session keeps the app from being
  suspended, but a call, memory pressure or a force quit can still end it; the
  download goes on from its `.part` the next time the app opens. The plugin sets
  the shared `AVAudioSession` category to playback with `mixWithOthers`, so
  other audio is not stopped, but an app that manages that session itself
  should expect the plugin to touch it. `release` stops the silent audio and
  leaves the session active, so the app's own player and AirPlay keep playing.
  When an interruption (a call, Siri) ends without iOS saying to resume, the
  silent audio starts again at once if the app is in front, otherwise the next
  time it comes to the front, and `hold` reports `held` only while it really
  plays. Apple's App Review guidelines limit the
  audio background mode to its intended purpose, so a store submission may be
  questioned on this point.
- **iOS notifications and your app's delegate.** The plugin becomes the
  `UNUserNotificationCenter` delegate only when nothing else is. If your app
  sets its own delegate, finish notices still show but taps do not come back
  through `taps`.
- **Windows keeps the system awake, not the screen.** The power request is
  "system required": the PC does not sleep by itself, but the person can still
  put it to sleep, and the screen can still turn off.

---

## Tests

```bash
flutter test
```

from this folder. The engine tests run against a real local HTTP server that
serves byte ranges and misbehaves on purpose (stalls, cuts, pages, expired
links, short bodies).

---

## License

MPL-2.0, © 2026 Kiritex.
