import CryptoKit
import UIKit
import UniformTypeIdentifiers

/// Share Extension: accepts plain text (for example a bank SMS shared from Messages) and
/// writes it to the same App Group capture inbox the App Intents use. Nothing is parsed or
/// uploaded here. The app parses, dedupes and posts it. The platform id is a hash of the
/// normalized text, so sharing the same message twice is deduplicated by the app.
final class ShareViewController: UIViewController {
  private let label = UILabel()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.96)
    label.translatesAutoresizingMaskIntoConstraints = false
    label.numberOfLines = 0
    label.textAlignment = .center
    label.font = .preferredFont(forTextStyle: .headline)
    label.text = NSLocalizedString("Saving to Fils…", comment: "")
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
    ])
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    Task { await handle() }
  }

  private func extractText() async -> String? {
    guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return nil }
    for item in items {
      for provider in item.attachments ?? [] where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
        if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String { return text }
      }
      if let s = item.attributedContentText?.string, !s.isEmpty { return s }
    }
    return nil
  }

  static func platformId(for text: String) -> String {
    let norm = text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    let digest = SHA256.hash(data: Data(norm.utf8))
    return "share:" + digest.map { String(format: "%02x", $0) }.joined().prefix(32)
  }

  private func handle() async {
    var message = NSLocalizedString("Nothing to save", comment: "")
    if let text = await extractText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      do {
        try CaptureInbox.shared.add(source: "share", text: text, sender: nil, platformId: Self.platformId(for: text))
        message = NSLocalizedString("Saved to Fils. Open Fils to see it.", comment: "")
      } catch {
        message = NSLocalizedString("Fils could not save this text.", comment: "")
      }
    }
    await MainActor.run { label.text = message }
    try? await Task.sleep(nanoseconds: 900_000_000)
    extensionContext?.completeRequest(returningItems: nil)
  }
}
