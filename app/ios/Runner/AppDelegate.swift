import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 通知点击代理要在任何通知出现之前挂上。
    UNUserNotificationCenter.current().delegate = DshNotifyPlugin.shared.makeCenterDelegate()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // iOS 移植版的自定义插件（docs/ios-port-notes.md）。
    let registry = engineBridge.pluginRegistry
    DshAppPlugin.register(with: registry.registrar(forPlugin: "DshAppPlugin")!)
    DshNotifyPlugin.register(with: registry.registrar(forPlugin: "DshNotifyPlugin")!)
    DshMediaPlugin.register(with: registry.registrar(forPlugin: "DshMediaPlugin")!)
    DshDiagnosticsPlugin.register(with: registry.registrar(forPlugin: "DshDiagnosticsPlugin")!)
  }
}
