import AVFoundation
import Flutter
import UIKit
import UserNotifications

/// The plugin's two channels on iOS. The keep-alive's: hold starts a silent,
/// mixable audio session, so iOS doesn't suspend the app and Dart keeps
/// downloading on the lock screen; release stops it. It needs only
/// `UIBackgroundModes: audio` in the app's Info.plist, no entitlement, so it
/// signs on a free Apple account; update is a no-op (iOS shows nothing while
/// it holds). The notifications': the permission, a download's finish shown,
/// a tap sent back with its download.
public class SteadfastDownloaderPlugin: NSObject, FlutterPlugin {
  private let silence = SilentAudio()
  private let notices = FinishNotices()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = SteadfastDownloaderPlugin()
    let keepAlive = FlutterMethodChannel(
      name: "steadfast_downloader/keep_alive",
      binaryMessenger: registrar.messenger())
    let notifications = FlutterMethodChannel(
      name: "steadfast_downloader/notifications",
      binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: keepAlive)
    registrar.addMethodCallDelegate(instance, channel: notifications)
    // Set while the app launches, so a tap that opened it still arrives.
    instance.notices.adopt { id in
      notifications.invokeMethod("tapped", arguments: ["id": id])
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "hold":
      result(silence.start() ? "held" : "refused")
    case "update":
      result(nil)
    case "release":
      silence.stop()
      result(nil)
    case "permission":
      notices.permission(ask: args["ask"] as? Bool ?? true, result: result)
    case "show":
      notices.show(
        id: args["id"] as? String ?? "",
        title: args["title"] as? String ?? "",
        text: args["text"] as? String ?? "")
      result(nil)
    case "launchTap":
      result(notices.launchTap())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    silence.stop()
  }
}

/// The notifications that say a download finished or stopped for good: one
/// per download, shown while the app is in the background (in front, its
/// own screens say so), a tap naming its download. A tap is kept until Dart
/// asks for it (`launchTap`): the one that launched the app may come before
/// Dart can hear it.
///
/// They take the notification center's delegate only when nothing else has
/// it; an app that sets its own gets no taps from here.
final class FinishNotices: NSObject, UNUserNotificationCenterDelegate {
  private static let idKey = "steadfast_downloader.id"
  // The key under the package's first name, durable_downloader: a notice
  // posted before the rename still opens its download when tapped.
  private static let firstNameIdKey = "durable_downloader.id"
  private var onTap: ((String) -> Void)?
  private var pendingTap: String?
  private var dartListens = false

  func adopt(onTap: @escaping (String) -> Void) {
    self.onTap = onTap
    let center = UNUserNotificationCenter.current()
    if center.delegate == nil { center.delegate = self }
  }

  /// The tap kept from before Dart asked, once; from now on taps go to Dart.
  func launchTap() -> String? {
    dartListens = true
    let id = pendingTap
    pendingTap = nil
    return id
  }

  /// Whether notifications may be shown; asks first when [ask] and the
  /// person hasn't answered yet.
  func permission(ask: Bool, result: @escaping FlutterResult) {
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
      let answer: (Bool) -> Void = { allowed in
        DispatchQueue.main.async { result(allowed) }
      }
      switch settings.authorizationStatus {
      case .authorized, .provisional:
        answer(true)
      case .notDetermined where ask:
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
          answer(granted)
        }
      default:
        answer(false)
      }
    }
  }

  func show(id: String, title: String, text: String) {
    guard !id.isEmpty else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = text
    content.sound = .default
    content.userInfo = [FinishNotices.idKey: id]
    // The download's own identifier: a later one for it takes its place.
    let request = UNNotificationRequest(
      identifier: "steadfast_downloader.\(id)", content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    if let id = (info[FinishNotices.idKey] ?? info[FinishNotices.firstNameIdKey]) as? String {
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        if self.dartListens {
          self.onTap?(id)
        } else {
          self.pendingTap = id
        }
      }
    }
    completionHandler()
  }
}

