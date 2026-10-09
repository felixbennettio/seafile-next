import Foundation

/// Compatibility with the original Seafile shib-login cookie bridge. Each
/// attempt must use a new, non-persistent browser store, not shared cookies.
public enum LegacySSO {
    public static func loginURL(endpoint: ServerEndpoint, device: SSODevice) throws -> URL {
        try endpoint.api("shib-login/", query: device.query)
    }

    public static func identity(cookie: HTTPCookie, endpoint: ServerEndpoint, page: URL, now: Date = Date()) -> SSOIdentity? {
        guard endpoint.isSameOrigin(page),
              cookie.name == "seahub_auth",
              cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == endpoint.url.host?.lowercased(),
              cookie.expiresDate.map({ $0 > now }) ?? true else { return nil }
        let base = URLComponents(url: endpoint.url, resolvingAgainstBaseURL: true)?.path ?? "/"
        let path = URLComponents(url: page, resolvingAgainstBaseURL: true)?.path ?? ""
        guard path.hasPrefix(base),
              cookie.path == "/" || base == cookie.path || base.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/") else { return nil }
        var value = cookie.value
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value.removeFirst(); value.removeLast() }
        guard let separator = value.lastIndex(of: "@") else { return nil }
        let username = String(value[..<separator]), token = String(value[value.index(after: separator)...])
        // TokenV2 and the legacy token model both use 40 hexadecimal digits.
        // A cookie is only a candidate; account/info verifies it before saving.
        guard !username.isEmpty, username.count <= 254,
              !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              token.utf8.count == 40,
              token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else { return nil }
        return SSOIdentity(username: username, apiToken: token)
    }
}
