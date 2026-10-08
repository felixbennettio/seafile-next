import Foundation

// Compile with the production ClientDevice.swift. Only synthetic installation
// identities and names are exported; never use the runner's hardware/hostname.
@main struct NativeLoginFields {
    static func main() throws {
        let installation = "00000000-0000-4000-8000-000000000002"
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersion
        let name = String(repeating: "Mac + 测试 & ", count: 8)
        let mac = SSODevice.apple(platform: "mac", installationID: installation, name: name,
                                 clientVersion: "1.0.0", operatingSystem: operatingSystem)
        let ios = SSODevice.apple(platform: "ios", installationID: installation, name: "CI iPhone + Test & Co",
                                 clientVersion: "1.0.0", operatingSystem: operatingSystem)
        let result: [String: Any] = ["mac": mac.authFields, "ios": ios.authFields,
                                    "legacyMacVersion": ProcessInfo.processInfo.operatingSystemVersionString]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        FileHandle.standardOutput.write(data)
    }
}
