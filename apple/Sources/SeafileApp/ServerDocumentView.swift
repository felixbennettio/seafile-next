import SwiftUI
@preconcurrency import WebKit
import SeafileCore

struct ServerDocumentView: View {
    var model: AppModel
    let account: ServerAccount
    let document: ServerDocument
    @Environment(\.dismiss) private var dismiss
    @State private var request: URLRequest?
    @State private var error: String?
    @State private var browser = ServerDocumentBrowser()
    @State private var closing = false
    @State private var dialogText = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error { Text(error).foregroundStyle(.red).padding(12) }
                if let request {
                    DocumentWebView(request: request, endpoint: account.endpoint, browser: browser).id(account.id)
                } else { ProgressView("Opening document").frame(maxWidth: .infinity, maxHeight: .infinity) }
                if let error = browser.error { Text(error).foregroundStyle(.red).padding(12) }
                if browser.loading { ProgressView().controlSize(.small).padding(8) }
            }.navigationTitle(document.title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { closing = true }.accessibilityIdentifier("document.close") }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("Back", systemImage: "chevron.left") { browser.view?.goBack() }.disabled(!browser.canGoBack)
                        Button("Forward", systemImage: "chevron.right") { browser.view?.goForward() }.disabled(!browser.canGoForward)
                        Button("Reload", systemImage: "arrow.clockwise") { browser.error = nil; browser.view?.reload() }.disabled(request == nil)
                    }
                }
                .confirmationDialog("Close document?", isPresented: $closing, titleVisibility: .visible) {
                    Button("Close") { dismiss() }
                } message: { Text("Check that the server has saved your changes before closing the document.") }
        }
        .interactiveDismissDisabled()
        .alert("Document", isPresented: Binding(get: { browser.dialog != nil }, set: { if !$0 { browser.finishDialog(nil) } })) {
            if browser.dialog?.kind == .prompt { TextField("Response", text: $dialogText) }
            Button("OK") { browser.finishDialog(browser.dialog?.kind == .prompt ? dialogText : "") }
            if browser.dialog?.kind != .alert { Button("Cancel", role: .cancel) { browser.finishDialog(nil) } }
        } message: { Text(browser.dialog?.message ?? "") }
        .onChange(of: browser.dialog?.id) { _, _ in dialogText = browser.dialog?.defaultText ?? "" }
        .task {
            do { request = try await model.client(for: account).documentLoginRequest(target: document.url) }
            catch { self.error = documentError(error) }
        }
        .onAppear { model.beginFileAction(account) }
        .onDisappear { model.endFileAction(account) }
        .onChange(of: model.selectedAccountID) { _, id in
            if id != account.id { browser.view?.stopLoading(); browser.view = nil; request = nil; dismiss() }
        }
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 560)
        #endif
    }
}

@MainActor @Observable final class ServerDocumentBrowser {
    var canGoBack = false
    var canGoForward = false
    var loading = true
    var error: String?
    var dialog: Dialog?
    @ObservationIgnored weak var view: WKWebView?
    struct Dialog: Identifiable {
        enum Kind { case alert, confirm, prompt }
        let id = UUID()
        let kind: Kind, message: String, defaultText: String?
        let finish: (String?) -> Void
    }
    func finishDialog(_ value: String?) { let pending = dialog; dialog = nil; pending?.finish(value) }
}

#if os(iOS)
private typealias DocumentRepresentable = UIViewRepresentable
#else
private typealias DocumentRepresentable = NSViewRepresentable
#endif

private struct DocumentWebView: DocumentRepresentable {
    let request: URLRequest
    let endpoint: ServerEndpoint
    let browser: ServerDocumentBrowser
    func makeCoordinator() -> Coordinator { Coordinator(endpoint: endpoint, browser: browser) }
    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { context.coordinator.make(request) }
    func updateUIView(_ view: WKWebView, context: Context) { }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop(view) }
    #else
    func makeNSView(context: Context) -> WKWebView { context.coordinator.make(request) }
    func updateNSView(_ view: WKWebView, context: Context) { }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop(view) }
    #endif
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let endpoint: ServerEndpoint, browser: ServerDocumentBrowser
        init(endpoint: ServerEndpoint, browser: ServerDocumentBrowser) { self.endpoint = endpoint; self.browser = browser }
        func make(_ request: URLRequest) -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = self; view.uiDelegate = self; browser.view = view
            view.load(request)
            return view
        }
        func stop(_ view: WKWebView) {
            browser.finishDialog(nil)
            view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil; browser.view = nil
        }
        private func allows(_ action: WKNavigationAction) -> Bool {
            if ServerDocumentSession.allowsNavigation(action.request, endpoint: endpoint, mainFrame: action.targetFrame?.isMainFrame != false) { return true }
            browser.error = "This page tried to leave the server's document session. Open external links separately in your browser."
            browser.loading = false
            return false
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // WebKit versions can retain custom headers across same-origin
            // redirects. Resume with only the new session cookie after the bridge.
            if action.request.value(forHTTPHeaderField: "Authorization") != nil,
               let url = action.request.url, let bridge = try? endpoint.api("mobile-login/"), url.path != bridge.path,
               let safe = try? ServerDocumentSession.sessionRedirect(action.request, endpoint: endpoint) {
                decisionHandler(.cancel); webView.load(safe); return
            }
            decisionHandler(allows(action) ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if allows(action) { webView.load(action.request) }; return nil
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { browser.loading = true }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            browser.loading = false; browser.canGoBack = webView.canGoBack; browser.canGoForward = webView.canGoForward
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
        private func failed(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            browser.loading = false; browser.error = "The document page could not be loaded. Check your connection and reload."
        }
        // WKWebView needs native JavaScript prompts for editor confirmations.
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            browser.finishDialog(nil)
            browser.dialog = .init(kind: .alert, message: String(message.prefix(2000)), defaultText: nil, finish: { _ in completionHandler() })
        }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            browser.finishDialog(nil)
            browser.dialog = .init(kind: .confirm, message: String(message.prefix(2000)), defaultText: nil, finish: { completionHandler($0 != nil) })
        }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            browser.finishDialog(nil)
            browser.dialog = .init(kind: .prompt, message: String(prompt.prefix(2000)), defaultText: defaultText, finish: completionHandler)
        }
    }
}
