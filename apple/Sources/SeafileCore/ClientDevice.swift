import Foundation
import CryptoKit

public struct SSODevice: Sendable {
    public let platform: String, identifier: String, name: String, clientVersion: String, systemVersion: String
    public init(platform: String, identifier: String, name: String, clientVersion: String, systemVersion: String) {
        self.platform = platform; self.identifier = identifier
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Match TokenV2's Unicode character limits, including combining marks.
        self.name = String(String.UnicodeScalarView((trimmed.isEmpty ? (platform == "ios" ? "iPhone" : "Mac") : trimmed).unicodeScalars.prefix(40)))
        self.clientVersion = String(String.UnicodeScalarView(clientVersion.unicodeScalars.prefix(16)))
        self.systemVersion = String(String.UnicodeScalarView(systemVersion.unicodeScalars.prefix(16)))
    }
    public static func apple(platform: String, installationID: String, name: String, clientVersion: String,
                             operatingSystem: OperatingSystemVersion) -> SSODevice {
        let id = platform == "ios" ? installationID : SHA256.hash(data: Data(installationID.utf8)).prefix(20).map { String(format: "%02x", $0) }.joined()
        let version = "\(operatingSystem.majorVersion).\(operatingSystem.minorVersion).\(operatingSystem.patchVersion)"
        return SSODevice(platform: platform, identifier: id, name: name, clientVersion: clientVersion, systemVersion: version)
    }
    public var authFields: [String: String] {
        ["platform": platform, "device_id": identifier, "device_name": name,
         "client_version": clientVersion, "platform_version": systemVersion]
    }
    var query: [URLQueryItem] {
        authFields.sorted { $0.key < $1.key }.map { .init(name: "shib_" + $0.key, value: $0.value) }
    }
}
