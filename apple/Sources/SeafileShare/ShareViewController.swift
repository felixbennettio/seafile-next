import UIKit
import SwiftUI
import SeafileCore
import UniformTypeIdentifiers

@MainActor final class ShareViewController: UIViewController {
    private var composer: ShareComposerModel?
    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = CGSize(width: 600, height: 620)
        do {
            let store = try SharedImportStore.shared()
            let inputs = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            var providers = inputs.flatMap { $0.attachments ?? [] }
            if !providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.text.identifier) }) {
                for text in inputs.compactMap({ $0.attributedContentText?.string }).filter({ !$0.isEmpty }) { providers.append(NSItemProvider(object: text as NSString)) }
            }
            let model = ShareComposerModel(store: store, providers: providers, requiresAuthentication: SharedAppSecurity.requiresAuthentication,
                accounts: { try SharedAccounts.read() }, client: { account in
                    guard let token = try CredentialStore.token(for: account) else { throw SeafileError.local("Open seafile-next and sign in again to this account.") }
                    return SeafileAPI(endpoint: account.endpoint, token: token)
                })
            composer = model
            embed(ShareComposerView(model: model) { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil) })
        } catch {
            embed(NavigationStack {
                VStack(spacing: 20) { Text("Open seafile-next and sign in before sharing files."); Button("Close") { self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil) } }.padding().navigationTitle("Save to Seafile")
            })
        }
        NotificationCenter.default.addObserver(self, selector: #selector(hostBackground), name: NSNotification.Name.NSExtensionHostDidEnterBackground, object: nil)
    }
    @objc private func hostBackground() { composer?.hostEnteredBackground() }
    private func embed<Content: View>(_ content: Content) {
        let child = UIHostingController(rootView: content)
        addChild(child); child.view.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child.view)
        NSLayoutConstraint.activate([child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), child.view.topAnchor.constraint(equalTo: view.topAnchor), child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        child.didMove(toParent: self)
    }
}
