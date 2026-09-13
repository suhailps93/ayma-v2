import CallKit
import Flutter
import Foundation

/// Bridges the live Ayma voice call (owned by Dart's `VoiceSessionController`)
/// to Apple's CallKit so a backgrounded call gets a real system call UI — the
/// green status-bar pill, the lock-screen call card, and CallKit's own
/// end-call / mute controls. This is the closest thing Apple gives a
/// third-party app to Android's ongoing-notification call surface (F4).
///
/// We never receive a VoIP push (no PushKit) — this reports a plain local
/// call the moment `VoiceSessionController` goes live, the same shape
/// CallKit expects of an app-initiated outgoing call.
///
/// PRODUCT TRADE-OFF (flagged for the founder, not hidden): any call
/// reported through CallKit — including a call like this with no telephony
/// behind it — surfaces in the iPhone's built-in Phone app "Recents" list,
/// labeled with the app name. There is no supported way to get the system
/// call UI without that; Apple treats CallKit and telephony-style Recents as
/// one package.
final class CallKitManager: NSObject, CXProviderDelegate {
    private let channel: FlutterMethodChannel
    private let provider: CXProvider
    private let callController = CXCallController()
    private var activeCallId: UUID?

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        let config = CXProviderConfiguration(localizedName: "Ayma")
        config.supportsVideo = false
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        self.provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "start":
            startCall(status: args?["status"] as? String ?? "Voice call in progress")
            result(nil)
        case "update":
            updateCall(muted: args?["muted"] as? Bool)
            result(nil)
        case "stop":
            endCall()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startCall(status: String) {
        if activeCallId != nil { return }
        let uuid = UUID()
        activeCallId = uuid
        let handle = CXHandle(type: .generic, value: "Ayma")
        let startAction = CXStartCallAction(call: uuid, handle: handle)
        startAction.isVideo = false

        callController.requestTransaction(CXTransaction(action: startAction)) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.activeCallId = nil
                self.channel.invokeMethod("startFailed", arguments: ["error": error.localizedDescription])
                return
            }
            let update = CXCallUpdate()
            update.remoteHandle = handle
            update.localizedCallerName = "Ayma"
            update.hasVideo = false
            update.supportsHolding = false
            update.supportsGrouping = false
            update.supportsUngrouping = false
            update.supportsDTMF = false
            self.provider.reportCall(with: uuid, updated: update)
            self.provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
            self.provider.reportOutgoingCall(with: uuid, connectedAt: nil)
        }
    }

    private func updateCall(muted: Bool?) {
        guard let uuid = activeCallId, let muted = muted else { return }
        // Keeps CallKit's own mute affordance in sync when the mic was
        // toggled some other way (e.g. the in-app Mute button while the call
        // is still audible) — one state machine, two surfaces.
        let action = CXSetMutedCallAction(call: uuid, muted: muted)
        callController.requestTransaction(CXTransaction(action: action)) { _ in }
    }

    private func endCall() {
        guard let uuid = activeCallId else { return }
        let endAction = CXEndCallAction(call: uuid)
        callController.requestTransaction(CXTransaction(action: endAction)) { [weak self] _ in
            self?.activeCallId = nil
        }
    }

    // MARK: - CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        activeCallId = nil
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        activeCallId = nil
        channel.invokeMethod("hangUp", arguments: nil)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        channel.invokeMethod("setMuted", arguments: ["muted": action.isMuted])
        action.fulfill()
    }
}
