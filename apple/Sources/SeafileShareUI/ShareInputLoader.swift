#if os(iOS)
import Foundation
import UniformTypeIdentifiers
import SeafileCore

@MainActor enum ShareInputLoader {
    static func load(_ provider: NSItemProvider, store: SharedImportStore, id: UUID) async throws {
        let name = provider.suggestedName
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                    do {
                        if let error { throw error }
                        guard let source = item as? URL, source.isFileURL else { throw SeafileError.invalidResponse }
                        let access = source.startAccessingSecurityScopedResource()
                        defer { if access { source.stopAccessingSecurityScopedResource() } }
                        try store.addFile(source, name: name ?? source.lastPathComponent, to: id)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, error in
                    do {
                        if let error { throw error }
                        guard let url = item as? URL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw SeafileError.invalidResponse }
                        let data = try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
                        try store.addData(data, name: "Shared link.webloc", to: id); continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } else if let identifier = provider.registeredTypeIdentifiers.first(where: {
            guard let type = UTType($0) else { return false }
            let namedTextFile = type.conforms(to: .text) && !(name.map { ($0 as NSString).pathExtension } ?? "").isEmpty
            return type.conforms(to: .data) && (!type.conforms(to: .text) || namedTextFile) && !type.conforms(to: .url)
        }) {
            let fileName = name ?? ("Shared file." + (UTType(identifier)?.preferredFilenameExtension ?? "bin"))
            let extensionName = UTType(identifier)?.preferredFilenameExtension
            let finalName = (fileName as NSString).pathExtension.isEmpty ? fileName + (extensionName.map { "." + $0 } ?? "") : fileName
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                provider.loadFileRepresentation(forTypeIdentifier: identifier) { source, error in
                    do {
                        if let error { throw error }
                        guard let source else { throw SeafileError.invalidResponse }
                        // The system removes this URL when the callback returns.
                        try store.addFile(source, name: finalName, to: id); continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                provider.loadItem(forTypeIdentifier: UTType.text.identifier) { item, error in
                    do {
                        if let error { throw error }
                        let data: Data
                        if let text = item as? String { data = Data(text.utf8) }
                        else if let supplied = item as? Data { data = supplied }
                        else { throw SeafileError.invalidResponse }
                        try store.addData(data, name: "Shared text.txt", to: id); continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } else { throw SeafileError.local("This shared item is not a supported file, photo, video, text or link.") }
    }
}
#endif
