import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  // Keeps the CallKit bridge alive for the app's lifetime — it owns the
  // CXProvider a backgrounded voice call needs (F4).
  private var callKitManager: CallKitManager?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "ayma/call_ui",
        binaryMessenger: controller.binaryMessenger
      )
      let manager = CallKitManager(channel: channel)
      callKitManager = manager
      channel.setMethodCallHandler { call, result in
        manager.handle(call, result: result)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
