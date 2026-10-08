import Foundation

public struct ServerInfo: Decodable, Sendable {
    public let version: String
    public let features: [String]
    public var supportsBrowserSSO: Bool { features.contains("client-sso-via-local-browser") }
}

public struct AccountInfo: Decodable, Sendable {
    public let email: String
    public let name: String?
}

public struct SSODevice: Sendable {
    public let platform: String, identifier: String, name: String, clientVersion: String, systemVersion: String
    public init(platform: String, identifier: String, name: String, clientVersion: String, systemVersion: String) {
        self.platform = platform; self.identifier = identifier; self.name = name
        self.clientVersion = clientVersion; self.systemVersion = systemVersion
    }
    var query: [URLQueryItem] {
        [.init(name: "shib_platform", value: platform), .init(name: "shib_device_id", value: identifier),
         .init(name: "shib_device_name", value: name), .init(name: "shib_client_version", value: clientVersion),
         .init(name: "shib_platform_version", value: systemVersion)]
    }
}

public struct SSOChallenge: Sendable {
    public let browserURL: URL
    let nonce: String
}

public struct SSOIdentity: Sendable, Equatable {
    public let username: String
    public let apiToken: String
}

extension SeafileAPI {
    public func serverInfo() async throws -> ServerInfo {
        try JSONDecoder().decode(ServerInfo.self, from: await request("api2/server-info/"))
    }

    public func accountInfo() async throws -> AccountInfo {
        let result = try JSONDecoder().decode(AccountInfo.self, from: await request("api2/account/info/"))
        guard !result.email.isEmpty else { throw SeafileError.invalidResponse }
        return result
    }

    public func beginSSO(device: SSODevice, preferSSO: Bool = false) async throws -> SSOChallenge {
        guard try await serverInfo().supportsBrowserSSO else {
            throw SeafileError.local("This server has not enabled browser sign-in for clients. Ask its administrator to enable CLIENT_SSO_VIA_LOCAL_BROWSER.")
        }
        struct Link: Decodable { let link: String }
        // A lost response may leave an unused expiring nonce, never an account
        // or file mutation. It is safe to request another sign-in challenge.
        let result = try JSONDecoder().decode(Link.self, from: await request("api2/client-sso-link/", method: "POST", replaySafe: true))
        guard let url = URL(string: result.link, relativeTo: endpoint.url)?.absoluteURL,
              endpoint.isSameOrigin(url), url.user == nil, url.password == nil,
              url.fragment == nil, var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw SeafileError.invalidResponse
        }
        let prefix = URLComponents(url: try endpoint.api("client-sso/"), resolvingAgainstBaseURL: true)!.path
        // URL.path drops the final slash on Apple platforms; components.path
        // retains it, which is required by Seafile's client-sso URL route.
        guard components.path.hasPrefix(prefix), components.path.hasSuffix("/") else { throw SeafileError.invalidResponse }
        let nonce = String(components.path.dropFirst(prefix.count).dropLast())
        guard nonce.count == 60, nonce.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw SeafileError.invalidResponse
        }
        // Seafile consumes all five device fields on the browser confirmation
        // URL, not on the API POST. A partial set cannot create a device token.
        components.queryItems = (components.queryItems ?? []).filter { !$0.name.hasPrefix("shib_") } + device.query
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let browserURL = components.url else { throw SeafileError.invalidResponse }
        if preferSSO {
            try await startSSOVisit(browserURL)
            // Older login templates interpolate an unescaped nested `next`
            // query into JavaScript, dropping four of the five device fields.
            // Enter the configured OIDC/SAML dispatcher directly, with one
            // properly encoded next value; no IdP client secret is needed.
            components.path += "complete/"
            let next = components.path + "?" + (components.percentEncodedQuery ?? "")
            let direct = try endpoint.api("sso/", query: [.init(name: "next", value: next)])
            return SSOChallenge(browserURL: direct, nonce: nonce)
        }
        return SSOChallenge(browserURL: browserURL, nonce: nonce)
    }

    public func checkSSO(_ challenge: SSOChallenge) async throws -> SSOIdentity? {
        struct Reply: Decodable { let status: String; let username: String?; let apiToken: String? }
        let result = try JSONDecoder().decode(Reply.self, from: await request("api2/client-sso-link/\(challenge.nonce)/"))
        switch result.status {
        case "waiting": return nil
        case "success":
            guard let username = result.username, !username.isEmpty,
                  let apiToken = result.apiToken, !apiToken.isEmpty else { throw SeafileError.invalidResponse }
            return SSOIdentity(username: username, apiToken: apiToken)
        case "error": throw SeafileError.local("Browser sign-in expired or was declined. Start sign-in again.")
        default: throw SeafileError.invalidResponse
        }
    }
}