/// A playing, zero-amplitude audio session. While audio renders, iOS doesn't
/// suspend the app. `.mixWithOthers`: the person's music is never stopped.
///
/// Best effort: a call, memory pressure or a force quit can still end the
/// app, and the download then goes on from its `.part` when it is opened.
/// It restarts itself after an interruption the system says to resume from,
/// after one that ends without saying so once the app is in front, when the
/// app comes to the front, after the audio engine stops on a route change
/// (headphones in or out), and after the system resets its media services.
/// Letting go leaves the app's audio session active: the app's own player
/// and AirPlay use the same session.
final class SilentAudio {
  private var engine = AVAudioEngine()
  private var player = AVAudioPlayerNode()
  private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
  private lazy var buffer: AVAudioPCMBuffer? = SilentAudio.silentBuffer(format: format)
  private var held = false

  init() {
    // Attached exactly once per engine: attaching an attached node raises an
    // Objective-C exception Swift can't catch.
    connect()
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(interrupted(_:)),
      name: AVAudioSession.interruptionNotification, object: nil)
    center.addObserver(
      self, selector: #selector(engineReconfigured(_:)),
      name: .AVAudioEngineConfigurationChange, object: nil)
    center.addObserver(
      self, selector: #selector(mediaServicesReset(_:)),
      name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    center.addObserver(
      self, selector: #selector(becameActive(_:)),
      name: UIApplication.didBecomeActiveNotification, object: nil)
  }

  /// The silent audio is really rendering: the engine runs and the node
  /// plays. An interruption can stop it while the hold stands.
  private var playing: Bool { engine.isRunning && player.isPlaying }

  /// Begins holding; true once audio is playing. Idempotent while it plays;
  /// a hold whose audio stopped starts it again, and says so if it can't.
  func start() -> Bool {
    if held && playing { return true }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, options: [.mixWithOthers])
      try session.setActive(true)
      try play()
      held = true
    } catch {
      held = false
    }
    return held
  }

  /// Lets go. Idempotent; the node stays attached.
  func stop() {
    guard held else { return }
    held = false
    player.stop()
    engine.stop()
    // The session stays active: deactivating it would stop the app's own
    // player and AirPlay, and `.mixWithOthers` interrupted no one to notify.
  }

  private func connect() {
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
  }

  /// (Re)starts the engine and schedules the looping silent buffer: iOS
  /// flushes a player's buffers when it stops, and a bare play() would then
  /// render nothing, which lets the system suspend the app.
  private func play() throws {
    guard let buffer = buffer else { return }
    if !engine.isRunning { try engine.start() }
    player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
    player.play()
  }

  /// Back to playing while held, on the main queue (notifications arrive on
  /// any thread).
  private func resume() {
    DispatchQueue.main.async { [weak self] in
      // Already playing: another buffer would only stack on the loop.
      guard let self = self, self.held, !self.playing else { return }
      do {
        try AVAudioSession.sharedInstance().setActive(true)
        try self.play()
      } catch {
        // Best effort; the download goes on from its .part later.
      }
    }
  }

  @objc private func interrupted(_ note: Notification) {
    guard
      let info = note.userInfo,
      let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
      AVAudioSession.InterruptionType(rawValue: raw) == .ended
    else { return }
    // When the system says so (Apple's guidance), or at once while the app
    // is in front; otherwise when it comes to the front (`becameActive`).
    // In the background, fighting another app for the session would fail.
    let options = AVAudioSession.InterruptionOptions(
      rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
    if options.contains(.shouldResume) {
      resume()
    } else {
      DispatchQueue.main.async { [weak self] in
        guard UIApplication.shared.applicationState == .active else { return }
        self?.resume()
      }
    }
  }

  /// In front again: audio an interruption left stopped plays again, while
  /// held.
  @objc private func becameActive(_ note: Notification) {
    resume()
  }

  /// The engine stops itself when its configuration changes (a route change:
  /// headphones in or out).
  @objc private func engineReconfigured(_ note: Notification) {
    resume()
  }

  /// Every audio object is invalid after a media services reset: a new engine
  /// and node, then back to playing while held.
  @objc private func mediaServicesReset(_ note: Notification) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.engine = AVAudioEngine()
      self.player = AVAudioPlayerNode()
      self.connect()
      guard self.held else { return }
      do {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, options: [.mixWithOthers])
        try session.setActive(true)
        try self.play()
      } catch {
        // Best effort, as above.
      }
    }
  }

  private static func silentBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
    let frames = AVAudioFrameCount(format.sampleRate)  // 1 second
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
    else { return nil }
    buffer.frameLength = frames
    if let channels = buffer.floatChannelData {
      memset(channels[0], 0, Int(frames) * MemoryLayout<Float>.size)
    }
    return buffer
  }
}
