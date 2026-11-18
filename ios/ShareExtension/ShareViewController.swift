//  ShareViewController.swift — "Spektra Cam" in the share sheet of Photos (and Files, other apps). The pictures are
//  copied into the app group's Inbox; the app imports them the next time it comes forward
//  (`ViewModel.collectHandedOver`). An extension cannot open its app, so it says where they went and closes.

import UIKit
import UniformTypeIdentifiers

@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.11, green: 0.10, blue: 0.09, alpha: 1)
        label.textColor = UIColor(red: 0.95, green: 0.91, blue: 0.84, alpha: 1)
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.text = String(localized: "正在加入 Spektra Cam…")
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
        ])
        Task { await handOver() }
    }

    private func handOver() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var copied = 0
        if let inbox = Self.inbox() {
            for provider in providers {
                // The RAW of a RAW + JPEG pair is the negative.
                let type = provider.registeredTypeIdentifiers.compactMap(UTType.init)
                    .first { $0.conforms(to: .rawImage) } ?? (provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) ? .image : nil)
                guard let type, await Self.copy(provider, type: type, into: inbox) else { continue }
                copied += 1
            }
        }
        label.text = copied == 0 ? String(localized: "没有可以加入的照片") : String(localized: "已加入 \(copied) 张\n打开 Spektra Cam 时导入")
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// The app group's Inbox ("group." + the app's bundle id; this extension's id is the app's + ".share").
    private static func inbox() -> URL? {
        let own = Bundle.main.bundleIdentifier ?? ""
        let app = own.hasSuffix(".share") ? String(own.dropLast(6)) : own
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group." + app) else { return nil }
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    private static func copy(_ provider: NSItemProvider, type: UTType, into inbox: URL) async -> Bool {
        await withCheckedContinuation { done in
            _ = provider.loadFileRepresentation(for: type) { url, _, _ in
                guard let url else { done.resume(returning: false); return }
                let name = UUID().uuidString.prefix(8) + "-" + url.lastPathComponent
                done.resume(returning: (try? FileManager.default.copyItem(at: url, to: inbox.appendingPathComponent(String(name)))) != nil)
            }
        }
    }
}
