// iOS 原生插件（iOS 移植版 MVP，docs/ios-port-notes.md）。
//
// 契约逐条对齐 Dart 封装层（lib/notify/notify_channel.dart、lib/media/gallery.dart、
// lib/diagnostics/diagnostics_channel.dart、lib/performance/refresh_rate.dart）：
// 缺键/失败时 Dart 侧的降级行为见 docs/ios-port-notes.md 的通道契约一节。
// Android 专属的方法（live/collectSystemIme/media_video…）不实现：
// Flutter 会回 MissingPluginException，Dart 端按既有降级路径处理。

import Flutter
import Photos
import UIKit

// MARK: - dsh/app

/// 时区与刷新率。Android 的刷新率控制在 iOS 无对应 API，全部 no-op；
/// `getTimeZoneId` 让日程编辑的时区匹配用上真实 IANA id。
final class DshAppPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "dsh/app", binaryMessenger: registrar.messenger())
    let instance = DshAppPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getTimeZoneId":
      result(TimeZone.current.identifier)
    case "setRefreshRateMode", "setFrameActive", "bringToFront":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

// MARK: - dsh/notify

/// 通知。iOS 用 UNUserNotificationCenter 复刻 Android 三通道的最小集：
/// MethodChannel 的 status/show/cancel*/openSettings/actionResult，加上
/// taps EventChannel（actions 留空：Dart 端在 status.native 时才订阅，
/// 空流只会安静地没有事件）。
///
/// 点击语义对齐 ChatNotifier.kt：通知 userInfo 携带 sessionId/host/kind/eventId，
/// 冷启动先持有、listen 时补发（NotifyPlugin.kt:91-94）。
final class DshNotifyPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  static let shared = DshNotifyPlugin()

  private var sink: FlutterEventSink?
  /// 已点到但 Dart 还没 listen 的 tap（冷启动窗口）。
  private var pendingTaps: [[String: Any]] = []

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "dsh/notify", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(shared, channel: channel)

    let taps = FlutterEventChannel(name: "dsh/notify/taps", binaryMessenger: registrar.messenger())
    taps.setStreamHandler(shared)
  }

  /// AppDelegate 在启动时挂上的通知中心代理。
  func makeCenterDelegate() -> UNUserNotificationCenterDelegate { DshNotificationDelegate(plugin: self) }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "status":
      let center = UNUserNotificationCenter.current()
      center.getNotificationSettings { settings in
        let on = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
          || settings.authorizationStatus == .ephemeral
        // FlutterResult 只能在平台主线程使用；center 的回调在私有队列。
        DispatchQueue.main.async { result(["enabled": on, "done": on, "attention": on]) }
      }
    case "show":
      guard let args = call.arguments as? [String: Any],
        let group = args["group"] as? String, !group.isEmpty,
        let key = args["key"] as? String, !key.isEmpty,
        let sessionId = args["sessionId"] as? String, !sessionId.isEmpty
      else {
        result(FlutterError(code: "bad_args", message: "group/key/sessionId required", details: nil))
        return
      }
      requestAuthorizationIfNeeded()
      let content = UNMutableNotificationContent()
      content.title = (args["title"] as? String) ?? "DSH Go"
      let body = (args["publicText"] as? String) ?? (args["text"] as? String) ?? ""
      content.body = body
      if (args["attention"] as? Bool) == true { content.sound = .default }
      var userInfo: [String: Any] = [
        "group": group,
        "key": key,
        "sessionId": sessionId,
      ]
      if let host = args["host"] as? String { userInfo["host"] = host }
      if let kind = args["kind"] as? String { userInfo["kind"] = kind }
      if let eventId = args["eventId"] as? String { userInfo["eventId"] = eventId }
      content.userInfo = userInfo
      // Android 用 group+key 作通知 id：这里合成稳定 identifier，便于 cancel。
      let request = UNNotificationRequest(identifier: "\(group)/\(key)", content: content, trigger: nil)
      UNUserNotificationCenter.current().add(request) { _ in
        DispatchQueue.main.async { result(nil) }
      }
    case "cancel":
      guard let args = call.arguments as? [String: Any],
        let group = args["group"] as? String, let key = args["key"] as? String
      else { result(nil); return }
      removeIdentifiers(["\(group)/\(key)"])
      result(nil)
    case "cancelGroup":
      guard let args = call.arguments as? [String: Any], let group = args["group"] as? String
      else { result(nil); return }
      removeMatching { ($0["group"] as? String) == group }
      result(nil)
    case "cancelAll":
      let center = UNUserNotificationCenter.current()
      center.removeAllPendingNotificationRequests()
      center.removeAllDeliveredNotifications()
      result(nil)
    case "openSettings":
      guard let url = URL(string: UIApplication.openSettingsURLString) else { result(false); return }
      DispatchQueue.main.async { UIApplication.shared.open(url) { opened in result(opened) } }
    case "actionResult":
      result(nil)
    case "live", "liveStatus", "openLiveSettings":
      // iOS 版不做 Android 的“实时活动”模拟；Dart 端按 unavailable 降级。
      result(FlutterMethodNotImplemented)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestAuthorizationIfNeeded() {
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
      guard settings.authorizationStatus == .notDetermined else { return }
      center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
  }

  private func removeIdentifiers(_ ids: [String]) {
    let center = UNUserNotificationCenter.current()
    center.removePendingNotificationRequests(withIdentifiers: ids)
    center.removeDeliveredNotifications(withIdentifiers: ids)
  }

  private func removeMatching(_ predicate: @escaping ([AnyHashable: Any]) -> Bool) {
    let center = UNUserNotificationCenter.current()
    center.getDeliveredNotifications { notifications in
      let ids = notifications.filter { predicate($0.request.content.userInfo) }.map(\.request.identifier)
      center.removeDeliveredNotifications(withIdentifiers: ids)
    }
    center.getPendingNotificationRequests { requests in
      let ids = requests.filter { predicate($0.content.userInfo) }.map(\.identifier)
      center.removePendingNotificationRequests(withIdentifiers: ids)
    }
  }

  /// taps EventChannel。
  func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    if !pendingTaps.isEmpty {
      let held = pendingTaps
      pendingTaps.removeAll()
      for tap in held { events(tap) }
    }
    return nil
  }

  func onCancel(withArguments _: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  /// 通知中心代理回传的点击。
  fileprivate func emitTap(userInfo: [AnyHashable: Any]) {
    guard let sessionId = userInfo["sessionId"] as? String, !sessionId.isEmpty else { return }
    var tap: [String: Any] = ["sessionId": sessionId]
    if let host = userInfo["host"] as? String { tap["host"] = host }
    if let kind = userInfo["kind"] as? String { tap["kind"] = kind }
    if let eventId = userInfo["eventId"] as? String { tap["eventId"] = eventId }
    if let sink { sink(tap) } else { pendingTaps.append(tap) }
  }
}

