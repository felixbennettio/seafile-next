import Cocoa
import FinderSync
import Darwin

/// The direct edition uses the original Finder Sync model for real sync
/// folders. Its bridge contains only paths/statuses, never account credentials.
final class FinderSync: FIFinderSync {
    private let controller = FIFinderSyncController.default()
    private var observed: Set<URL> = []
    private var statuses: [String: String] = [:]
    private var timer: Timer?
    private var stateURL: URL {
        let home = String(cString: getpwuid(getuid()).pointee.pw_dir)
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/seafile-next/FinderBridge/state.json")
    }
    override init() {
        super.init()
        for (id, symbol, name) in [("synced", "checkmark.circle.fill", "Synced"), ("syncing", "arrow.triangle.2.circlepath", "Syncing"), ("error", "exclamationmark.circle.fill", "Sync error"), ("readonly", "eye.circle.fill", "Read only"), ("paused", "pause.circle.fill", "Paused"), ("locked", "lock.fill", "Locked"), ("locked_by_me", "lock.open.fill", "Locked by you"), ("ignored", "minus.circle", "Ignored")] {
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: name) { controller.setBadgeImage(image, label: NSLocalizedString(name, comment: "Finder sync status"), forBadgeIdentifier: id) }
        }
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reload() }
    }
    deinit { timer?.invalidate() }
    private func reload() {
        guard let data = try? Data(contentsOf: stateURL), let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let updated = state["updated"] as? Double, Date().timeIntervalSince1970 - updated < 30,
              let roots = state["roots"] as? [String] else {
            controller.directoryURLs = []; return
        }
        controller.directoryURLs = Set(roots.map { URL(fileURLWithPath: $0) })
        statuses = state["statuses"] as? [String: String] ?? [:]
        for url in observed { controller.setBadgeIdentifier(statuses[url.path] ?? "", for: url) }
    }
    override func requestBadgeIdentifier(for url: URL) {
        if observed.count >= 1000 { observed.removeAll() }
        observed.insert(url)
        controller.setBadgeIdentifier(statuses[url.path] ?? "", for: url)
        // Sandbox notifications use only a string object, without userInfo.
        if let data = try? JSONSerialization.data(withJSONObject: ["path": url.path]), let object = String(data: data, encoding: .utf8) {
            DistributedNotificationCenter.default().postNotificationName(.init("io.felixbennett.seafile.direct.finder-status"), object: object, userInfo: nil, deliverImmediately: true)
        }
    }
    override func endObservingDirectory(at url: URL) { observed = observed.filter { !$0.path.hasPrefix(url.path + "/") } }
    override var toolbarItemName: String { "seafile-next" }
    override var toolbarItemToolTip: String { "Open seafile-next" }
    override var toolbarItemImage: NSImage { NSImage(systemSymbolName: "cloud", accessibilityDescription: "seafile-next")! }
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let menu = NSMenu(title: "seafile-next")
        if menuKind == .toolbarItemMenu {
            add("Open seafile-next", action: "open", menu: menu); return menu
        }
        guard let url = controller.selectedItemURLs()?.first ?? controller.targetedURL() else { return nil }
        guard controller.directoryURLs.contains(where: { url.path == $0.path || url.path.hasPrefix($0.path + "/") }) else { return nil }
        add("Open in seafile-next", action: "open", menu: menu, url: url)
        add("Sync now", action: "sync", menu: menu, url: url)
        add("Share links and permissions…", action: "share", menu: menu, url: url)
        add("Show file history", action: "history", menu: menu, url: url)
        if url.hasDirectoryPath == false {
            add("Lock file", action: "lock", menu: menu, url: url)
            add("Unlock file", action: "unlock", menu: menu, url: url)
            add("Show lock owner", action: "lock-info", menu: menu, url: url)
        }
        return menu
    }
    private func add(_ title: String, action: String, menu: NSMenu, url: URL? = nil) {
        let item = NSMenuItem(title: NSLocalizedString(title, comment: "Finder action"), action: #selector(performFinderAction(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = ["action": action, "path": url?.path ?? ""]
        menu.addItem(item)
    }
    @objc private func performFinderAction(_ item: NSMenuItem) {
        guard let fields = item.representedObject as? [String: String] else { return }
        var url = URLComponents(); url.scheme = "seafile-next-direct"; url.host = "finder"
        url.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        if let url = url.url { NSWorkspace.shared.open(url) }
    }
}
