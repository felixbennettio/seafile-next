import Foundation
import Testing
@testable import SeafileCore

@Test func legacySignInPreservesTheDeploymentPathAndDeviceMetadata() throws {
    let endpoint = try ServerEndpoint("https://cloud.example/nested/seafile")
    let device = SSODevice(platform: "mac", identifier: "device", name: "Mac + 名 & Co", clientVersion: "1.0", systemVersion: "26.0.1")
    let url = try LegacySSO.loginURL(endpoint: endpoint, device: device)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: true))
    #expect(components.path == "/nested/seafile/shib-login/")
    #expect(components.queryItems?.count == 5)
    #expect(components.queryItems?.first { $0.name == "shib_device_name" }?.value == device.name)
    #expect(components.percentEncodedQuery?.contains("%2B") == true)
    #expect(components.queryItems?.first { $0.name == "shib_platform_version" }?.value == "26.0.1")
}

private func authCookie(name: String = "seahub_auth", value: String, domain: String = "cloud.example", path: String = "/", expires: Date? = nil) throws -> HTTPCookie {
    var values: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
    if let expires { values[.expires] = expires }
    return try #require(HTTPCookie(properties: values))
}

@Test func legacyCookieRequiresTheExactServerCookieAndTrustedReturnPage() throws {
    let endpoint = try ServerEndpoint("https://cloud.example/seafile/")
    let page = URL(string: "https://cloud.example/seafile/library/")!
    let token = String(repeating: "a1", count: 20)
    let cookie = try authCookie(value: "\"user+tag@example.org@\(token)\"")
    #expect(LegacySSO.identity(cookie: cookie, endpoint: endpoint, page: page) == SSOIdentity(username: "user+tag@example.org", apiToken: token))
    for invalid in [try authCookie(name: "other_seahub_auth", value: cookie.value),
                    try authCookie(value: cookie.value, domain: "example"),
                    try authCookie(value: cookie.value, domain: "other.example"),
                    try authCookie(value: cookie.value, path: "/another/"),
                    try authCookie(value: cookie.value, path: "/seaf"),
                    try authCookie(value: cookie.value, expires: .distantPast)] {
        #expect(LegacySSO.identity(cookie: invalid, endpoint: endpoint, page: page) == nil)
    }
    for wrongPage in ["https://idp.example/callback/", "http://cloud.example/seafile/", "https://cloud.example/another/", "https://cloud.example/seafile-evil/", "https://cloud.example:8443/seafile/"] {
        #expect(LegacySSO.identity(cookie: cookie, endpoint: endpoint, page: URL(string: wrongPage)!) == nil)
    }
}

@Test func legacyCookieRejectsMissingOrMalformedTokenWithoutExposingIt() throws {
    let endpoint = try ServerEndpoint("https://cloud.example/")
    for value in ["no-token", "@" + String(repeating: "a", count: 40), "user@example.org@short", "user@example.org@" + String(repeating: "z", count: 40)] {
        #expect(LegacySSO.identity(cookie: try authCookie(value: value), endpoint: endpoint, page: endpoint.url) == nil)
    }
}
