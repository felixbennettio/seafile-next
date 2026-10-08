#if os(macOS)
import SwiftUI
import SeafileCore

struct MacServerStatusView: View {
    var model: AppModel
    @State private var results: [UUID: String] = [:]
    @State private var loading = false
    var body: some View {
        List(model.accounts) { account in
            VStack(alignment: .leading, spacing: 6) {
                Text(account.name).font(.headline)
                Text(verbatim: account.endpoint.url.absoluteString).font(.caption).textSelection(.enabled)
                Text(results[account.id] ?? "Checking connection…").foregroundStyle(.secondary)
            }.padding(.vertical, 4)
        }.navigationTitle("Server status")
            .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(loading) }
            .onAppear { Task { await refresh() } }
            .overlay { if loading { ProgressView() } }
    }
    private func refresh() async {
        guard !loading else { return }; loading = true
        defer { loading = false }
        for account in model.accounts {
            let start = Date()
            do {
                let info = try await model.client(for: account).serverInfo()
                results[account.id] = "Connected · \(info.version) · \(Int(Date().timeIntervalSince(start) * 1000)) ms"
            } catch { results[account.id] = error.localizedDescription }
        }
    }
}
#endif
