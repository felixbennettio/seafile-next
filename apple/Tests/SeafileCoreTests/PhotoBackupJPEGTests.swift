import Foundation
import Testing
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import SeafileCore

@Test func photoBackupJPEGPreservesDimensionsOrientationAndOriginal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("photo.heic"), result = root.appendingPathComponent("photo.jpg")
    let pixels = Data(repeating: 97, count: 16 * 8 * 4)
    let image = try #require(CGImage(width: 16, height: 8, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16 * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let encoded = try #require(CGImageDestinationCreateWithURL(input as CFURL, UTType.heic.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(encoded, image, [kCGImagePropertyOrientation: 6,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:09 12:34:56"]] as CFDictionary)
    #expect(CGImageDestinationFinalize(encoded))
    let original = try Data(contentsOf: input)
    try PhotoBackupJPEG.convert(source: input, destination: result)
    #expect(try Data(contentsOf: input) == original)
    let jpeg = try #require(CGImageSourceCreateWithURL(result as CFURL, nil))
    #expect(CGImageSourceGetType(jpeg) as String? == UTType.jpeg.identifier)
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(jpeg, 0, nil) as? [String: Any])
    #expect(properties[kCGImagePropertyPixelWidth as String] as? Int == 16)
    #expect(properties[kCGImagePropertyPixelHeight as String] as? Int == 8)
    #expect(properties[kCGImagePropertyOrientation as String] as? Int == 6)
    let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
    #expect(exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String == "2026:10:09 12:34:56")
    let bytes = try Data(contentsOf: result)
    #expect(throws: Error.self) { try PhotoBackupJPEG.convert(source: input, destination: result) }
    #expect(try Data(contentsOf: result) == bytes)
    #expect(try FileManager.default.attributesOfItem(atPath: result.path)[.posixPermissions] as? Int == 0o600)
}

@Test func invalidHEICBackupDoesNotDestroyItsOriginalOrProduceAnUpload() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("broken.heic"), result = root.appendingPathComponent("result.jpg")
    let bytes = Data("a damaged photo".utf8); try bytes.write(to: input)
    #expect(throws: Error.self) { try PhotoBackupJPEG.convert(source: input, destination: result) }
    #expect(try Data(contentsOf: input) == bytes)
    #expect(!FileManager.default.fileExists(atPath: result.path))
}

@Test @MainActor func olderPhotoSettingsKeepOriginalsAndJPEGHistoryIsIndependent() throws {
    let old = Data(#"{"repository":"repo","path":"/","enabled":true,"wifiOnly":false,"includeVideos":true,"includeLivePhotoVideo":false,"albums":["album"]}"#.utf8)
    var settings = try JSONDecoder().decode(PhotoBackupSettings.self, from: old)
    #expect(!settings.useJPEG && settings.enabled && !settings.wifiOnly && settings.albums == ["album"])
    settings.useJPEG = true
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let account = UUID(), history = try PhotoBackupHistory(root: root)
    try history.configure(account: account, settings: settings)
    #expect(try PhotoBackupHistory(root: root).settings(account: account)?.useJPEG == true)
    let base = PhotoBackupRecord.key(accountID: account, repository: "repo", path: "/", asset: "photo", revision: "1", resource: "1:IMG_1.heic")
    let converted = PhotoBackupRecord.key(accountID: account, repository: "repo", path: "/", asset: "photo", revision: "1", resource: "1:IMG_1.heic:jpeg-v1")
    #expect(base != converted)
    #expect(PhotoBackupJPEG.filename(original: "IMG_1.HEIC", enabled: true, livePair: false) == "IMG_1.jpg")
    #expect(PhotoBackupJPEG.filename(original: "IMG_1.heif", enabled: true, livePair: false) == "IMG_1.jpg")
    #expect(PhotoBackupJPEG.filename(original: "IMG_1.heic", enabled: false, livePair: false) == "IMG_1.heic")
    #expect(PhotoBackupJPEG.filename(original: "IMG_1.heic", enabled: true, livePair: true) == "IMG_1.heic")
    for name in ["IMG_1.png", "IMG_1.gif", "IMG_1.jpg", "IMG_1.mov"] {
        #expect(PhotoBackupJPEG.filename(original: name, enabled: true, livePair: false) == name)
    }
}
