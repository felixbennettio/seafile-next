#if os(macOS)
import Foundation
import CFNetwork

public enum SystemProxyResolver {
    public static func resolve(for url: URL) async throws -> ClientNetworkSettings {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
              let list = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as? [[String: Any]],
              let first = list.first else { var direct = ClientNetworkSettings(); direct.proxy = .none; return direct }
        var result = first
        if first[kCFProxyTypeKey as String] as? String == kCFProxyTypeAutoConfigurationURL as String,
           let pacURL = first[kCFProxyAutoConfigurationURLKey as String] as? URL {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            configuration.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(from: pacURL)
            if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                throw SeafileError.local("Could not load the system proxy configuration.")
            }
            guard let script = String(data: data, encoding: .utf8),
                  let proxies = CFNetworkCopyProxiesForAutoConfigurationScript(script as CFString, url as CFURL, nil)?.takeRetainedValue() as? [[String: Any]],
                  let evaluated = proxies.first else { throw SeafileError.local("Could not evaluate the system proxy configuration.") }
            result = evaluated
        }
        var value = ClientNetworkSettings()
        let type = result[kCFProxyTypeKey as String] as? String
        if type == kCFProxyTypeHTTP as String || type == kCFProxyTypeHTTPS as String { value.proxy = .http }
        else if type == kCFProxyTypeSOCKS as String { value.proxy = .socks5 }
        else if type == kCFProxyTypeNone as String { value.proxy = .none }
        else { throw SeafileError.local("The system returned an unsupported proxy configuration.") }
        value.host = result[kCFProxyHostNameKey as String] as? String ?? ""
        value.port = result[kCFProxyPortNumberKey as String] as? Int ?? 0
        value.username = result[kCFProxyUsernameKey as String] as? String ?? ""
        value.password = result[kCFProxyPasswordKey as String] as? String ?? ""
        return value
    }
}
#endif
