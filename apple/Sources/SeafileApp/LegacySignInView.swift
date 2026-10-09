import SwiftUI
@preconcurrency import WebKit
import SeafileCore

struct LegacySignInView: View {
    let request: LegacySignInRequest
    let finish: (Result<SSOIdentity, Error>) -> Void
    @State private var error: String?
    @State private var retryID = UUID()
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(request.endpoint.url.host ?? "").font(.subheadline).textSelection(.enabled)
                Text("This server uses the older Seafile sign-in protocol. Complete its sign-in here. Servers with modern browser sign-in use your default browser instead.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("login.legacyError")
                    Button("Start a new sign-in attempt") { self.error = nil; retryID = UUID() }
                }
                LegacyLoginWebView(request: request, finish: finish, failed: { error = $0 }).id(retryID)
            }.padding(12).navigationTitle("Server sign-in")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { finish(.failure(CancellationError())) }.accessibilityIdentifier("login.legacyCancel") } }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 560)
        #endif
    }
}

#if os(iOS)
private typealias LegacyWebRepresentable = UIViewRepresentable
#else
private typealias LegacyWebRepresentable = NSViewRepresentable
#endif

private struct LegacyLoginWebView: LegacyWebRepresentable {
    let request: LegacySignInRequest
    let finish: (Result<SSOIdentity, Error>) -> Void
    let failed: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(request: request, finish: finish, failed: failed) }
    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { context.coordinator.makeWebView() }
    func updateUIView(_ view: WKWebView, context: Context) { }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop(view) }
    #else
    func makeNSView(context: Context) -> WKWebView { context.coordinator.makeWebView() }
    func updateNSView(_ view: WKWebView, context: Context) { }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop(view) }
    #endif

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver, WKUIDelegate {
        let request: LegacySignInRequest
        let finish: (Result<SSOIdentity, Error>) -> Void
        let failed: (String) -> Void
        private weak var view: WKWebView?
        private var complete = false
        init(request: LegacySignInRequest, finish: @escaping (Result<SSOIdentity, Error>) -> Void, failed: @escaping (String) -> Void) {
            self.request = request; self.finish = finish; self.failed = failed
        }
        func makeWebView() -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: .zero, configuration: config)
            self.view = view
            view.navigationDelegate = self; view.uiDelegate = self
            config.websiteDataStore.httpCookieStore.add(self)
            view.load(URLRequest(url: request.url))
            return view
        }
        func stop(_ view: WKWebView) {
            complete = true; view.stopLoading()
            view.configuration.websiteDataStore.httpCookieStore.remove(self)
            view.navigationDelegate = nil; view.uiDelegate = nil
            self.view = nil
        }
        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { checkCookies() }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { checkCookies() }
        private func checkCookies() {
            guard !complete, let view, let page = view.url, request.endpoint.isSameOrigin(page) else { return }
            view.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.complete, self.view?.url == page else { return }
                for cookie in cookies {
                    if let identity = LegacySSO.identity(cookie: cookie, endpoint: self.request.endpoint, page: page) {
                        self.complete = true
                        self.finish(.success(identity)); return
                    }
                }
            }
        }
        private func allowed(_ url: URL?) -> Bool {
            guard let url, let scheme = url.scheme?.lowercased(), ["http", "https", "about"].contains(scheme),
                  url.user == nil, url.password == nil else {
                failed("This older server login needs a browser-compatible authentication option. An external authentication app cannot return credentials through the old protocol."); return false
            }
            if request.endpoint.url.scheme == "https", scheme == "http" {
                failed("The server sign-in attempted to leave HTTPS. Check its identity provider and callback addresses."); return false
            }
            return true
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(allowed(navigationAction.request.url) ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if allowed(navigationAction.request.url) { webView.load(navigationAction.request) }
            return nil
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { show(error) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { show(error) }
        private func show(_ error: Error) {
            guard !complete else { return }
            let code = (error as NSError).code
            guard code != NSURLErrorCancelled else { return }
            // Do not display authorization URLs containing codes or state.
            failed("The server sign-in page could not be loaded (\(code)). Check your connection or start a new attempt.")
        }
    }
}