/// 点击代理：前台也弹横幅；点击时把 sessionId 交给 Dart。
final class DshNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
  private weak var plugin: DshNotifyPlugin?

  init(plugin: DshNotifyPlugin) {
    self.plugin = plugin
    super.init()
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    plugin?.emitTap(userInfo: response.notification.request.content.userInfo)
    completionHandler()
  }
}

// MARK: - dsh/media

/// 相册保存。错误码对齐 MediaPlugin.kt：invalid / permission / failed；
/// 返回值只是给用户看的落点展示串，Dart 端为 null 时自行兜底。
final class DshMediaPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "dsh/media", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(DshMediaPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "saveImage":
      guard let args = call.arguments as? [String: Any],
        let typed = args["bytes"] as? FlutterStandardTypedData, !typed.data.isEmpty,
        let name = args["name"] as? String, !name.isEmpty,
        let mime = args["mime"] as? String
      else {
        result(FlutterError(code: "invalid", message: "bytes/name/mime required", details: nil))
        return
      }
      guard let utType = Self.utType(forMime: mime) else {
        result(FlutterError(code: "invalid", message: "unsupported mime \(mime)", details: nil))
        return
      }
      save(data: typed.data, utType: utType, name: name, displayFolder: "Photos/DSH Go", result: result)
    case "saveVideoFile":
      guard let args = call.arguments as? [String: Any],
        let path = args["path"] as? String, path.hasPrefix("/"),
        let name = args["name"] as? String, !name.isEmpty
      else {
        result(FlutterError(code: "invalid", message: "path/name required", details: nil))
        return
      }
      let ext = (name as NSString).pathExtension.lowercased()
      let allowed = ["mp4", "m4v", "mov", "webm", "3gp", "mkv", "avi"]
      guard allowed.contains(ext), FileManager.default.fileExists(atPath: path) else {
        result(FlutterError(code: "invalid", message: "unsupported extension or missing file", details: nil))
        return
      }
      let url = URL(fileURLWithPath: path)
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
        DispatchQueue.main.async {
          guard status == .authorized || status == .limited else {
            result(FlutterError(code: "permission", message: "photo library add denied", details: nil))
            return
          }
          PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
          } completionHandler: { ok, _ in
            DispatchQueue.main.async { result(ok ? "Movies/DSH Go/\(name)" : nil) }
          }
        }
      }
    case "openSettings":
      guard let url = URL(string: UIApplication.openSettingsURLString) else { result(false); return }
      DispatchQueue.main.async { UIApplication.shared.open(url) { opened in result(opened) } }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func utType(forMime mime: String) -> UTType? {
    switch mime {
    case "image/png": return .png
    case "image/jpeg": return .jpeg
    case "image/gif": return .gif
    case "image/webp": return UTType("public.webp")
    default: return nil
    }
  }

  private func save(data: Data, utType: UTType, name: String, displayFolder: String, result: @escaping FlutterResult) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      DispatchQueue.main.async {
        guard status == .authorized || status == .limited else {
          result(FlutterError(code: "permission", message: "photo library add denied", details: nil))
          return
        }
        PHPhotoLibrary.shared().performChanges {
          let request = PHAssetCreationRequest.forAsset()
          let options = PHAssetResourceCreationOptions()
          options.originalFilename = name
          options.uniformTypeIdentifier = utType.identifier
          request.addResource(with: .photo, data: data, options: options)
        } completionHandler: { ok, _ in
          DispatchQueue.main.async { result(ok ? "\(displayFolder)/\(name)" : nil) }
        }
      }
    }
  }
}

