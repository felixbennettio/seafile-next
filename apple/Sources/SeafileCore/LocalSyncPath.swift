#if os(macOS)
import Foundation

public enum LocalSyncPath {
    /// Resolve symlinks and enforce a complete directory boundary. Finder must
    /// never apply a library's credentials to a sibling or an escaped symlink.
    public static func relative(_ item: URL, within folder: URL) -> String? {
        guard item.isFileURL, folder.isFileURL else { return nil }
        guard let root = canonical(folder)?.path, let target = canonical(item)?.path else { return nil }
        if target == root { return "/" }
        guard target.hasPrefix(root + "/") else { return nil }
        return String(target.dropFirst(root.count))
    }
    private static func canonical(_ url: URL) -> URL? {
        var parent = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: parent.path) {
            if (try? FileManager.default.attributesOfItem(atPath: parent.path)[.type]) as? FileAttributeType == .typeSymbolicLink { return nil }
            guard parent.path != "/" else { return nil }
            tail.insert(parent.lastPathComponent, at: 0)
            parent.deleteLastPathComponent()
        }
        var resolved = parent.resolvingSymlinksInPath()
        for name in tail { resolved.appendPathComponent(name) }
        return resolved
    }
}
#endif
