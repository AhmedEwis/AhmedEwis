import Flutter
import UIKit

/// Processes queued captures while the app UI isn't running, by starting a headless
/// Flutter engine that runs the `captureMain` Dart entrypoint. That entrypoint opens the
/// same encrypted database with the same schema and migrations, runs the same ingestion
/// pipeline, acknowledges processed inbox items and reports a summary.
///
/// Data protection is unchanged:
/// - The database key stays in the Keychain with `first_unlock_this_device`.
/// - Before the first unlock after a reboot the key is unreadable, so processing fails
///   safely and items stay queued (status: "securely queued").
/// - Inbox files use `completeUntilFirstUserAuthentication`.
///
/// Concurrency: if the UI engine is alive, it drains the inbox itself (notification) and no
/// headless engine is started. SQLite WAL + busy timeout guard the rare overlap; ingestion
/// is idempotent by platform id.
@MainActor
final class HeadlessCapture {
  static let shared = HeadlessCapture()
  var uiEngineActive = false
  private var engine: FlutterEngine?
  private var waiters: [CheckedContinuation<[String: Any], Never>] = []
  private var bgTask: UIBackgroundTaskIdentifier = .invalid

  struct Summary {
    let posted: Int
    let review: Int
    let ignored: Int
    let duplicate: Int
    let queued: Int
    let lastLine: String?
    let error: String?
  }

  /// Starts processing (if needed) and waits up to [wait] seconds for the result.
  func process(wait seconds: Double) async -> Summary? {
    if uiEngineActive {
      NotificationCenter.default.post(name: CaptureInbox.didChange, object: nil)
      return nil
    }
    startIfNeeded()
    let result: [String: Any]? = await withTaskGroup(of: [String: Any]?.self) { group in
      group.addTask { @MainActor in await self.awaitDone() }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
    guard let r = result else { return nil }
    return Summary(
      posted: r["posted"] as? Int ?? 0, review: r["review"] as? Int ?? 0, ignored: r["ignored"] as? Int ?? 0,
      duplicate: r["duplicate"] as? Int ?? 0, queued: r["queued"] as? Int ?? CaptureInbox.shared.count, lastLine: r["last"] as? String, error: r["error"] as? String)
  }

  private func awaitDone() async -> [String: Any] {
    await withCheckedContinuation { c in waiters.append(c) }
  }

  private func startIfNeeded() {
    guard engine == nil else { return }
    // Ask iOS for background execution time so processing can finish after the intent returns.
    bgTask = UIApplication.shared.beginBackgroundTask(withName: "fils.capture") { [weak self] in
      Task { @MainActor in self?.finish(["error": "expired"]) }
    }
    let e = FlutterEngine(name: "fils_capture", project: nil, allowHeadlessExecution: true)
    guard e.run(withEntrypoint: "captureMain", libraryURI: "package:fils/capture_main.dart") else {
      finish(["error": "engine_start_failed"])
      return
    }
    GeneratedPluginRegistrant.register(with: e)
    _ = CaptureChannels.register(messenger: e.binaryMessenger)
    let done = FlutterMethodChannel(name: "fils/capture/headless", binaryMessenger: e.binaryMessenger)
    done.setMethodCallHandler { [weak self] call, result in
      result(nil)
      if call.method == "done" {
        let args = call.arguments as? [String: Any] ?? [:]
        Task { @MainActor in self?.finish(args) }
      }
    }
    engine = e
  }

  private func finish(_ args: [String: Any]) {
    let ws = waiters
    waiters.removeAll()
    ws.forEach { $0.resume(returning: args) }
    engine?.destroyContext()
    engine = nil
    if bgTask != .invalid {
      UIApplication.shared.endBackgroundTask(bgTask)
      bgTask = .invalid
    }
  }
}