// MARK: - dsh/diagnostics

/// 诊断信息。Dart 端对缺 section 全兜底；`info`/`engineLog` 在 Dart 侧只 catch
/// MissingPluginException——这里绝不抛错，有什么都塞进 Map。
final class DshDiagnosticsPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "dsh/diagnostics", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(DshDiagnosticsPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "info":
      let info = ProcessInfo.processInfo
      let device = UIDevice.current
      let screen = UIScreen.main
      let version = Bundle.main.infoDictionary
      let free = (try? URL(fileURLWithPath: NSHomeDirectory())
        .resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity) ?? 0
      result([
        "app": [
          "versionName": version?["CFBundleShortVersionString"] ?? "",
          "versionCode": version?["CFBundleVersion"] ?? "",
          "abi": "arm64",
        ],
        "device": [
          "manufacturer": "Apple",
          "brand": "Apple",
          "model": device.model,
          "android": "",
          "sdkInt": ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
          "abis": ["arm64"],
          "memoryMb": Int64(info.physicalMemory / 1024 / 1024),
          "freeStorageMb": Int64(free / 1024 / 1024),
          "display": [
            "widthPx": Int(screen.bounds.width * screen.scale),
            "heightPx": Int(screen.bounds.height * screen.scale),
            "density": screen.scale,
            "densityDpi": Int(screen.scale * 160),
            "fontScale": 1.0,
          ],
        ],
        "manifest": [:],
      ] as [String: Any])
    case "engineLog":
      result([])
    case "collectSystemIme":
      // Android 特权 API；iOS 版让 Dart 走 'unsupported' 证据路径。
      result(FlutterMethodNotImplemented)
    case "cancelSystemIme":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
