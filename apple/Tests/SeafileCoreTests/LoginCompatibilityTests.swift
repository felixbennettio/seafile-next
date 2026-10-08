import Foundation
import Testing
@testable import SeafileCore

private actor LoginHTTP: HTTPTransport {
    var requests: [URLRequest] = []
    var replies: [(Int, String, [String: String])]
    init(_ replies: [(Int, String, [String: String])]) { self.replies = replies }
    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let reply = replies.removeFirst()
        return (Data(reply.1.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: reply.2)!)
    }
    func download(for request: URLRequest) throws -> (URL, URLResponse) { throw SeafileError.invalidResponse }
    func upload(for request: URLRequest, from file: URL) throws -> (Data, URLResponse) { throw SeafileError.invalidResponse }
}

private actor LostLoginHTTP: HTTPTransport {
    var requests: [URLRequest] = []
    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        if requests.count == 1 { throw URLError(.networkConnectionLost) }
        return (Data(#"{"token":"fixture-token"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func download(for request: URLRequest) throws -> (URL, URLResponse) { throw SeafileError.invalidResponse }
    func upload(for request: URLRequest, from file: URL) throws -> (Data, URLResponse) { throw SeafileError.invalidResponse }
}

@Test func aLostOTPLoginResponseIsNeverAutomaticallyReplayed() async throws {
    let http = LostLoginHTTP()
    let retry = RetryingHTTPTransport(transport: http, retryDelays: [.milliseconds(1)])
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://fixture.invalid/"), transport: retry)
    do {
        _ = try await api.authenticate(username: "fixture", password: "fixture", otp: "123456")
        Issue.record("An OTP request whose response was lost was replayed")
    } catch {
        #expect(error.localizedDescription.contains("new two-factor code"))
        #expect(!error.localizedDescription.contains("123456"))
    }
    #expect(await http.requests.count == 1)
    let noOTP = LostLoginHTTP()
    let apiWithoutOTP = SeafileAPI(endpoint: try ServerEndpoint("https://fixture.invalid/"), transport: RetryingHTTPTransport(transport: noOTP, retryDelays: [.milliseconds(1)]))
    #expect(try await apiWithoutOTP.authenticate(username: "fixture", password: "fixture") == "fixture-token")
    #expect(await noOTP.requests.count == 2)
}

@Test func nativeMacDeviceUsesNumericVersionWithinTheRealTokenSchema() {
    let installation = "00000000-0000-4000-8000-000000000002"
    let version = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 2)
    let device = SSODevice.apple(platform: "mac", installationID: installation, name: "My Mac", clientVersion: "1.0.0", operatingSystem: version)
    #expect(device.systemVersion == "26.1.2")
    #expect(device.systemVersion.unicodeScalars.count <= 16)
    #expect(device.identifier.count == 40 && device.identifier.allSatisfy(\.isHexDigit))
    let same = SSODevice.apple(platform: "mac", installationID: installation, name: "Other name", clientVersion: "1.0.1", operatingSystem: version)
    #expect(same.identifier == device.identifier)
    let ios = SSODevice.apple(platform: "ios", installationID: installation, name: "Phone", clientVersion: "1.0.0", operatingSystem: version)
    #expect(ios.identifier == installation)
}

@Test func nativeDeviceNameHandlesBlankAndCombiningUnicodeNames() {
    let blank = SSODevice(platform: "mac", identifier: String(repeating: "a", count: 40), name: " \n ", clientVersion: "1.0.0", systemVersion: "26.1.2")
    #expect(blank.name == "Mac")
    let long = SSODevice(platform: "ios", identifier: UUID().uuidString, name: String(repeating: "e\u{301}", count: 40), clientVersion: String(repeating: "a", count: 30), systemVersion: String(repeating: "b", count: 30))
    #expect(long.name.unicodeScalars.count == 40)
    #expect(long.clientVersion.unicodeScalars.count == 16 && long.systemVersion.unicodeScalars.count == 16)
}

@Test func passwordAndSSOUseExactlyTheSameBoundedNativeMetadata() async throws {
    let nonce = String(repeating: "d", count: 60)
    let http = LoginHTTP([
        (200, #"{"token":"fixture-token"}"#, [:]),
        (200, #"{"version":"13.0.25","features":["client-sso-via-local-browser"]}"#, [:]),
        (200, "{\"link\":\"https://fixture.invalid/seafile/client-sso/\(nonce)/\"}", [:]),
        (302, "", ["Location": "/seafile/accounts/login/"])
    ])
    let endpoint = try ServerEndpoint("https://fixture.invalid/seafile")
    let device = SSODevice.apple(platform: "mac", installationID: UUID().uuidString, name: String(repeating: "Mac + 测试 & ", count: 8), clientVersion: "1.0.0", operatingSystem: ProcessInfo.processInfo.operatingSystemVersion)
    let api = SeafileAPI(endpoint: endpoint, transport: http)
    _ = try await api.authenticate(username: "user", password: "fixture-password", otp: "123456", device: device)
    let challenge = try await api.beginSSO(device: device, preferSSO: true)
    let login = await http.requests[0]
    let body = URLComponents(string: "?" + String(decoding: login.httpBody!, as: UTF8.self))!.queryItems!
    let next = URLComponents(url: challenge.browserURL, resolvingAgainstBaseURL: true)!.queryItems!.first!.value!
    let browser = URLComponents(string: "https://fixture.invalid" + next)!.queryItems!
    for (key, value) in device.authFields {
        #expect(body.first { $0.name == key }?.value == value)
        #expect(browser.first { $0.name == "shib_" + key }?.value == value)
    }
}

@Test func authentication400DisplaysTheServersActualOTPReason() async throws {
    let http = LoginHTTP([(400, #"{"non_field_errors":["Two factor auth token is invalid."]}"#, ["X-Seafile-OTP": "required"])])
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://fixture.invalid/seafile/"), transport: http)
    do {
        _ = try await api.authenticate(username: "fixture", password: "not-a-real-password", otp: "123456")
        Issue.record("The invalid OTP response was accepted")
    } catch {
        #expect(error.localizedDescription.contains("Two factor auth token is invalid."))
        #expect(error.localizedDescription.contains("400"))
        #expect(!error.localizedDescription.contains("not-a-real-password"))
    }
}

@Test func authentication400DisplaysFieldValidationWithoutDumpingOtherResponseKeys() async throws {
    let http = LoginHTTP([(400, #"{"device_name":["This field may not be blank."],"token":"private-diagnostic-value"}"#, [:])])
    let api = SeafileAPI(endpoint: try ServerEndpoint("https://fixture.invalid/"), transport: http)
    do {
        _ = try await api.authenticate(username: "fixture", password: "fixture")
        Issue.record("The validation failure was accepted")
    } catch {
        #expect(error.localizedDescription.contains("device_name: This field may not be blank."))
        #expect(!error.localizedDescription.contains("private-diagnostic-value"))
    }
}
