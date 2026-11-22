import AppIntents
import Flutter
import UIKit

// MARK: - App delegate + capture channel

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var captureChannel: FlutterMethodChannel?
  private var eventSink: FlutterEventSink?
  private var inboxObserver: NSObjectProtocol?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FilsCapture") else { return }
    let channel = FlutterMethodChannel(name: "fils/capture", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "drainInbox":
        result(CaptureInbox.shared.pending())
      case "ack":
        let ids = (call.arguments as? [String: Any])?["ids"] as? [String] ?? []
        CaptureInbox.shared.remove(ids: ids)
        result(nil)
      case "takeSharedText":
        result(nil) // iOS shares arrive through the inbox (source = "share")
      case "openShortcuts":
        if let url = URL(string: "shortcuts://") { UIApplication.shared.open(url) }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    captureChannel = channel

    let events = FlutterEventChannel(name: "fils/capture/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(self)

    // When an App Intent runs while the app is alive, it posts this notification so the
    // Dart side drains immediately.
    inboxObserver = NotificationCenter.default.addObserver(forName: CaptureInbox.didChange, object: nil, queue: .main) { [weak self] _ in
      self?.eventSink?(true)
    }
  }
}

extension AppDelegate: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}

// MARK: - Durable capture inbox

/// File-based inbox in the App Group container. Each event is one JSON file written
/// atomically with `completeUntilFirstUserAuthentication` protection, so Shortcuts can run
/// the intent while the phone is locked (after the first unlock since boot). Nothing is
/// parsed or sent anywhere here: the Flutter side parses, dedupes and acknowledges.
final class CaptureInbox {
  static let shared = CaptureInbox()
  static let didChange = Notification.Name("FilsCaptureInboxDidChange")
  static let appGroup = "group.kw.fils"
  private let maxEvents = 500
  private let maxTextLength = 2000

  private var dir: URL {
    let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let d = base.appendingPathComponent("capture_inbox", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                             attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    return d
  }

  enum InboxError: Error { case full, empty }

  @discardableResult
  func add(source: String, text: String, sender: String?, fields: [String: String]? = nil, kind: String? = nil, platformId: String? = nil) throws -> String {
    let trimmed = String(text.prefix(maxTextLength))
    if trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (fields?.isEmpty ?? true) { throw InboxError.empty }
    let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    if existing.count >= maxEvents { throw InboxError.full }
    let id = UUID().uuidString
    var obj: [String: Any] = [
      "id": id,
      "source": source,
      "text": trimmed,
      "receivedAt": ISO8601DateFormatter().string(from: Date()),
      // Each Shortcuts run gets a distinct id. A retried run that re-sends the same
      // message is deduplicated in Dart by text hash and time window.
      "platformId": platformId ?? id,
    ]
    if let sender = sender, !sender.isEmpty { obj["sender"] = String(sender.prefix(64)) }
    if let fields = fields { obj["fields"] = fields }
    if let kind = kind { obj["kind"] = kind }
    let data = try JSONSerialization.data(withJSONObject: obj)
    let url = dir.appendingPathComponent("\(id).json")
    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    NotificationCenter.default.post(name: Self.didChange, object: nil)
    return id
  }

  func pending() -> [[String: Any]] {
    let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    return files.compactMap { url in
      guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
      return o
    }
  }

  func remove(ids: [String]) {
    for id in ids where !id.isEmpty && !id.contains("/") {
      try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
    }
  }

  var count: Int { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).count }
}

// MARK: - App Intents (Shortcuts actions)

/// "Import Bank Message": used in a personal automation with the Message trigger. The user
/// passes the automation's message content (Shortcut Input) as `messageText`. Optional
/// sender text can come from the message's sender variable if their iOS version offers it.
@available(iOS 16.0, *)
struct ImportBankTransactionIntent: AppIntent {
  static var title: LocalizedStringResource = "Import Bank Message"
  static var description = IntentDescription("Sends a bank SMS to Fils so it can record the transaction. Fils stores it on this device only.")
  static var openAppWhenRun: Bool = false

  @Parameter(title: "Message Text", inputOptions: String.IntentInputOptions(multiline: true))
  var messageText: String

  @Parameter(title: "Sender")
  var sender: String?

  static var parameterSummary: some ParameterSummary {
    Summary("Import \(\.$messageText) into Fils") { \.$sender }
  }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    do {
      try CaptureInbox.shared.add(source: "shortcut", text: messageText, sender: sender)
      return .result(dialog: "Saved to Fils. It will appear when you open the app.")
    } catch CaptureInbox.InboxError.empty {
      return .result(dialog: "No message text was received. Check that the automation passes the message.")
    } catch {
      return .result(dialog: "Fils could not save this message. Open Fils to check capture status.")
    }
  }
}

/// "Import Apple Pay Transaction": for the Wallet "Transaction" automation trigger
/// (iOS 17+). The user maps the trigger's Merchant, Amount and Card/Pass variables to these
/// parameters. Only those fields are used; missing fields go to review in the app.
@available(iOS 16.0, *)
struct ImportWalletTransactionIntent: AppIntent {
  static var title: LocalizedStringResource = "Import Apple Pay Transaction"
  static var description = IntentDescription("Sends an Apple Pay tap-to-pay transaction (merchant and amount) to Fils.")
  static var openAppWhenRun: Bool = false

  @Parameter(title: "Merchant")
  var merchant: String?

  @Parameter(title: "Amount")
  var amount: String?

  @Parameter(title: "Card or Pass")
  var card: String?

  func perform() async throws -> some IntentResult & ProvidesDialog {
    var fields: [String: String] = [:]
    if let m = merchant, !m.isEmpty { fields["merchant"] = m }
    if let a = amount, !a.isEmpty { fields["amount"] = a }
    if let c = card, !c.isEmpty { fields["card"] = c }
    if fields["amount"] == nil && fields["merchant"] == nil {
      return .result(dialog: "No transaction details were received.")
    }
    do {
      try CaptureInbox.shared.add(source: "wallet", text: "", sender: nil, fields: fields)
      return .result(dialog: "Saved to Fils.")
    } catch {
      return .result(dialog: "Fils could not save this transaction.")
    }
  }
}

/// Test action used by onboarding: proves the automation can reach the app.
@available(iOS 16.0, *)
struct FilsTestCaptureIntent: AppIntent {
  static var title: LocalizedStringResource = "Test Fils Capture"
  static var openAppWhenRun: Bool = false

  func perform() async throws -> some IntentResult & ProvidesDialog {
    try CaptureInbox.shared.add(source: "shortcut", text: "FILS TEST", sender: "FILS", kind: "test")
    return .result(dialog: "Fils received the test. Go back to Fils to confirm.")
  }
}

/// App Shortcuts make the actions discoverable in Shortcuts and Spotlight. Publishing them
/// does NOT create the user's personal automation: the user sets that up once in
/// Shortcuts → Automation.
@available(iOS 16.0, *)
struct FilsShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(intent: FilsTestCaptureIntent(), phrases: ["Test \(.applicationName) capture"], shortTitle: "Test Capture", systemImageName: "checkmark.seal")
    AppShortcut(intent: ImportBankTransactionIntent(), phrases: ["Import bank message to \(.applicationName)"], shortTitle: "Import Bank Message", systemImageName: "message")
    AppShortcut(intent: ImportWalletTransactionIntent(), phrases: ["Import Apple Pay transaction to \(.applicationName)"], shortTitle: "Import Apple Pay", systemImageName: "creditcard")
  }
}
