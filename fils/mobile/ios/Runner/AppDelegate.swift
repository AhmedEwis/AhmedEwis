import AppIntents
import Flutter
import UIKit
import UserNotifications

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
    // Lets flutter_local_notifications present reminders while the app is in the foreground.
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FilsCapture") else { return }
    let channel = CaptureChannels.register(messenger: registrar.messenger())
    HeadlessCapture.shared.uiEngineActive = true
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
    } catch CaptureInbox.InboxError.empty {
      return .result(dialog: "No message text was received. Check that the automation passes the message.")
    } catch {
      return .result(dialog: "Fils could not save this message. Open Fils to check capture status.")
    }
    // Securely queued. Now try to process it right away (headless), within a short wait so
    // the automation doesn't time out.
    let summary = await HeadlessCapture.shared.process(wait: 4)
    if let s = summary, s.error == nil {
      if s.posted > 0, let line = s.lastLine { return .result(dialog: "Added to Fils: \(line)") }
      if s.review > 0 { return .result(dialog: "Saved to Fils. It needs your review before it counts.") }
      if s.ignored > 0 { return .result(dialog: "Not a transaction (for example an OTP). Nothing was added.") }
      if s.duplicate > 0 { return .result(dialog: "Already in Fils. This exact message was imported before, so it was not counted again.") }
    }
    return .result(dialog: "Saved securely in Fils. It will be added to your balances shortly, or when you open Fils.")
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

  @Parameter(title: "Name")
  var name: String?

  func perform() async throws -> some IntentResult & ProvidesDialog {
    var fields: [String: String] = [:]
    if let m = merchant, !m.isEmpty { fields["merchant"] = m }
    if let a = amount, !a.isEmpty { fields["amount"] = a }
    if let c = card, !c.isEmpty { fields["card"] = c }
    if let n = name, !n.isEmpty { fields["name"] = n }
    if fields["amount"] == nil && fields["merchant"] == nil {
      return .result(dialog: "No transaction details were received.")
    }
    do {
      try CaptureInbox.shared.add(source: "wallet", text: "", sender: nil, fields: fields)
      // Wallet automations are reported to time out when intents run long: return now
      // and process in the background.
      Task { @MainActor in _ = await HeadlessCapture.shared.process(wait: 0) }
      return .result(dialog: "Saved securely in Fils.")
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
