import Flutter
import UIKit

/// The `fils/capture` method channel, registered on whichever Flutter engine is running:
/// the UI engine or the headless capture engine.
enum CaptureChannels {
  static func register(messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: "fils/capture", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "drainInbox":
        result(CaptureInbox.shared.pending())
      case "ack":
        let ids = (call.arguments as? [String: Any])?["ids"] as? [String] ?? []
        CaptureInbox.shared.remove(ids: ids)
        result(nil)
      case "inboxCount":
        result(CaptureInbox.shared.count)
      case "takeSharedText":
        result(nil) // iOS shares arrive through the inbox (source = "share")
      case "openShortcuts":
        if let url = URL(string: "shortcuts://") { UIApplication.shared.open(url) }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    return channel
  }
}
