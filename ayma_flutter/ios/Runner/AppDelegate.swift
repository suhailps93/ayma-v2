import Flutter
import Photos
import UIKit
import UserNotifications

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

      // Mirrors the in-app notification unread count onto the app-icon badge
      // (§7.6) — set when a tap marks a notification read so the red icon
      // badge stays in sync with the in-app bell. 0 clears it.
      FlutterMethodChannel(
        name: "ayma/badge",
        binaryMessenger: controller.binaryMessenger
      ).setMethodCallHandler { call, result in
        guard call.method == "setBadge" else {
          result(FlutterMethodNotImplemented)
          return
        }
        let count = (call.arguments as? [String: Any])?["count"] as? Int ?? 0
        if #available(iOS 16.0, *) {
          UNUserNotificationCenter.current().setBadgeCount(max(0, count))
        } else {
          UIApplication.shared.applicationIconBadgeNumber = max(0, count)
        }
        result(nil)
      }

      // "Save image" for the report card: add-only Photos access, the
      // minimum needed to write (never read) the library.
      FlutterMethodChannel(
        name: "ayma/media_save",
        binaryMessenger: controller.binaryMessenger
      ).setMethodCallHandler { call, result in
        guard call.method == "saveImage" else {
          result(FlutterMethodNotImplemented)
          return
        }
        guard let args = call.arguments as? [String: Any],
              let bytes = args["bytes"] as? FlutterStandardTypedData else {
          result(FlutterError(code: "ARGS", message: "missing image bytes", details: nil))
          return
        }
        AppDelegate.saveToPhotos(bytes.data, result: result)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private static func saveToPhotos(_ data: Data, result: @escaping FlutterResult) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        DispatchQueue.main.async {
          result(FlutterError(code: "PERMISSION", message: "Photos add access not granted", details: nil))
        }
        return
      }
      PHPhotoLibrary.shared().performChanges({
        PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
      }) { ok, error in
        DispatchQueue.main.async {
          if ok {
            result("Photos")
          } else {
            result(FlutterError(code: "SAVE_FAILED", message: error?.localizedDescription, details: nil))
          }
        }
      }
    }
  }
}
