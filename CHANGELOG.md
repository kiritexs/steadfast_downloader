# Changelog

## 0.1.0

- First release.
- Each download streams into `<name>.part`, resumes with an HTTP Range
  request after any interruption, and takes its name only when complete.
- Host-agnostic: the app supplies fresh links and its own content check.
- `clientFactory` takes your own HTTP client (a proxy, your own certificate
  checks); `adoptExistingFile` goes on from a partial an older downloader
  left under the final name.
- Keeps downloading in the background on Android, iOS and Windows, and
  shows how each download ended.
- Runs on Linux and macOS too. There is no native code there: the plugin
  registers a Dart-only side whose keep-alive and notifier do nothing
  (`UnsupportedKeepAlive`, `UnsupportedDownloadNotifier`), so no call throws.
- `KeepAlive.instance` and `DownloadNotifier.instance` give the platform's
  own; set them to use another.
- A cancel or a pause is answered at once, even while a run waits for a fresh
  link or out a back-off; a fresh link that comes after the cancel is not
  used, and the back-off is one timer, not a polling loop.
- `run` takes an optional `onWaiting(wait, error)`, called before each
  back-off, so the app can say a download is waiting instead of showing it
  frozen.
- iOS: `release` leaves the app's audio session active, so the app's own
  player and AirPlay keep playing; the silent audio recovers after an
  interruption that ends without iOS saying to resume, and `hold` reports
  `held` only while it really plays.
