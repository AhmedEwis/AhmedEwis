import Foundation

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
