import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PhotoBackupJPEG {
    /// Original iOS semantics: convert HEIC/HEIF stills only. Keep a Live Photo's
    /// original still when its paired video is included; preserve other formats.
    public static func filename(original: String, enabled: Bool, livePair: Bool) -> String {
        guard enabled, !livePair, ["heic", "heif"].contains((original as NSString).pathExtension.lowercased()) else { return original }
        return (original as NSString).deletingPathExtension + ".jpg"
    }
    public static func convert(source: URL, destination: URL) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL,
              !FileManager.default.fileExists(atPath: destination.path),
              let image = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(image), [UTType.heic.identifier, UTType.heif.identifier].contains(type as String),
              CGImageSourceGetCount(image) > 0 else {
            throw SeafileError.local("The HEIC photo could not be converted. Its original is preserved.")
        }
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw SeafileError.local("The JPEG backup could not be created. Its original is preserved.")
        }
        // ImageIO retains the still's EXIF, orientation and dimensions rather
        // than rendering a thumbnail through UIKit. Do not alter the source.
        CGImageDestinationAddImageFromSource(output, image, 0, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(output) else {
            try? FileManager.default.removeItem(at: destination)
            throw SeafileError.local("The JPEG conversion failed. Its original is preserved.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}
